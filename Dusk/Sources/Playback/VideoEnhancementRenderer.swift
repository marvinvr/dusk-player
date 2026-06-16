import CoreVideo
import Foundation
import Metal
import QuartzCore
import SwiftUI
import UIKit
import simd

@MainActor
final class VideoEnhancementRenderer {
    private struct Uniforms {
        var sourceSize: SIMD2<Float>
        var outputSize: SIMD2<Float>
        var sharpening: Float
        var useLanczos: Float
        var sourceRGBA: Float
        var _padding: Float = 0
    }

    // Immutable Metal context. Sendable `let`s are implicitly nonisolated, so
    // the render queue can use them without hopping to the main actor.
    private let request: VideoEnhancementRequest
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    /// Dedicated serial queue that performs all GPU work. Rendering is kept off
    /// the main thread so the player's periodic UI work (time sync, SwiftUI
    /// diffing, HUD) cannot stall frames, and a blocking `nextDrawable()` paces
    /// rendering against the display without freezing the interface.
    private let renderQueue = DispatchQueue(
        label: "com.dusk.videoenhancement.render",
        qos: .userInteractive
    )

    /// Render-queue-owned Metal state. Only touched on `renderQueue`.
    nonisolated(unsafe) private var textureCache: CVMetalTextureCache?
    nonisolated(unsafe) private var metalLayer: CAMetalLayer?
    nonisolated(unsafe) private var lastDrawnFrame: VideoEnhancementFrame?

    /// Latest status, written from the render queue and read from the main
    /// actor. Guarded by `statusLock`.
    private let statusLock = NSLock()
    nonisolated(unsafe) private var _status: VideoEnhancementStatus

