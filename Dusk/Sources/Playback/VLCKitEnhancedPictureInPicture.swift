#if os(iOS)
import Accelerate
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import OSLog
import UIKit

private let enhancedPiPLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "VLCKitEnhancedPiP"
)

/// Carries a non-`Sendable` AVKit completion handler across into a main-actor
/// closure. Safe because the handler is created and invoked on the main thread.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Playback surface the sample-buffer PiP window drives. Implemented by
/// `VLCKitEngine` so the floating window's play/pause/skip controls map back to
/// the live `VLCMediaPlayer`.
@MainActor
protocol VLCKitEnhancedPictureInPicturePlaybackDelegate: AnyObject {
    var enhancedPiPIsPlaying: Bool { get }
    var enhancedPiPCurrentTime: TimeInterval { get }
    var enhancedPiPDuration: TimeInterval { get }
    func enhancedPiPSetPlaying(_ playing: Bool)
    func enhancedPiPSkip(by seconds: TimeInterval, completion: @escaping () -> Void)
}

/// Backing view whose layer is the `AVSampleBufferDisplayLayer` that PiP projects
/// from. It is mounted (fully occluded) behind the Metal enhancement view so it
/// stays in the on-screen hierarchy, which is what keeps PiP possible.
final class VLCKitEnhancedPiPDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        displayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Native Picture in Picture for VLCKit's Video Enhancement path.
///
/// When enhancement is on, VLCKit renders through raw libvlc callbacks into the
/// Metal upscaler, so its own PiP drawable is detached and there is no native
/// layer to project. This output tees the same decoded frames into an
/// `AVSampleBufferDisplayLayer` and drives a sample-buffer
/// `AVPictureInPictureController` from it, giving the floating window the
/// non-upscaled source stream (which is all PiP needs).
///
/// Frame intake mirrors `VideoEnhancementRenderer`: pushes are coalesced to the
/// most recent frame and drained one at a time on a serial queue, so a GPU/CPU
/// that cannot keep up drops stale frames instead of building a backlog.
@MainActor
final class VLCKitEnhancedPictureInPictureOutput: NSObject {
    let displayView: VLCKitEnhancedPiPDisplayView

    private(set) var isPictureInPicturePossible = false
    private(set) var isPictureInPictureActive = false

    /// Fires when `isPictureInPicturePossible` changes so the engine can
    /// republish its observable flag for the PiP button.
    var onPictureInPicturePossibleChanged: (@MainActor () -> Void)?
    /// Fires when the floating window starts (`true`) or stops (`false`).
    var onPictureInPictureActiveChanged: (@MainActor (Bool) -> Void)?
    /// Asks the owner to bring the full player UI back before the window closes.
    /// Call the completion once the UI is on screen.
    var onRestoreUI: (@MainActor (@escaping (Bool) -> Void) -> Void)?

    weak var playbackDelegate: (any VLCKitEnhancedPictureInPicturePlaybackDelegate)?

    private var pipController: AVPictureInPictureController?
    nonisolated(unsafe) private var possibleObserver: NSKeyValueObservation?

    /// The display layer, reachable from the render queue. AVSampleBufferDisplayLayer's
    /// media-feeding API (`enqueue`, `isReadyForMoreMediaData`, `flush`, `status`)
    /// is designed to be called from a serial queue, so this is safe off-main.
    nonisolated(unsafe) private let renderLayer: AVSampleBufferDisplayLayer

    /// Drives the PiP scrubber. Time/rate are pushed from the engine on the main
    /// actor; CMTimebase is internally synchronized so the render queue can read
    /// it while stamping frames.
    nonisolated(unsafe) private let timebase: CMTimebase

    /// Serial queue that owns all frame conversion and enqueue work.
    private let renderQueue = DispatchQueue(
        label: "com.dusk.enhancedpip.samplebuffer",
        qos: .userInitiated
    )

    /// Coalescing inbox: only the most recent frame is kept. Guarded by `frameLock`.
    private let frameLock = NSLock()
    nonisolated(unsafe) private var pendingPixelBuffer: CVPixelBuffer?
    nonisolated(unsafe) private var isDraining = false

    /// Render-queue-owned conversion state (RGBA source bytes -> true BGRA).
    nonisolated(unsafe) private var conversionPool: CVPixelBufferPool?
    nonisolated(unsafe) private var conversionWidth = 0
    nonisolated(unsafe) private var conversionHeight = 0

