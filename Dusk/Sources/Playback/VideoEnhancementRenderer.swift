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

    private let request: VideoEnhancementRequest
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private weak var view: VideoEnhancementMetalView?
    private var latestFrame: VideoEnhancementFrame?
    private(set) var status: VideoEnhancementStatus

    /// Coalescing inbox for frames pushed from a background producer thread.
    /// Only the most recent frame is kept; `isDraining` guarantees a single
    /// in-flight main-actor render so we never queue more work than the GPU can
    /// drain. Guarded by `frameLock`.
    nonisolated(unsafe) private let frameLock = NSLock()
    nonisolated(unsafe) private var pendingFrame: VideoEnhancementFrame?
    nonisolated(unsafe) private var isDraining = false

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
        self.status = .idle
    }

    func makeView() -> VideoEnhancementMetalView {
        let view = VideoEnhancementMetalView(renderer: self, device: device)
        self.view = view
        return view
    }

    func submit(pixelBuffer: CVPixelBuffer) {
        submit(frame: VideoEnhancementFrame(retaining: pixelBuffer))
    }

    /// Direct render path for producers already on the main actor that pace
    /// themselves by time (AVPlayer's display-link pull). Renders immediately.
    func submit(frame: VideoEnhancementFrame) {
        latestFrame = frame
        render(frame: frame)
    }

    /// Thread-safe push path for background producers that emit one callback per
    /// decoded frame (VLCKit raw video output). Frames are coalesced to the most
    /// recent one and rendered at most one-at-a-time on the main actor. When the
    /// GPU cannot sustain the source frame rate, intermediate frames are dropped
    /// instead of being queued, which keeps the picture aligned with the audio
    /// clock rather than drifting into slow motion.
    nonisolated func enqueue(frame: VideoEnhancementFrame) {
        frameLock.lock()
        pendingFrame = frame
        let shouldSchedule = !isDraining
        if shouldSchedule {
            isDraining = true
        }
        frameLock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor in
            self.drainPendingFrames()
        }
    }

    @MainActor
    private func drainPendingFrames() {
        frameLock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        frameLock.unlock()

        if let frame {
            latestFrame = frame
            render(frame: frame)
        }

        frameLock.lock()
        let hasMore = pendingFrame != nil
        if !hasMore {
            isDraining = false
        }
        frameLock.unlock()

        guard hasMore else { return }
        Task { @MainActor in
            self.drainPendingFrames()
        }
    }

    func clear() {
        frameLock.lock()
        pendingFrame = nil
        frameLock.unlock()
        latestFrame = nil
        status = request.isPotentiallyEnabled ? .idle : .disabled
    }

    func renderCurrentFrame() {
        guard let latestFrame else { return }
        render(frame: latestFrame)
    }

    private func render(frame: VideoEnhancementFrame) {
        let pixelBuffer = frame.pixelBuffer
        guard let view else { return }
        let layer = view.metalLayer
        let outputSize = layer.drawableSize
        guard outputSize.width > 0, outputSize.height > 0 else { return }

        guard let drawable = layer.nextDrawable(),
              let texture = makeTexture(from: pixelBuffer) else {
            status = VideoEnhancementStatus(state: .unavailable, reason: "Could not create Metal texture")
            return
        }

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
            status = VideoEnhancementStatus(state: .unavailable, reason: "Could not create command buffer")
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

        status = decision.status
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
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

    private func metalPixelFormat(for pixelBuffer: CVPixelBuffer) -> MTLPixelFormat? {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA:
            .bgra8Unorm
        case kCVPixelFormatType_32RGBA:
            .rgba8Unorm
        default:
            nil
        }
    }

    private func enhancementDecision(
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

        let sharpening = Float(min(max((heightScale - 1) * 0.18, 0.18), 0.55))
        return (
            VideoEnhancementStatus(
                state: .active,
                reason: "Metal Lanczos + adaptive sharpening",
                inputSize: inputSize,
                outputSize: outputSize
            ),
            sharpening,
            heightScale > 1.02
        )
    }

    private func aspectFitRect(inputSize: CGSize, outputSize: CGSize) -> CGRect {
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