    nonisolated var status: VideoEnhancementStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return _status
    }

    /// Coalescing inbox for pushed frames. Only the most recent frame is kept;
    /// `isDraining` guarantees a single in-flight drain on `renderQueue`, so we
    /// never queue more work than the GPU can drain. Guarded by `frameLock`.
    private let frameLock = NSLock()
    nonisolated(unsafe) private var pendingFrame: VideoEnhancementFrame?
    nonisolated(unsafe) private var isDraining = false
    /// Count of frames replaced before they could be drawn: the live "GPU can't
    /// keep up" signal that drives adaptive quality. Guarded by `frameLock`.
    nonisolated(unsafe) private var droppedFrameCount = 0

    /// Adaptive quality: when the GPU cannot sustain the source frame rate the
    /// coalescing path drops frames, which the viewer sees as judder. Instead of
    /// dropping, step the shader down (Lanczos -> bilinear -> bilinear without
    /// sharpening) so every frame is drawn, then probe back up when headroom
    /// returns. Downgrade quickly, upgrade cautiously, and back off probing when
    /// an upgrade immediately fails so stable heavy content settles instead of
    /// oscillating. Render-queue-owned state, updated in `evaluateAdaptiveQuality`.
    private enum PerformanceLevel: Int {
        case full = 0          // Lanczos + adaptive sharpening
        case bilinearSharp = 1 // bilinear + adaptive sharpening
        case bilinear = 2      // bilinear only
    }
    nonisolated private static let maxPerformanceLevel = PerformanceLevel.bilinear.rawValue
    nonisolated private static let qualityEvalWindow = 48
    nonisolated private static let downgradeDropThreshold = 3
    nonisolated private static let upgradeStreakInitial = 3
    nonisolated private static let upgradeStreakMax = 24
    nonisolated(unsafe) private var performanceLevel: PerformanceLevel = .full
    nonisolated(unsafe) private var renderedInWindow = 0
    nonisolated(unsafe) private var cleanWindowStreak = 0
    nonisolated(unsafe) private var windowsSinceUpgrade = Int.max
    nonisolated(unsafe) private var upgradeStreakRequired = VideoEnhancementRenderer.upgradeStreakInitial

    init?(request: VideoEnhancementRequest) {
        guard request.isPotentiallyEnabled else { return nil }
        guard request.preflightUnavailabilityReason == nil else { return nil }
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "videoEnhancementVertex"),
              let fragmentFunction = library.makeFunction(name: "videoEnhancementFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)

        self.request = request
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = cache
        self._status = .idle
    }

    func makeView() -> VideoEnhancementMetalView {
        let view = VideoEnhancementMetalView(renderer: self, device: device)
        metalLayer = view.metalLayer
        return view
    }

    // MARK: - Frame intake

    /// Entry point for producers already on the main actor (AVPlayer's
    /// display-link pull). Routes through the same coalescing path as `enqueue`.
    func submit(pixelBuffer: CVPixelBuffer) {
        enqueue(frame: VideoEnhancementFrame(retaining: pixelBuffer))
    }

    /// Thread-safe push path for any producer. Frames are coalesced to the most
    /// recent one and drawn one-at-a-time on the render queue. When the GPU
    /// cannot sustain the source frame rate, intermediate frames are dropped
    /// instead of being queued, keeping the picture aligned with the audio clock.
    nonisolated func enqueue(frame: VideoEnhancementFrame) {
        frameLock.lock()
        if pendingFrame != nil {
            // The previous frame is replaced before it was drawn: a dropped
            // frame, i.e. the renderer is behind the source frame rate.
            droppedFrameCount &+= 1
        }
        pendingFrame = frame
        let shouldSchedule = !isDraining
        if shouldSchedule {
            isDraining = true
        }
        frameLock.unlock()

        guard shouldSchedule else { return }
        renderQueue.async { [weak self] in
            self?.drainPendingFrames()
        }
    }

    /// Runs on `renderQueue`. Renders the newest pending frame repeatedly,
    /// dropping any older frames that piled up while the GPU was busy. The serial
    /// queue plus `isDraining` keeps exactly one drain loop in flight.
    nonisolated private func drainPendingFrames() {
        while true {
            frameLock.lock()
            let frame = pendingFrame
            pendingFrame = nil
            if frame == nil {
                isDraining = false
                frameLock.unlock()
                return
            }
            frameLock.unlock()

            if let frame {
                lastDrawnFrame = frame
                renderToLayer(frame: frame)
                evaluateAdaptiveQuality()
            }
        }
    }

    func clear() {
        frameLock.lock()
        pendingFrame = nil
        droppedFrameCount = 0
        frameLock.unlock()
        setStatus(request.isPotentiallyEnabled ? .idle : .disabled)
        renderQueue.async { [weak self] in
            self?.lastDrawnFrame = nil
            self?.resetAdaptiveState()
        }
    }

    /// Redraws the last frame at the current drawable size (e.g. after a layout
    /// change) so paused video does not go black. Dispatched to the render queue.
    func renderCurrentFrame() {
        renderQueue.async { [weak self] in
            guard let self, let frame = self.lastDrawnFrame else { return }
            self.renderToLayer(frame: frame)
        }
    }

    // MARK: - Adaptive quality (render queue)

    /// Adjusts `performanceLevel` from the live drop signal with hysteresis.
    /// Downgrades on a burst of drops, upgrades only after several fully clean
    /// windows, and widens the upgrade requirement whenever an upgrade fails.
    nonisolated private func evaluateAdaptiveQuality() {
        frameLock.lock()
        let dropsSoFar = droppedFrameCount
        frameLock.unlock()

        // Fast path: a burst of drops mid-window means we are clearly behind, so
        // drop quality now rather than waiting for the window to close.
        if dropsSoFar >= Self.downgradeDropThreshold,
           performanceLevel.rawValue < Self.maxPerformanceLevel {
            downgradePerformance()
            return
        }

        renderedInWindow += 1
        guard renderedInWindow >= Self.qualityEvalWindow else { return }
        renderedInWindow = 0
        if windowsSinceUpgrade != Int.max {
            windowsSinceUpgrade += 1
        }

        frameLock.lock()
        let windowDrops = droppedFrameCount
        droppedFrameCount = 0
        frameLock.unlock()

        if windowDrops > 0 {
            cleanWindowStreak = 0
            if windowDrops >= Self.downgradeDropThreshold,
               performanceLevel.rawValue < Self.maxPerformanceLevel {
                downgradePerformance()
            }
            return
        }

        // A fully clean window. Only restore quality after enough of them.
        cleanWindowStreak += 1
        guard performanceLevel.rawValue > 0, cleanWindowStreak >= upgradeStreakRequired else { return }
        performanceLevel = PerformanceLevel(rawValue: performanceLevel.rawValue - 1) ?? .full
        cleanWindowStreak = 0
        windowsSinceUpgrade = 0
        if performanceLevel == .full {
            // Fully recovered and stable; relax probing for next time.
            upgradeStreakRequired = Self.upgradeStreakInitial
        }
    }

    nonisolated private func downgradePerformance() {
        let failedProbe = windowsSinceUpgrade <= 1
        performanceLevel = PerformanceLevel(
            rawValue: min(performanceLevel.rawValue + 1, Self.maxPerformanceLevel)
        ) ?? .bilinear
        cleanWindowStreak = 0
        renderedInWindow = 0
        frameLock.lock()
        droppedFrameCount = 0
        frameLock.unlock()
        if failedProbe {
            // The last upgrade did not hold; wait longer before trying again.
            upgradeStreakRequired = min(upgradeStreakRequired * 2, Self.upgradeStreakMax)
        }
    }

    nonisolated private func resetAdaptiveState() {
        performanceLevel = .full
        renderedInWindow = 0
        cleanWindowStreak = 0
        windowsSinceUpgrade = Int.max
        upgradeStreakRequired = Self.upgradeStreakInitial
    }

    // MARK: - Rendering (render queue)

    nonisolated private func setStatus(_ newStatus: VideoEnhancementStatus) {
        statusLock.lock()
        _status = newStatus
        statusLock.unlock()
    }

    nonisolated private func renderToLayer(frame: VideoEnhancementFrame) {
        guard let metalLayer else { return }
        let pixelBuffer = frame.pixelBuffer

        guard let texture = makeTexture(from: pixelBuffer) else {
            setStatus(VideoEnhancementStatus(state: .unavailable, reason: "Could not create Metal texture"))
            return
        }

        // nextDrawable() may block while the compositor recycles a drawable;
        // because we are off the main thread this paces rendering instead of
        // freezing the UI.
        guard let drawable = metalLayer.nextDrawable() else { return }

        // Derive the output size from the drawable itself rather than reading the
        // layer's drawableSize across threads.
        let outputSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        guard outputSize.width > 0, outputSize.height > 0 else { return }

        let inputSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let decision = enhancementDecision(inputSize: inputSize, outputSize: outputSize)

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            setStatus(VideoEnhancementStatus(state: .unavailable, reason: "Could not create command buffer"))
            return
        }

        let viewportRect = aspectFitRect(inputSize: inputSize, outputSize: outputSize)
        encoder.setViewport(MTLViewport(
            originX: Double(viewportRect.minX),
            originY: Double(viewportRect.minY),
            width: Double(viewportRect.width),
            height: Double(viewportRect.height),
            znear: 0,
            zfar: 1
        ))

        var uniforms = Uniforms(
            sourceSize: SIMD2(Float(inputSize.width), Float(inputSize.height)),
            outputSize: SIMD2(Float(outputSize.width), Float(outputSize.height)),
            sharpening: decision.sharpening,
            useLanczos: decision.useLanczos ? 1 : 0,
            sourceRGBA: frame.channelLayout == .rgbaBytesInBGRA ? 1 : 0
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        setStatus(decision.status)
    }

    nonisolated private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache,
              let pixelFormat = metalPixelFormat(for: pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )

        guard result == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }

        return texture
    }

    nonisolated private func metalPixelFormat(for pixelBuffer: CVPixelBuffer) -> MTLPixelFormat? {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA:
            .bgra8Unorm
        case kCVPixelFormatType_32RGBA:
            .rgba8Unorm
        default:
            nil
        }
    }

    nonisolated private func enhancementDecision(
        inputSize: CGSize,
        outputSize: CGSize
    ) -> (status: VideoEnhancementStatus, sharpening: Float, useLanczos: Bool) {
        let frameRate = request.frameRate ?? 0
        let heightScale = outputSize.height / max(inputSize.height, 1)

        if request.mode == .automatic {
            if request.isHDR {
                return (
                    VideoEnhancementStatus(
                        state: .unavailable,
                        reason: "Auto skips HDR",
                        inputSize: inputSize,
                        outputSize: outputSize
                    ),
                    0,
                    false
                )
            }

            if frameRate > 50 {
                return (
                    VideoEnhancementStatus(
                        state: .unavailable,
                        reason: "Auto skips >50fps",
                        inputSize: inputSize,
                        outputSize: outputSize
                    ),
                    0,
                    false
                )
            }

            if heightScale < 1.08 {
                return (
                    VideoEnhancementStatus(
                        state: .unavailable,
                        reason: "Source already matches output",
                        inputSize: inputSize,
                        outputSize: outputSize
                    ),
                    0,
                    false
                )
            }
        } else if frameRate > 70 {
            return (
                VideoEnhancementStatus(
                    state: .unavailable,
                    reason: "Disabled above 70fps",
                    inputSize: inputSize,
                    outputSize: outputSize
                ),
                0,
                false
            )
        }

        let baseSharpening = Float(min(max((heightScale - 1) * 0.18, 0.18), 0.55))
        let wantsLanczos = heightScale > 1.02

        // Apply the adaptive performance level. Under sustained GPU load we draw
        // every frame with a cheaper shader instead of dropping frames.
        let useLanczos: Bool
        let sharpening: Float
        let reason: String
        switch performanceLevel {
        case .full:
            useLanczos = wantsLanczos
            sharpening = baseSharpening
            reason = wantsLanczos
                ? "Metal Lanczos + adaptive sharpening"
                : "Metal bilinear + adaptive sharpening"
        case .bilinearSharp:
            useLanczos = false
            sharpening = baseSharpening
            reason = "Adaptive: bilinear + sharpening (GPU load)"
        case .bilinear:
            useLanczos = false
            sharpening = 0
            reason = "Adaptive: bilinear (GPU load)"
        }

        return (
            VideoEnhancementStatus(
                state: .active,
                reason: reason,
                inputSize: inputSize,
                outputSize: outputSize
            ),
            sharpening,
            useLanczos
        )
    }

    nonisolated private func aspectFitRect(inputSize: CGSize, outputSize: CGSize) -> CGRect {
        guard inputSize.width > 0, inputSize.height > 0 else {
            return CGRect(origin: .zero, size: outputSize)
        }

        let scale = min(outputSize.width / inputSize.width, outputSize.height / inputSize.height)
        let fittedSize = CGSize(width: inputSize.width * scale, height: inputSize.height * scale)
        return CGRect(
            x: (outputSize.width - fittedSize.width) / 2,
            y: (outputSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}

@MainActor
final class VideoEnhancementMetalView: UIView {
    private weak var renderer: VideoEnhancementRenderer?

    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    init(renderer: VideoEnhancementRenderer, device: MTLDevice) {
        self.renderer = renderer
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = currentDisplayScale
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
        renderer?.renderCurrentFrame()
    }

    private func updateDrawableSize() {
        let scale = currentDisplayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    private var currentDisplayScale: CGFloat {
        if let scale = window?.screen.scale, scale > 0 {
            return scale
        }

        let traitScale = traitCollection.displayScale
        return traitScale > 0 ? traitScale : 1
    }
}

struct VideoEnhancementRepresentable: UIViewRepresentable {
    let renderer: VideoEnhancementRenderer

    func makeUIView(context: Context) -> VideoEnhancementMetalView {
        renderer.makeView()
    }

    func updateUIView(_ uiView: VideoEnhancementMetalView, context: Context) {}
}