    override init() {
        let view = VLCKitEnhancedPiPDisplayView()
        self.displayView = view
        self.renderLayer = view.displayLayer

        var createdTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &createdTimebase
        )
        // A timebase is always creatable from the host clock; fall back defensively.
        self.timebase = createdTimebase ?? {
            var fallback: CMTimebase?
            CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &fallback
            )
            return fallback!
        }()

        super.init()

        CMTimebaseSetRate(timebase, rate: 0)
        renderLayer.controlTimebase = timebase

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            enhancedPiPLogger.notice("PiP unsupported on this device; enhanced VLCKit PiP disabled")
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: renderLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        pipController = controller
        possibleObserver = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard let self, self.isPictureInPicturePossible != possible else { return }
                self.isPictureInPicturePossible = possible
                self.onPictureInPicturePossibleChanged?()
            }
        }
    }

    deinit {
        possibleObserver?.invalidate()
    }

    func start() {
        guard let pipController, pipController.isPictureInPicturePossible else { return }
        pipController.startPictureInPicture()
    }

    func stop() {
        pipController?.stopPictureInPicture()
    }

    /// Pushes the engine's current position/rate into the PiP scrubber timebase.
    func updatePlaybackState(currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        let time = CMTime(seconds: max(0, currentTime), preferredTimescale: 600)
        CMTimebaseSetTime(timebase, time: time)
        CMTimebaseSetRate(timebase, rate: isPlaying ? 1 : 0)
        pipController?.invalidatePlaybackState()
    }

    /// Stops accepting frames and clears the display layer. Called on teardown.
    func clear() {
        frameLock.lock()
        pendingPixelBuffer = nil
        frameLock.unlock()
        CMTimebaseSetRate(timebase, rate: 0)
        renderQueue.async { [weak self] in
            self?.renderLayer.flushAndRemoveImage()
        }
    }

    // MARK: - Frame intake (thread-safe)

    /// Thread-safe push from the libvlc video thread. Coalesces to the newest
    /// frame; a single drain runs on `renderQueue`.
    nonisolated func submit(pixelBuffer: CVPixelBuffer) {
        frameLock.lock()
        pendingPixelBuffer = pixelBuffer
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

    nonisolated private func drainPendingFrames() {
        while true {
            frameLock.lock()
            let buffer = pendingPixelBuffer
            pendingPixelBuffer = nil
            if buffer == nil {
                isDraining = false
                frameLock.unlock()
                return
            }
            frameLock.unlock()

            if let buffer {
                enqueueForDisplay(buffer)
            }
        }
    }

    // MARK: - Rendering (render queue)

    nonisolated private func enqueueForDisplay(_ source: CVPixelBuffer) {
        // Recover a failed layer (e.g. after a backgrounding hiccup) so PiP keeps
        // receiving frames.
        if renderLayer.status == .failed {
            renderLayer.flush()
        }
        guard renderLayer.isReadyForMoreMediaData else { return }

        guard let bgra = convertedBGRABuffer(from: source),
              let sampleBuffer = makeSampleBuffer(from: bgra) else {
            return
        }

        renderLayer.enqueue(sampleBuffer)
    }

    /// libvlc hands us RGBA bytes packed into a `32BGRA`-typed pixel buffer (the
    /// Metal shader compensates via a channel-swap flag). The sample-buffer
    /// display layer honors the buffer's declared format, so swap the channels
    /// into a genuine BGRA buffer here — otherwise PiP shows a red/blue-swapped
    /// picture. The enhancement path's own buffer is never mutated.
    nonisolated private func convertedBGRABuffer(from source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0, let pool = pool(width: width, height: height) else {
            return nil
        }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
              let destination else {
            return nil
        }

        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
            return nil
        }

        var src = vImage_Buffer(
            data: sourceBase,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var dst = vImage_Buffer(
            data: destinationBase,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(destination)
        )
        // Source memory order R,G,B,A -> destination B,G,R,A.
        var permuteMap: [UInt8] = [2, 1, 0, 3]
        guard vImagePermuteChannels_ARGB8888(&src, &dst, &permuteMap, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }

        return destination
    }

    nonisolated private func pool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let conversionPool, conversionWidth == width, conversionHeight == height {
            return conversionPool
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else {
            return nil
        }

        conversionPool = pool
        conversionWidth = width
        conversionHeight = height
        return pool
    }

    nonisolated private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        // Stamp with the timebase's current time and force immediate display, so
        // frames appear as they arrive regardless of scrubber timing.
        let presentationTime = CMTimebaseGetTime(timebase)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime.isNumeric ? presentationTime : .zero,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let raw = CFArrayGetValueAtIndex(attachments, 0)
            let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sampleBuffer
    }
}

// MARK: - AVPictureInPictureControllerDelegate

// AVKit invokes these on the main thread; `assumeIsolated` keeps the hops
// synchronous and lets the main-actor state be touched directly, matching
// `AVPlayerEngine`'s PiP delegate.
extension VLCKitEnhancedPictureInPictureOutput: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isPictureInPictureActive = true
            onPictureInPictureActiveChanged?(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isPictureInPictureActive = false
            onPictureInPictureActiveChanged?(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        MainActor.assumeIsolated {
            enhancedPiPLogger.error(
                "Enhanced VLCKit PiP failed to start: \(error.localizedDescription, privacy: .public)"
            )
            isPictureInPictureActive = false
            onPictureInPictureActiveChanged?(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let handler = UncheckedSendableBox(completionHandler)
        MainActor.assumeIsolated {
            if let onRestoreUI {
                onRestoreUI(handler.value)
            } else {
                handler.value(true)
            }
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension VLCKitEnhancedPictureInPictureOutput: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        MainActor.assumeIsolated {
            playbackDelegate?.enhancedPiPSetPlaying(playing)
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        MainActor.assumeIsolated {
            let duration = playbackDelegate?.enhancedPiPDuration ?? 0
            guard duration > 0 else {
                // Unknown duration (e.g. live) — open-ended range from the current time.
                let now = CMTimebaseGetTime(timebase)
                return CMTimeRange(start: now.isNumeric ? now : .zero, duration: .positiveInfinity)
            }
            return CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            )
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        MainActor.assumeIsolated {
            !(playbackDelegate?.enhancedPiPIsPlaying ?? false)
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let seconds = CMTimeGetSeconds(skipInterval)
        let handler = UncheckedSendableBox(completionHandler)
        MainActor.assumeIsolated {
            guard let playbackDelegate, seconds.isFinite else {
                handler.value()
                return
            }
            playbackDelegate.enhancedPiPSkip(by: seconds) {
                handler.value()
            }
        }
    }
}
#endif
