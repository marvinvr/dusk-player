#if canImport(MobileVLCKit)
import MobileVLCKit
#elseif canImport(TVVLCKit)
import TVVLCKit
#endif
#if canImport(MobileVLCKit) || canImport(TVVLCKit)
import AVFoundation
import CoreVideo
import OSLog
import SwiftUI
import UIKit
#endif

#if canImport(MobileVLCKit) || canImport(TVVLCKit)
private let vlcKitEngineLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "VLCKitEngine"
)

/// Bridges libvlc's internal log stream into the unified logger (category
/// "libvlc") so TestFlight/device sessions can be diagnosed from Console.app
/// or a sysdiagnose without a debugger. VLCKit DROPS all libvlc messages
/// unless a logger is attached — which is why no on-device trace of the
/// audio output's actual behavior ("deferring start", "playback way too
/// late", session activation failures, output restarts) has ever been
/// available while chasing the silent-audio bugs.
///
/// Volume control: errors and warnings always pass (rare, and exactly the
/// audio/clock complaints that matter). Info/debug chatter passes only for
/// audio/clock-related emitters and messages. The `vlcVerboseLogging` user
/// default opens the full firehose for a deep capture without rebuilding.
/// Everything is emitted at .notice or above so it persists to the log
/// store (OSLog .info/.debug are memory-only by default and would be
/// missing from a sysdiagnose).
private final class VLCLibraryLogBridge: NSObject, VLCLogging, @unchecked Sendable {
    nonisolated(unsafe) static let shared = VLCLibraryLogBridge()

    var level: VLCLogLevel = .debug

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
        category: "libvlc"
    )
    private let verbose = UserDefaults.standard.bool(forKey: "vlcVerboseLogging")

    func handleMessage(
        _ message: String,
        logLevel: VLCLogLevel,
        context: VLCLogContext?
    ) {
        let module = context?.module ?? ""
        let objectType = context?.objectType ?? ""

        guard verbose
            || logLevel == .error
            || logLevel == .warning
            || Self.isAudioPipelineRelated(
                module: module, objectType: objectType, message: message
            ) else {
            return
        }

        let line = "[\(module)/\(objectType)] \(message)"
        switch logLevel {
        case .error:
            logger.error("\(line, privacy: .public)")
        case .warning:
            logger.warning("\(line, privacy: .public)")
        default:
            logger.notice("\(line, privacy: .public)")
        }
    }

    /// Emitters and phrases covering the audio output, the aout core, the
    /// clock, ES selection, and the session/interruption handling — the
    /// complete "why is there no sound" surface.
    private static func isAudioPipelineRelated(
        module: String,
        objectType: String,
        message: String
    ) -> Bool {
        if module.contains("audiounit") || module.contains("avsamplebuffer")
            || module.contains("aout") {
            return true
        }
        if objectType.contains("audio") {
            return true
        }

        let phrases = [
            "audio", "aout", "deferring start", "starting late", "clamping",
            "playback way too", "playback too", "underrun", "drift",
            "master clock", "resetting", "interruption", "AVAudioSession",
            "restarting output", "restart requested", "silence", "es out",
            "selecting", "mute", "volume",
        ]
        for phrase in phrases where message.localizedCaseInsensitiveContains(phrase) {
            return true
        }
        return false
    }
}

/// Platform renderer contract for the shared VLCKit playback core.
protocol VLCKitRenderingHost: AnyObject, Sendable {
    var playerView: UIView { get }

    func attach(to player: VLCMediaPlayer, engine: VLCKitEngine)
    func detach(from player: VLCMediaPlayer)
    func updatePlaybackState(
        currentTimeMs: Int64,
        durationMs: Int64,
        isPlaying: Bool,
        isSeekable: Bool
    )
    func invalidatePlaybackState()
    func setVideoFillEnabled(_ enabled: Bool)
}

@MainActor
private func makeVLCKitRenderingHost() -> any VLCKitRenderingHost {
    #if os(iOS)
    IOSVLCKitRenderingHost()
    #elseif os(tvOS)
    TVOSVLCKitRenderingHost()
    #else
    fatalError("VLCKit is not supported on this platform")
    #endif
}

private final class VLCKitVideoEnhancementFrameSink: NSObject, DuskVLCVideoFrameConsumer, @unchecked Sendable {
    nonisolated(unsafe) private weak var renderer: VideoEnhancementRenderer?
    #if os(iOS)
    /// Tee target for Picture in Picture. The same decoded frames feed a native
    /// sample-buffer PiP window (non-upscaled) alongside the Metal upscaler.
    nonisolated(unsafe) weak var pictureInPictureOutput: VLCKitEnhancedPictureInPictureOutput?
    #endif

    /// `renderer` is nil in Picture in Picture support mode, where the raw tap
    /// exists purely to feed the sample-buffer output (no Metal upscaling).
    init(renderer: VideoEnhancementRenderer?) {
        self.renderer = renderer
        super.init()
    }

    nonisolated func duskVLCVideoOutputDidProduce(_ pixelBuffer: CVPixelBuffer) {
        if let renderer {
            let frame = VideoEnhancementFrame(
                retaining: pixelBuffer,
                channelLayout: .rgbaBytesInBGRA
            )
            // Coalesce on the renderer instead of queueing a main-actor task per
            // frame: under GPU load this drops stale frames rather than letting an
            // unbounded backlog push the video into slow motion behind the audio.
            renderer.enqueue(frame: frame)
        }
        #if os(iOS)
        // Same coalescing discipline for the PiP feed (see the output class).
        pictureInPictureOutput?.submit(pixelBuffer: pixelBuffer)
        #endif
    }
}

/// PlaybackEngine implementation backed by the stable VLCKit 3.x line
/// (MobileVLCKit on iOS/iPadOS, TVVLCKit on tvOS).
///
/// Shared playback logic lives here. Platform-specific rendering behavior
/// lives in `VLCKitRendererIOS.swift` and `VLCKitRendererTVOS.swift`.
@MainActor
@Observable
final class VLCKitEngine: NSObject, PlaybackEngine {
    private static let seekSettleDelay: Duration = .milliseconds(150)
    private static let seekRetryDelay: Duration = .milliseconds(450)
    private static let pendingSeekTolerance: TimeInterval = 1.0
    private static let pendingSeekStaleUpdateWindow: TimeInterval = 1.5

    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isBuffering = false
    private(set) var error: PlaybackError?
    private(set) var availableSubtitleTracks: [SubtitleTrack] = []
    private(set) var availableAudioTracks: [AudioTrack] = []
    private(set) var selectedSubtitleTrackID: Int?
    private(set) var selectedAudioTrackID: Int?
    private(set) var playbackDiagnostics: [PlaybackEngineDiagnostic] = []
    var videoEnhancementStatus: VideoEnhancementStatus {
        if let videoEnhancementRenderer {
            return videoEnhancementRenderer.status
        }
        return videoEnhancementRequest.isPotentiallyEnabled
            ? VideoEnhancementStatus(
                state: .unavailable,
                reason: videoEnhancementRequest.preflightUnavailabilityReason ?? "Metal unavailable"
            )
            : .disabled
    }
    var onPlaybackEnded: (@MainActor () -> Void)?

    // VLCKit feeds iOS a raw audio stream that the `.moviePlayback` spatializer
    // keeps re-negotiating on a Bluetooth route, underrunning the output and
    // stuttering the sound. Opt out of the spatialized session for a plain one.
    var prefersSpatializedAudioSession: Bool { false }

    #if os(iOS)
    private(set) var isPictureInPicturePossible = false
    private(set) var isPictureInPictureActive = false
    @ObservationIgnored private weak var pictureInPictureDelegate: (any PlaybackPictureInPictureDelegate)?
    /// Native sample-buffer PiP output. Present while Video Enhancement's raw
    /// frame tap is active, or while the on-demand PiP support mode below is.
    @ObservationIgnored private var enhancedPictureInPictureOutput: VLCKitEnhancedPictureInPictureOutput?
    /// On-demand Picture in Picture for plain (non-enhanced) sessions.
    /// VLCKit 3.x has no drawable-native PiP and libvlc has exactly one video
    /// output, so the button tap swaps the whole rendering pipeline: the raw
    /// frame tap is attached, the sample-buffer layer becomes the PRIMARY
    /// on-screen surface, media reloads in place at the current position
    /// (raw callbacks must be installed before play), and PiP auto-starts
    /// once the system controller reports possible. The mode persists for the
    /// rest of the session — switching back would be another visible reload.
    @ObservationIgnored private var isPipSupportModeActive = false
    /// Set while a support-mode start is waiting for the controller to become
    /// possible after the pipeline swap; consumed by `refreshPictureInPicturePossible`.
    @ObservationIgnored private var pendingPictureInPictureStart = false
    #endif
    /// Bumped whenever `makePlayerView()` would return a different view
    /// (entering PiP support mode); `PlayerViewModel` re-fetches the view.
    private(set) var playerViewGeneration = 0

    nonisolated(unsafe) private let mediaPlayer: VLCMediaPlayer
    private let renderingHost: any VLCKitRenderingHost

    private var pendingStartPosition: TimeInterval?
    private var hasAppliedStartPosition = false
    private var hasReportedPlaybackEnded = false
    private var suppressPlaybackEndedEvent = false
    private var ignoreNextStoppedEvent = false
    private var pendingSeekTarget: TimeInterval?
    /// Count of consecutive accepted, advancing time updates while playing
    /// with no seek in flight. Reset by anything that truly disturbs the
    /// pipeline (load, seek, pause, stall recovery) — but deliberately NOT
    /// by buffering state events and NOT gated on `isBuffering`: libvlc
    /// emits buffering events continuously on network streams (cache-level
    /// churn), which kept this counter pinned at zero forever — device logs
    /// proved the audio revive and the automatic track selection never ran
    /// at all on network playback. Advancing time IS the proof the pipeline
    /// is rendering; a real refill freezes the clock and stops the count on
    /// its own.
    private var steadyPlaybackTicks = 0
    private var pendingSeekStartedAt: Date?
    /// One-shot: an audio-output disturbance (load, stall recovery, or a
    /// seek — every seek flushes the output) schedules a single pause→play
    /// "revive" once playback is up. The vendored libvlc patches recover
    /// every *detectable* audio failure, but the iOS AudioUnit output still
    /// has states where it renders silence while reporting success, and
    /// neither libvlc nor the app can observe them. The only universal cure
    /// is the pause→resume cycle (AudioOutputUnitStop → session
    /// reactivation → AudioOutputUnitStart → render unlatch, plus a fresh
    /// timing report that re-syncs the master clock).
    ///
    /// The revive is CLOSED-LOOP: every step waits for libvlc's own state
    /// confirmation instead of racing it with wall-clock timers (an
    /// open-loop pause → sleep → play provably lost the race on slow
    /// connections: the timed play was processed before the pause, which
    /// then confirmed afterwards and stranded the player paused). Phases:
    /// pause issued → wait for the .paused event → gap → play issued →
    /// wait for the .playing event (stray late pauses are re-played,
    /// bounded). The only timers are failsafes whose expiry action is safe
    /// and idempotent in every ordering.
    private enum AudioRevivePhase {
        case inactive
        case awaitingPauseConfirmation
        case awaitingResumeConfirmation
    }

    private var needsSettleAudioRevive = false
    private var audioRevivePhase: AudioRevivePhase = .inactive
    private var audioReviveResumeAttempts = 0
    /// While true (initial bring-up only, not seeks), the engine reports
    /// `.loading` instead of `.playing` until the revive completes, so the
    /// whole warmup — including the pause→resume — reads as load time and
    /// the UI never sees a play→pause→play flap.
    private var isInitialAudioWarmup = false
    /// Raw "libvlc reported playing" flag, independent of the masked
    /// user-facing `state`. Drives the revive machinery.
    private var vlcReportedPlaying = false
    private var lastAudioReviveAt: Date?
    @ObservationIgnored nonisolated(unsafe) private var audioReviveTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var audioInterruptionWatchdogTask: Task<Void, Never>?
    private var currentAttemptContext: PlaybackAttemptContext?
    private var currentSource: PlaybackSource?
    private var lastAppliedAudioConfigSignature: String?
    // VLCKit 3 identifies player tracks by libvlc elementary-stream indexes,
    // which are only unique per track kind. Key them as "audio/<index>" /
    // "spu/<index>" and map each key to a stable unique Int for the
    // `AudioTrack`/`SubtitleTrack` models, and back for selection.
    private var trackIDsByModelID: [Int: String] = [:]
    private var modelIDsByTrackID: [String: Int] = [:]
    private var nextTrackModelID = 1
    /// Metadata for the current audio track list, keyed by ES index. Feeds the
    /// audio-output policy and diagnostics (VLCKit 3 exposes codec/channel data
    /// only through `VLCMedia.tracksInformation`, not on the player).
    private var latestAudioTrackInfosByIndex: [Int: VLCTrackInfo] = [:]
    /// Last seen (audio, text) track counts; see `refreshTracksIfCountsChanged`.
    private var lastObservedTrackCounts: (audio: Int32, text: Int32) = (-1, -1)
    @ObservationIgnored nonisolated(unsafe) private var audioSessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored nonisolated(unsafe) private var seekVerificationTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var loadValidationTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var videoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsVideoRefreshOnPlay = false
    @ObservationIgnored private var videoEnhancementRequest: VideoEnhancementRequest = .disabled
    @ObservationIgnored private var videoEnhancementRenderer: VideoEnhancementRenderer?
    @ObservationIgnored nonisolated(unsafe) private var rawVideoFrameSink: VLCKitVideoEnhancementFrameSink?
    @ObservationIgnored nonisolated(unsafe) private var rawVideoOutput: DuskVLCRawVideoOutput?

    /// Shared libvlc instance. On the stable 3.x line the iOS/tvOS audio
    /// output IS the classic pull-model AudioUnit module — the
    /// `avsamplebuffer` output that libvlc 4.0-dev defaulted to (and whose
    /// clock drift caused the cyclic audio dropouts documented in
    /// docs/audio-silence-postmortem.md) does not exist on this branch, so no
    /// `--aout` pin or A/B toggle is needed.
    nonisolated(unsafe) private static let sharedLibrary: VLCLibrary = {
        let library = VLCLibrary(options: [])
        library.loggers = [VLCLibraryLogBridge.shared]
        return library
    }()

    /// Master switch for the pause→play audio revive machinery below.
    ///
    /// The revive was built against libvlc 4.0-dev's rewritten audio output,
    /// which could latch into rendering silence while reporting success (see
    /// docs/audio-silence-postmortem.md). The vendored stable 3.x line uses
    /// the field-proven audiounit output that has shown none of those states,
    /// so the machinery is DORMANT by default and kept only as a safety net —
    /// set the `vlcAudioReviveEnabled` user default to re-arm it without a
    /// rebuild if silent playback is ever observed on this stack.
    private static var isAudioReviveEnabled: Bool {
        UserDefaults.standard.bool(forKey: "vlcAudioReviveEnabled")
    }

    /// Audit of the VLCKit binary actually loaded into THIS process. Xcode's
    /// framework-embed step can silently reuse a stale cached copy when a
    /// checked-in binary is replaced in-place — device builds have shipped
    /// outdated VLCKit while the repo contained a newer one, making fixes
    /// look ineffective (see docs/audio-silence-postmortem.md). Build-time
    /// staleness is caught by scripts/verify_embedded_vlckit.sh (Mach-O UUID
    /// compare against Frameworks/); this runtime audit reports the loaded
    /// libvlc version so Playback Info can state definitively which build is
    /// running.
    static let vendoredVLCKitAudit: (isExpectedBuild: Bool, detail: String) = {
        let version = sharedLibrary.version
        if version.hasPrefix("3.0.") {
            return (true, "Stable VLCKit 3.x (libvlc \(version))")
        }
        return (false, "UNEXPECTED build (libvlc \(version)) — expected the stable 3.x line; clean build / reinstall")
    }()

    override init() {
        let player = VLCMediaPlayer(library: Self.sharedLibrary)
        let renderingHost = makeVLCKitRenderingHost()
        self.mediaPlayer = player
        self.renderingHost = renderingHost
        super.init()

        player.delegate = self
        renderingHost.attach(to: player, engine: self)
        configureAudioOutputPolicy()
        registerAudioSessionObserversIfNeeded()

        let audit = Self.vendoredVLCKitAudit
        if audit.isExpectedBuild {
            vlcKitEngineLogger.notice("VLCKit audit: \(audit.detail, privacy: .public)")
        } else {
            vlcKitEngineLogger.error("VLCKit audit: \(audit.detail, privacy: .public)")
        }
    }

    deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        loadValidationTask?.cancel()
        seekVerificationTask?.cancel()
        videoRefreshTask?.cancel()
        audioReviveTask?.cancel()
        audioInterruptionWatchdogTask?.cancel()
        mediaPlayer.stop()
        rawVideoOutput?.detach()
        mediaPlayer.delegate = nil
        renderingHost.detach(from: mediaPlayer)
    }

    func load(source: PlaybackSource) {
        loadValidationTask?.cancel()
        videoRefreshTask?.cancel()
        videoRefreshTask = nil
        cancelAudioRevive()
        armSettleAudioRevive(initialBringUp: true)
        vlcReportedPlaying = false
        #if os(iOS)
        // A new source starts on the native drawable; PiP support mode is
        // re-entered on demand.
        tearDownPictureInPictureSupportModeIfNeeded()
        #endif
        rawVideoOutput?.detach()
        currentAttemptContext = source.context
        currentSource = source
        state = .loading
        isBuffering = true
        error = nil
        currentTime = 0
        duration = 0
        hasAppliedStartPosition = false
        hasReportedPlaybackEnded = false
        suppressPlaybackEndedEvent = false
        ignoreNextStoppedEvent = false
        clearPendingSeek()
        pendingStartPosition = source.startPosition
        steadyPlaybackTicks = 0
        availableSubtitleTracks = []
        availableAudioTracks = []
        selectedSubtitleTrackID = nil
        selectedAudioTrackID = nil
        playbackDiagnostics = []
        lastAppliedAudioConfigSignature = nil
        trackIDsByModelID = [:]
        modelIDsByTrackID = [:]
        nextTrackModelID = 1
        latestAudioTrackInfosByIndex = [:]
        lastObservedTrackCounts = (-1, -1)
        syncRendererPlaybackState()

        vlcKitEngineLogger.notice(
            "Playback attempt \(source.context.attemptLabel, privacy: .public) starting in VLCKit for ratingKey \(source.context.ratingKey, privacy: .public), media \(source.context.mediaID, privacy: .public), part \(source.context.partID, privacy: .public), URL \(source.context.sanitizedPlaybackURL, privacy: .public)"
        )

        let attemptID = source.context.attemptID
        loadValidationTask = Task { [weak self] in
            guard let self else { return }

            if let validationError = await PlaybackError.validateDirectPlayURL(source.url) {
                guard !Task.isCancelled else { return }
                self.failLoad(
                    validationError,
                    attemptID: attemptID,
                    message: "VLCKit direct-play validation failed"
                )
                return
            }

            guard !Task.isCancelled else { return }
            self.finishValidatedLoad(source: source, attemptID: attemptID)
        }
    }

    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {
        #if os(iOS)
        tearDownPictureInPictureSupportModeIfNeeded()
        #endif
        videoEnhancementRequest = request
        videoEnhancementRenderer = VideoEnhancementRenderer(request: request)

        if let videoEnhancementRenderer {
            renderingHost.detach(from: mediaPlayer)
            let frameSink = VLCKitVideoEnhancementFrameSink(renderer: videoEnhancementRenderer)
            rawVideoFrameSink = frameSink
            // Detach before replacing: a dropped-but-still-attached output keeps
            // feeding the renderer it was built for.
            rawVideoOutput?.detach()
            rawVideoOutput = DuskVLCRawVideoOutput(frameConsumer: frameSink)
            #if os(iOS)
            configureEnhancedPictureInPicture(frameSink: frameSink)
            #endif
        } else {
            rawVideoOutput?.detach()
            rawVideoOutput = nil
            rawVideoFrameSink = nil
            #if os(iOS)
            teardownEnhancedPictureInPicture()
            #endif
            renderingHost.attach(to: mediaPlayer, engine: self)
        }
    }

    func play() {
        let wasPaused = state == .paused
        if wasPaused {
            // A real pause→resume already re-runs the session-activation +
            // AudioOutputUnitStart sequence — the exact cure the pending
            // revive would perform — so a second cycle is redundant.
            needsSettleAudioRevive = false
            isInitialAudioWarmup = false
        }
        suppressPlaybackEndedEvent = false
        mediaPlayer.play()
        if wasPaused || needsVideoRefreshOnPlay {
            if needsVideoRefreshOnPlay {
                needsVideoRefreshOnPlay = false
                refreshVideoOutputAfterResume()
            }
            scheduleVideoOutputRefreshAfterResume()
        }
        syncRendererPlaybackState()
    }

    func pause() {
        // User intent wins over an in-flight revive: tear its sequence down
        // (without consuming a still-pending arm — the resume on the user's
        // own play() consumes it, having run the same cure natively).
        cancelAudioReviveSequence()
        seekVerificationTask?.cancel()
        seekVerificationTask = nil
        videoRefreshTask?.cancel()
        videoRefreshTask = nil
        mediaPlayer.pause()
        state = .paused
        steadyPlaybackTicks = 0
        syncRendererPlaybackState()
    }

    func stop() {
        loadValidationTask?.cancel()
        loadValidationTask = nil
        videoRefreshTask?.cancel()
        videoRefreshTask = nil
        cancelAudioRevive()
        clearPendingSeek()
        suppressPlaybackEndedEvent = true
        ignoreNextStoppedEvent = false
        mediaPlayer.stop()
        rawVideoOutput?.detach()
        #if os(iOS)
        tearDownPictureInPictureSupportModeIfNeeded()
        #endif
        videoEnhancementRenderer?.clear()
        state = .stopped
        hasReportedPlaybackEnded = false
        playbackDiagnostics = []
        currentAttemptContext = nil
        currentSource = nil
        syncRendererPlaybackState()
    }

    func handleReturnToForeground() {
        #if os(iOS)
        // VLCKit ignores track re-selection while paused, so defer the
        // video output refresh until play() is called.
        needsVideoRefreshOnPlay = true
        #endif
    }

    func setVideoFillEnabled(_ enabled: Bool) {
        // With Video Enhancement active the picture is drawn by the Metal
        // renderer; otherwise VLCKit draws straight into the rendering host and
        // the crop is applied there. Forward to both so whichever path is live
        // honors the zoom (the inactive one no-ops).
        videoEnhancementRenderer?.setVideoFillEnabled(enabled)
        renderingHost.setVideoFillEnabled(enabled)
    }

    #if os(iOS)
    // MARK: - Picture in Picture

    /// VLCKit 3.x has no drawable-native Picture in Picture (that was a 4.x
    /// feature). The sample-buffer output built for the Video Enhancement path
    /// (`VLCKitEnhancedPictureInPictureOutput`, a real
    /// `AVPictureInPictureController` over an `AVSampleBufferDisplayLayer`) is
    /// the only PiP surface for VLC sessions, so PiP is possible exactly when
    /// Video Enhancement's raw frame tap is active.
    func setPictureInPictureDelegate(_ delegate: (any PlaybackPictureInPictureDelegate)?) {
        pictureInPictureDelegate = delegate
    }

    func startPictureInPicture() {
        if let enhancedPictureInPictureOutput,
           enhancedPictureInPictureOutput.isPictureInPicturePossible {
            enhancedPictureInPictureOutput.start()
            return
        }
        guard canEnterPictureInPictureSupportMode, !isPipSupportModeActive else { return }
        enterPictureInPictureSupportMode()
    }

    func stopPictureInPicture() {
        enhancedPictureInPictureOutput?.stop()
    }

    /// A plain session can enter support mode whenever media is loaded and
    /// playback is not torn down; the reload resumes from the live position.
    private var canEnterPictureInPictureSupportMode: Bool {
        currentSource != nil && state != .idle && state != .stopped && state != .error
    }

    private func enterPictureInPictureSupportMode() {
        vlcKitEngineLogger.notice("VLCKit entering PiP support mode (pipeline swap + in-place reload)")
        isPipSupportModeActive = true
        pendingPictureInPictureStart = true

        let frameSink = VLCKitVideoEnhancementFrameSink(renderer: nil)
        rawVideoFrameSink = frameSink
        rawVideoOutput?.detach()
        rawVideoOutput = DuskVLCRawVideoOutput(frameConsumer: frameSink)
        configureEnhancedPictureInPicture(frameSink: frameSink)
        // The sample-buffer layer is the visible surface in this mode, so the
        // intake must run at full rate even while the floating window is closed.
        enhancedPictureInPictureOutput?.isPrimaryDisplaySurface = true
        renderingHost.detach(from: mediaPlayer)
        playerViewGeneration += 1

        // Same in-place reload as stall recovery: raw video callbacks only
        // take effect on a fresh input, and this resumes at the live position.
        recoverFromStall()
    }

    private func tearDownPictureInPictureSupportModeIfNeeded() {
        guard isPipSupportModeActive else {
            pendingPictureInPictureStart = false
            return
        }
        isPipSupportModeActive = false
        pendingPictureInPictureStart = false
        rawVideoOutput?.detach()
        rawVideoOutput = nil
        rawVideoFrameSink = nil
        teardownEnhancedPictureInPicture()
        renderingHost.attach(to: mediaPlayer, engine: self)
        playerViewGeneration += 1
    }

    /// Builds the sample-buffer PiP output for the Video Enhancement path and
    /// bridges its readiness/active/restore events into the engine's observable
    /// PiP state and the coordinator delegate.
    private func configureEnhancedPictureInPicture(frameSink: VLCKitVideoEnhancementFrameSink) {
        // Any previous output has to be cleared before it is dropped, or its
        // render queue can outlive it and run `deinit` off the main thread.
        enhancedPictureInPictureOutput?.clear()
        let output = VLCKitEnhancedPictureInPictureOutput()
        output.playbackDelegate = self
        output.onPictureInPicturePossibleChanged = { [weak self] in
            self?.refreshPictureInPicturePossible()
        }
        output.onPictureInPictureActiveChanged = { [weak self] isActive in
            guard let self else { return }
            self.isPictureInPictureActive = isActive
            self.pictureInPictureDelegate?.pictureInPictureActiveDidChange(isActive)
        }
        output.onRestoreUI = { [weak self] completion in
            guard let self, let delegate = self.pictureInPictureDelegate else {
                completion(true)
                return
            }
            delegate.pictureInPictureRestorePlayerUI(completion: completion)
        }
        frameSink.pictureInPictureOutput = output
        enhancedPictureInPictureOutput = output
        refreshPictureInPicturePossible()
    }

    private func teardownEnhancedPictureInPicture() {
        enhancedPictureInPictureOutput?.clear()
        enhancedPictureInPictureOutput = nil
        isPictureInPictureActive = false
        refreshPictureInPicturePossible()
    }

    private func refreshPictureInPicturePossible() {
        let outputPossible = enhancedPictureInPictureOutput?.isPictureInPicturePossible ?? false
        // Plain sessions show the button too: tapping it enters support mode.
        let newValue = outputPossible || canEnterPictureInPictureSupportMode
        if isPictureInPicturePossible != newValue {
            isPictureInPicturePossible = newValue
        }
        if outputPossible, pendingPictureInPictureStart {
            pendingPictureInPictureStart = false
            enhancedPictureInPictureOutput?.start()
        }
    }
    #endif

    func seek(to position: TimeInterval) {
        let clampedPosition: TimeInterval
        if duration > 0 {
            clampedPosition = min(max(position, 0), duration)
        } else {
            clampedPosition = max(position, 0)
        }

        vlcKitEngineLogger.notice(
            "VLCKit seek to \(clampedPosition, format: .fixed(precision: 1), privacy: .public)s (state=\(String(describing: self.state), privacy: .public), buffering=\(self.isBuffering, privacy: .public))"
        )
        pendingSeekTarget = clampedPosition
        pendingSeekStartedAt = Date()
        currentTime = clampedPosition
        steadyPlaybackTicks = 0
        // Every seek flushes the audio output; if the flush leaves it in a
        // silent-but-"healthy" state, the settle revive brings it back once
        // playback is steady again (one revive per burst of seeks — arming is
        // idempotent and the progress clock restarts after the last seek).
        armSettleAudioRevive()

        // Seek without pausing — pausing first creates a race between
        // VLCKit's asynchronous state callbacks and the timed resume,
        // which can leave the player stuck in a paused state.
        applySeek(to: clampedPosition)
        scheduleSeekVerification(target: clampedPosition)
        syncRendererPlaybackState()
    }

    func recoverFromStall() {
        guard let source = currentSource else {
            mediaPlayer.play()
            return
        }

        let recoveryPosition = recoveryStartPosition(for: source)
        if let currentAttemptContext {
            vlcKitEngineLogger.notice(
                "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) VLCKit recovering stalled playback at \(recoveryPosition, privacy: .public)s"
            )
        }

        loadValidationTask?.cancel()
        videoRefreshTask?.cancel()
        videoRefreshTask = nil
        cancelAudioRevive()
        armSettleAudioRevive(initialBringUp: true)
        vlcReportedPlaying = false
        clearPendingSeek()
        suppressPlaybackEndedEvent = true
        ignoreNextStoppedEvent = true
        mediaPlayer.stop()
        rawVideoOutput?.detach()
        suppressPlaybackEndedEvent = false

        error = nil
        state = .loading
        isBuffering = true
        pendingStartPosition = recoveryPosition
        hasAppliedStartPosition = recoveryPosition <= 0
        steadyPlaybackTicks = 0
        hasReportedPlaybackEnded = false
        availableSubtitleTracks = []
        availableAudioTracks = []
        selectedSubtitleTrackID = nil
        selectedAudioTrackID = nil
        playbackDiagnostics = []
        syncRendererPlaybackState()

        finishValidatedLoad(source: source, attemptID: source.context.attemptID)
    }

    func selectSubtitleTrack(_ track: SubtitleTrack?) {
        guard let track else {
            mediaPlayer.currentVideoSubTitleIndex = -1
            selectedSubtitleTrackID = nil
            return
        }

        if let index = vlcTrackIndex(forModelID: track.id) {
            mediaPlayer.currentVideoSubTitleIndex = Int32(index)
        }
        selectedSubtitleTrackID = track.id
    }

    func selectAudioTrack(_ track: AudioTrack) {
        if let index = vlcTrackIndex(forModelID: track.id) {
            mediaPlayer.currentAudioTrackIndex = Int32(index)
        }
        selectedAudioTrackID = track.id
        configureAudioOutputPolicy(reason: "audio-track-selected")
    }

    /// Track model IDs map to engine-local keys like "audio/3"/"spu/2"; the
    /// numeric part is the libvlc elementary-stream index used for selection.
    private func vlcTrackIndex(forModelID id: Int) -> Int? {
        guard let key = trackIDsByModelID[id],
              let last = key.split(separator: "/").last else { return nil }
        return Int(last)
    }

    /// Automatic audio selection must wait for steady-state playback. Switching
    /// the audio ES makes libvlc restart the audio output for the input format
    /// change (e.g. TrueHD 7.1 → AC-3 5.1); if that restart lands inside the
    /// startup window — output bring-up, passthrough probing, audio session
    /// activation, the resume seek's flush — a failed `aout_OutputNew` marks
    /// the stream dead (`mixer_format.i_format = 0`) and libvlc never retries:
    /// video plays, audio is simply absent until a pause/resume forces another
    /// restart. Note this is only the SAFETY NET: the preferred track is
    /// normally preselected via the `:audio-track` media option before play
    /// (`PlaybackSource.preferredAudioTrackPosition`), so no switch happens at
    /// all. Steady state means: actually playing, not buffering, the pending
    /// start-position seek issued AND settled, and several consecutive
    /// advancing time ticks observed (~1s at the 250 ms cadence; the counter
    /// resets on load/seek/pause/buffering) — i.e. the pipeline has
    /// demonstrably been rendering for a while, the same conditions under
    /// which manual track switches are reliable.
    var isReadyForAutomaticAudioSelection: Bool {
        // Deliberately NOT gated on `isBuffering`: libvlc's continuous
        // buffering events on network streams kept that flag flapping and
        // this gate closed forever (device logs showed the safety net never
        // ran). Advancing time — steadyPlaybackTicks — is the real signal.
        guard state == .playing else { return false }
        guard hasAppliedStartPosition || (pendingStartPosition ?? 0) <= 0 else { return false }
        // Let the settle audio revive finish first so a safety-net ES
        // switch (an audio-output restart) never interleaves with it.
        guard !needsSettleAudioRevive, audioRevivePhase == .inactive else { return false }
        return pendingSeekTarget == nil && steadyPlaybackTicks >= 4
    }

    func makePlayerView() -> AnyView {
        if let videoEnhancementRenderer {
            #if os(iOS)
            if let enhancedPictureInPictureOutput {
                // Keep the PiP sample-buffer layer in the hierarchy (occluded by
                // the opaque Metal view) so native PiP stays possible while the
                // upscaled picture is shown full-screen.
                return AnyView(
                    ZStack {
                        VLCEnhancedPiPDisplayRepresentable(
                            displayView: enhancedPictureInPictureOutput.displayView
                        )
                        VideoEnhancementRepresentable(renderer: videoEnhancementRenderer)
                    }
                )
            }
            #endif
            return AnyView(VideoEnhancementRepresentable(renderer: videoEnhancementRenderer))
        }
        #if os(iOS)
        if isPipSupportModeActive, let enhancedPictureInPictureOutput {
            // PiP support mode: the sample-buffer layer IS the on-screen
            // surface (libvlc's one video output feeds the raw tap).
            return AnyView(
                VLCEnhancedPiPDisplayRepresentable(
                    displayView: enhancedPictureInPictureOutput.displayView
                )
            )
        }
        #endif
        return AnyView(VLCPlayerRepresentable(playerView: renderingHost.playerView))
    }

    fileprivate func handleStateChange(_ vlcState: VLCMediaPlayerState) {
        logStateChange(vlcState)
        switch vlcState {
        case .opening, .buffering:
            // Do NOT reset steadyPlaybackTicks here: libvlc fires buffering
            // events continuously on network streams (cache-level updates),
            // which permanently zeroed the counter and disabled everything
            // gated on it. A genuine refill freezes the reported time, which
            // stops the counter by itself.
            isBuffering = true
            if state != .playing && state != .paused {
                state = .loading
            }

        case .playing:
            isBuffering = false
            vlcReportedPlaying = true
            suppressPlaybackEndedEvent = false
            configureAudioOutputPolicy(reason: "entered-playing-state")

            if !hasAppliedStartPosition, let start = pendingStartPosition, start > 0 {
                hasAppliedStartPosition = true
                // The start position was normally applied while the input was
                // still opening (see finishValidatedLoad), before the audio
                // output existed. Only fall back to the legacy post-start
                // seek when that early seek demonstrably did not land —
                // seeking here flushes the audio output in the middle of its
                // bring-up, the most fragile moment of the whole session.
                if abs(observedPlayerTime - start) > Self.pendingSeekTolerance {
                    seek(to: start)
                }
            }

            switch audioRevivePhase {
            case .awaitingResumeConfirmation:
                // libvlc confirmed our post-revive play: the cure completed.
                completeAudioRevive()
            case .awaitingPauseConfirmation:
                // Our pause is still in flight (e.g. a buffering→playing
                // emission overtook it); keep waiting for the .paused event.
                break
            case .inactive:
                // Event-driven revive hook for SEEK revives (far seeks that
                // refill emit buffering→playing). Deliberately NOT used for
                // the initial warmup: firing the cure at the first .playing
                // proved too early on device — the silent state forms during
                // the first ~second of rendering, and a cure that runs
                // before it exists cures nothing. Warmup waits for confirmed
                // rendering progress in updateTime instead (empirically
                // reliable; the latency hides behind the loading mask).
                if needsSettleAudioRevive, !isInitialAudioWarmup, pendingSeekTarget == nil {
                    beginAudioRevive(reason: "entered-playing")
                }
            }

            // During the initial warmup the user-facing state stays .loading
            // until the revive has completed, so the pause→resume cure is
            // absorbed into perceived load time instead of flashing
            // play→pause→play in the UI.
            state = isAudioWarmupMasking ? .loading : .playing

            refreshTracks()

        case .paused:
            isBuffering = false
            vlcReportedPlaying = false
            switch audioRevivePhase {
            case .awaitingPauseConfirmation:
                // libvlc confirmed our revive pause — only NOW schedule the
                // resume. The resume physically cannot overtake the pause,
                // regardless of connection speed or queue latency.
                scheduleAudioReviveResume()
            case .awaitingResumeConfirmation:
                // A stray/late pause surfaced after our play was issued
                // (event raced the resume). Re-play, bounded.
                enforceAudioReviveResume()
            case .inactive:
                state = .paused
            }

        case .ended:
            // libvlc 3 signals natural end-of-stream explicitly (followed by
            // a .stopped event, which the flag below swallows).
            isBuffering = false
            vlcReportedPlaying = false
            cancelAudioReviveSequence()
            state = .stopped
            clearPendingSeek()
            ignoreNextStoppedEvent = true

            if !suppressPlaybackEndedEvent {
                currentTime = max(currentTime, duration)
                if !hasReportedPlaybackEnded {
                    hasReportedPlaybackEnded = true
                    if let currentAttemptContext {
                        vlcKitEngineLogger.notice(
                            "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) VLCKit reached end of playback"
                        )
                    }
                    onPlaybackEnded?()
                }
            }
            suppressPlaybackEndedEvent = false

        case .esAdded:
            // Elementary stream added — the 3.x signal that the track lists
            // changed (this branch has no per-track delegate callbacks).
            refreshTracks()

        case .stopped:
            if ignoreNextStoppedEvent {
                ignoreNextStoppedEvent = false
                break
            }

            isBuffering = false
            vlcReportedPlaying = false
            // Tear down any in-flight revive so its failsafes can never
            // issue play() against a stopped player (which would restart
            // the media).
            cancelAudioReviveSequence()
            state = .stopped
            clearPendingSeek()

            if !suppressPlaybackEndedEvent, shouldTreatCurrentStopAsPlaybackEnded {
                currentTime = max(currentTime, duration)
                if !hasReportedPlaybackEnded {
                    hasReportedPlaybackEnded = true
                    if let currentAttemptContext {
                        vlcKitEngineLogger.notice(
                            "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) VLCKit reached end of playback"
                        )
                    }
                    onPlaybackEnded?()
                }
            }

            suppressPlaybackEndedEvent = false

        case .error:
            isBuffering = false
            vlcReportedPlaying = false
            cancelAudioReviveSequence()
            state = .error
            let parsedStatus = String(describing: mediaPlayer.media?.parsedStatus)
            let attemptLabel = currentAttemptContext?.attemptLabel ?? "unknown"
            let urlLabel = currentAttemptContext?.sanitizedPlaybackURL ?? "<unknown>"
            let libraryError = VLCLibrary.currentErrorMessage
            vlcKitEngineLogger.error(
                "Playback attempt \(attemptLabel, privacy: .public) VLCKit entered error state. parsedStatus=\(parsedStatus, privacy: .public) currentTime=\(self.currentTime, privacy: .public) duration=\(self.duration, privacy: .public) URL=\(urlLabel, privacy: .public) libraryError=\(libraryError ?? "<none>", privacy: .public)"
            )
            error = PlaybackError.fromDirectPlayFailureMessage(
                libraryError ?? vlcPlaybackErrorMessage(),
                fallback: vlcPlaybackErrorMessage()
            )
            clearPendingSeek()
            loadValidationTask = nil

        @unknown default:
            break
        }

        syncRendererPlaybackState()
        renderingHost.invalidatePlaybackState()
        #if os(iOS)
        refreshPictureInPicturePossible()
        #endif
    }

    fileprivate func updateTime(timeMs: Int32, lengthMs: Int32) {
        let updatedTime = max(0, TimeInterval(timeMs) / 1000.0)
        if lengthMs > 0 {
            duration = TimeInterval(lengthMs) / 1000.0
        }

        if shouldAcceptUpdatedTime(updatedTime) {
            if vlcReportedPlaying, pendingSeekTarget == nil, updatedTime > currentTime {
                steadyPlaybackTicks += 1
                let requiredTicks = isInitialAudioWarmup ? 4 : 1
                if needsSettleAudioRevive, audioRevivePhase == .inactive,
                   steadyPlaybackTicks >= requiredTicks {
                    // Time-progress revive hook. For the initial warmup this
                    // is the PRIMARY trigger and waits for ~1 s of confirmed
                    // rendering (4 advancing ticks at the 250 ms cadence —
                    // the empirically proven point where the cure reliably
                    // works; earlier triggers cured seeks but not starts).
                    // Ticks freeze during genuine refills, so the wait adapts
                    // to connection speed instead of racing it, and the
                    // latency hides behind the loading mask. For seek revives
                    // this is the fallback covering near/cached seeks that
                    // settle without a state transition. The arm is only
                    // consumed inside beginAudioRevive when the revive
                    // actually starts — a deferred attempt retries on the
                    // next tick.
                    beginAudioRevive(reason: "time-progress")
                }
            }
            currentTime = updatedTime
        }
        refreshTracksIfCountsChanged()
        syncRendererPlaybackState()
    }

    /// libvlc 3 has no track-added/-removed delegate callbacks; poll the track
    /// counts on the (already throttled) time ticks and refresh on movement.
    private func refreshTracksIfCountsChanged() {
        let counts = (
            audio: mediaPlayer.numberOfAudioTracks,
            text: mediaPlayer.numberOfSubtitlesTracks
        )
        guard counts != lastObservedTrackCounts else { return }
        lastObservedTrackCounts = counts
        refreshTracks()
    }

    private var shouldTreatCurrentStopAsPlaybackEnded: Bool {
        let durationTolerance = max(1.0, min(5.0, duration * 0.01))
        let reachedDuration = duration > 0 && currentTime >= max(0, duration - durationTolerance)
        let reachedEndPosition = mediaPlayer.position >= 0.98
        return reachedDuration || reachedEndPosition
    }

    private func syncRendererPlaybackState() {
        renderingHost.updatePlaybackState(
            currentTimeMs: Int64(currentTime * 1000),
            durationMs: Int64(duration * 1000),
            isPlaying: state == .playing,
            isSeekable: duration > 0
        )
        #if os(iOS)
        enhancedPictureInPictureOutput?.updatePlaybackState(
            currentTime: currentTime,
            duration: duration,
            isPlaying: state == .playing
        )
        #endif
    }

    private func applySubtitleStyling(to media: VLCMedia) {
        // VLCKit 3.x has no player-level font-scale property; sub-text-scale
        // is the per-media equivalent (percent, 100 = default).
        let scalePercent = Int((PlaybackSubtitleStyle.vlcSubtitleFontScale * 100).rounded())
        media.addOption(":sub-text-scale=\(scalePercent)")
        media.addOption(":freetype-color=#FFFFFF")
        media.addOption(":freetype-background-color=#000000")
        media.addOption(":freetype-background-opacity=110")
        media.addOption(":freetype-shadow-color=#000000")
        media.addOption(":freetype-shadow-opacity=80")
        media.addOption(":freetype-shadow-distance=1")
    }

    private func applyNetworkBufferingOptions(to media: VLCMedia) {
        media.addOption(":network-caching=\(PlaybackBufferPolicy.vlcNetworkCachingMilliseconds)")
        media.addOption(":file-caching=\(PlaybackBufferPolicy.vlcFileCachingMilliseconds)")
        media.addOption(":http-reconnect")
    }

    private func applySeek(to position: TimeInterval) {
        // Exactly ONE seek command. Setting `position` and then `time` issued
        // two back-to-back input seeks — and every libvlc seek flushes the
        // decoders and the audio output, so each app seek doubled the churn
        // the output has to survive. libvlc's input core already emulates a
        // time-seek with a position-seek internally when a demuxer cannot
        // seek by time, so the position pre-seek bought nothing.
        let targetMs = Int(position * 1000.0)
        mediaPlayer.time = VLCTime(int: Int32(clamping: targetMs))
    }

    private func scheduleSeekVerification(target: TimeInterval) {
        seekVerificationTask?.cancel()
        seekVerificationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.seekSettleDelay)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }

            if self.shouldRetrySeek(toward: target) {
                self.applySeek(to: target)
            }

            do {
                try await Task.sleep(for: Self.seekRetryDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            if self.shouldRetrySeek(toward: target) {
                self.applySeek(to: target)
            }
        }
    }

    private func shouldRetrySeek(toward target: TimeInterval) -> Bool {
        guard let pendingSeekTarget else { return false }
        guard abs(pendingSeekTarget - target) <= Self.pendingSeekTolerance else { return false }
        // A buffering player has ACCEPTED the seek and is refilling — far
        // seeks over the network legitimately take longer than these retry
        // delays. Re-seeking now would flush the refill and hammer the audio
        // output with another restart cycle (this is what killed audio when
        // double-tap seeking "too far"). Only retry when playback is running
        // yet demonstrably still at the pre-seek position, i.e. the seek was
        // actually ignored.
        guard !isBuffering else { return false }
        return !hasReachedPendingSeekTarget(using: observedPlayerTime)
    }

    private func shouldAcceptUpdatedTime(_ updatedTime: TimeInterval) -> Bool {
        guard pendingSeekTarget != nil else { return true }

        if hasReachedPendingSeekTarget(using: updatedTime) {
            clearPendingSeek()
            return true
        }

        let elapsed = pendingSeekStartedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if elapsed < Self.pendingSeekStaleUpdateWindow {
            return false
        }

        clearPendingSeek()
        return true
    }

    private func hasReachedPendingSeekTarget(using updatedTime: TimeInterval) -> Bool {
        guard let pendingSeekTarget else { return true }
        return abs(updatedTime - pendingSeekTarget) <= Self.pendingSeekTolerance
    }

    private var observedPlayerTime: TimeInterval {
        max(0, TimeInterval(mediaPlayer.time.intValue) / 1000.0)
    }

    private func clearPendingSeek() {
        pendingSeekTarget = nil
        pendingSeekStartedAt = nil
        seekVerificationTask?.cancel()
        seekVerificationTask = nil
    }

    private func vlcPlaybackErrorMessage() -> String {
        "Playback failed while opening the direct-play stream."
    }

    private func scheduleVideoOutputRefreshAfterResume() {
        #if os(iOS)
        videoRefreshTask?.cancel()
        videoRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }

            guard let self, self.state == .playing || self.mediaPlayer.isPlaying else { return }
            self.refreshVideoOutputAfterResume()
        }
        #endif
    }

    private func refreshVideoOutputAfterResume() {
        #if os(iOS)
        // Re-asserting the current video track nudges VLCKit to rebuild the
        // video output when audio has resumed but rendering is still stale.
        let current = mediaPlayer.currentVideoTrackIndex
        if current >= 0 {
            mediaPlayer.currentVideoTrackIndex = current
        }
        renderingHost.invalidatePlaybackState()
        #endif
    }

    private func recoveryStartPosition(for source: PlaybackSource) -> TimeInterval {
        let observed = observedPlayerTime
        let fallback = source.startPosition ?? 0
        return max(0, observed.isFinite && observed > 0 ? observed : max(currentTime, fallback))
    }

    private func finishValidatedLoad(source: PlaybackSource, attemptID: UUID) {
        guard currentAttemptContext?.attemptID == attemptID else { return }

        let media = VLCMedia(url: source.url)

        applySubtitleStyling(to: media)
        applyNetworkBufferingOptions(to: media)
        if let audioTrackPosition = source.preferredAudioTrackPosition {
            // Open directly on the automatically preferred audio track
            // (position among the audio ESes, computed from Plex metadata).
            // This avoids the post-start ES switch whose audio-output restart
            // could land in the fragile startup window and mute playback.
            media.addOption(":audio-track=\(audioTrackPosition)")
            vlcKitEngineLogger.notice(
                "Playback attempt \(source.context.attemptLabel, privacy: .public) preselecting audio track position \(audioTrackPosition, privacy: .public) via media option"
            )
        }
        configureAudioOutputPolicy(reason: "before-play")
        mediaPlayer.media = media
        if let rawVideoOutput {
            _ = rawVideoOutput.attach(to: mediaPlayer)
        }
        mediaPlayer.play()
        if let start = pendingStartPosition, start > 0 {
            // Apply the resume position NOW, while the input is still
            // opening: play() creates the player input synchronously, so the
            // seek is queued on the input thread and processed before the
            // decoders start rendering — before the audio output even
            // exists. The old approach seeked on the first .playing state,
            // which flushed the audio output right as it was brought up and
            // could latch it silent until a manual pause/resume. The
            // .playing handler keeps a fallback for the rare case where this
            // early seek is dropped (e.g. the demuxer refused to seek while
            // opening). Note: NOT the `:start-time` media option — that
            // shifts libvlc's whole reported timeline (duration shrinks,
            // seeks become relative), which would corrupt Plex progress
            // reporting.
            seek(to: start)
        }
        loadValidationTask = nil
    }

    private func failLoad(_ error: PlaybackError, attemptID: UUID, message: String) {
        guard currentAttemptContext?.attemptID == attemptID else { return }

        if let currentAttemptContext {
            vlcKitEngineLogger.error(
                "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) \(message, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        self.error = error
        state = .error
        isBuffering = false
        loadValidationTask = nil
    }

    /// Buffering events fire continuously on network streams, so only real
    /// transitions are logged — at notice level, because debug-level OSLog
    /// is memory-only and invisible in Console captures/sysdiagnoses, which
    /// blinded on-device debugging of the silent-audio failures.
    @ObservationIgnored private var lastLoggedVLCState: VLCMediaPlayerState?

    private func logStateChange(_ vlcState: VLCMediaPlayerState) {
        guard vlcState != lastLoggedVLCState else { return }
        lastLoggedVLCState = vlcState
        let attemptLabel = currentAttemptContext?.attemptLabel ?? "unknown"
        vlcKitEngineLogger.notice(
            "Playback attempt \(attemptLabel, privacy: .public) VLCKit state=\(String(describing: vlcState), privacy: .public) currentTime=\(self.currentTime, privacy: .public) duration=\(self.duration, privacy: .public) buffering=\(self.isBuffering, privacy: .public)"
        )
    }

    private struct VLCTrackInfo {
        let index: Int
        let name: String
        let codecFourCC: UInt32?
        let channels: Int
        let language: String?
    }

    private func refreshTracks() {
        let audioInfos = vlcTrackInfos(
            indexes: mediaPlayer.audioTrackIndexes,
            names: mediaPlayer.audioTrackNames,
            informationType: VLCMediaTracksInformationTypeAudio
        )
        latestAudioTrackInfosByIndex = Dictionary(
            audioInfos.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        availableAudioTracks = audioInfos.map { info in
            AudioTrack(
                id: modelID(forTrackID: "audio/\(info.index)"),
                displayTitle: info.name,
                language: info.language,
                languageCode: normalizedLanguageCode(from: info.language),
                codec: info.codecFourCC.map(Self.fourCCDisplayString),
                channels: info.channels.nonZeroValue,
                channelLayout: nil,
                isDecodable: Self.canDecodeAudioCodec(info.codecFourCC ?? 0)
            )
        }
        let currentAudioIndex = Int(mediaPlayer.currentAudioTrackIndex)
        selectedAudioTrackID = currentAudioIndex >= 0
            ? modelID(forTrackID: "audio/\(currentAudioIndex)")
            : nil
        configureAudioOutputPolicy(reason: "tracks-refreshed")

        let subtitleInfos = vlcTrackInfos(
            indexes: mediaPlayer.videoSubTitlesIndexes,
            names: mediaPlayer.videoSubTitlesNames,
            informationType: VLCMediaTracksInformationTypeText
        )
        availableSubtitleTracks = subtitleInfos.map { info in
            SubtitleTrack(
                id: modelID(forTrackID: "spu/\(info.index)"),
                displayTitle: info.name,
                language: info.language,
                languageCode: normalizedLanguageCode(from: info.language),
                codec: info.codecFourCC.map(Self.fourCCDisplayString),
                isForced: false,
                isHearingImpaired: false,
                isExternal: false,
                externalURL: nil
            )
        }
        let currentSubtitleIndex = Int(mediaPlayer.currentVideoSubTitleIndex)
        selectedSubtitleTrackID = currentSubtitleIndex >= 0
            ? modelID(forTrackID: "spu/\(currentSubtitleIndex)")
            : nil
    }

    /// Track lists on VLCKit 3.x are parallel index/name arrays (including a
    /// "Disable" pseudo-track at index -1, filtered out here). Codec, channel,
    /// and language metadata lives in `VLCMedia.tracksInformation`, matched by
    /// elementary-stream id.
    private func vlcTrackInfos(
        indexes: [Any],
        names: [Any],
        informationType: String
    ) -> [VLCTrackInfo] {
        let metadataByID = mediaTrackMetadata(ofType: informationType)
        return zip(indexes, names).compactMap { rawIndex, rawName in
            guard let index = (rawIndex as? NSNumber)?.intValue, index >= 0 else { return nil }
            let metadata = metadataByID[index]
            let arrayName = (rawName as? String).flatMap { $0.isEmpty ? nil : $0 }
            let name = arrayName
                ?? metadata?.description.flatMap { $0.isEmpty ? nil : $0 }
                ?? metadata?.language
                ?? "Track \(index)"
            return VLCTrackInfo(
                index: index,
                name: name,
                codecFourCC: metadata?.codecFourCC,
                channels: metadata?.channels ?? 0,
                language: metadata?.language
            )
        }
    }

    private struct VLCTrackMetadata {
        let codecFourCC: UInt32?
        let channels: Int
        let language: String?
        let description: String?
    }

    private func mediaTrackMetadata(ofType type: String) -> [Int: VLCTrackMetadata] {
        guard let tracks = mediaPlayer.media?.tracksInformation as? [[String: Any]] else {
            return [:]
        }

        var result: [Int: VLCTrackMetadata] = [:]
        for track in tracks {
            guard (track[VLCMediaTracksInformationType] as? String) == type,
                  let id = (track[VLCMediaTracksInformationId] as? NSNumber)?.intValue else {
                continue
            }
            result[id] = VLCTrackMetadata(
                codecFourCC: (track[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value,
                channels: (track[VLCMediaTracksInformationAudioChannelsNumber] as? NSNumber)?.intValue ?? 0,
                language: track[VLCMediaTracksInformationLanguage] as? String,
                description: track[VLCMediaTracksInformationDescription] as? String
            )
        }
        return result
    }

    /// Renders a VLC_FOURCC value ("mlpa", "ac-3", …) for display.
    private static func fourCCDisplayString(_ value: UInt32) -> String {
        let bytes = [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
        let characters = bytes.map { byte in
            (32...126).contains(byte) ? String(UnicodeScalar(byte)) : " "
        }
        return characters.joined().trimmingCharacters(in: .whitespaces)
    }

    /// Audio codecs present in containers that the vendored VLCKit build cannot
    /// decode. Stock VideoLAN builds disable ffmpeg's TrueHD/MLP decoders on
    /// iOS/tvOS for App Store licensing compliance ("Codec `mlpa' is not
    /// supported"), and the vendored stable 3.x binaries are stock — the
    /// patched source builds that re-enabled TrueHD were retired with the 4.x
    /// alpha. Tracks matching these are skipped by automatic selection, and
    /// picking one in the picker reroutes playback through a server transcode
    /// (see `PlayerViewModel.selectAudio`). A file with no locally decodable
    /// audio at all triggers the same fallback automatically.
    private static let undecodableAudioFourCCs: Set<UInt32> = [
        fourCC("m", "l", "p", "a"), // TrueHD
        fourCC("m", "l", "p", " "), // MLP
    ]

    private static func canDecodeAudioCodec(_ codec: UInt32) -> Bool {
        !undecodableAudioFourCCs.contains(codec)
    }

    /// Packs characters the way libvlc's VLC_FOURCC macro does (little endian),
    /// matching the raw `VLCMediaTrack.codec` value.
    private static func fourCC(
        _ a: Character, _ b: Character, _ c: Character, _ d: Character
    ) -> UInt32 {
        UInt32(a.asciiValue ?? 0)
            | UInt32(b.asciiValue ?? 0) << 8
            | UInt32(c.asciiValue ?? 0) << 16
            | UInt32(d.asciiValue ?? 0) << 24
    }

    private func normalizedLanguageCode(from language: String?) -> String? {
        guard let language, !language.isEmpty else { return nil }
        return language.lowercased()
    }

    private func configureAudioOutputPolicy(reason: String = "initial") {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = route.outputs
        let selectedInfo = selectedAudioTrackInfo()
        let selectedTrackLabel = selectedInfo?.name ?? "Unknown"
        let selectedChannels = selectedInfo?.channels.nonZeroValue
        let outputChannelCount = max(
            Int(session.outputNumberOfChannels),
            outputs.compactMap { $0.channels?.count }.max() ?? 0
        )
        let maximumOutputChannelCount = max(Int(session.maximumOutputNumberOfChannels), outputChannelCount)
        #if os(tvOS)
        // tvOS drives true multichannel output to the connected receiver over
        // HDMI/eARC. libvlc 3's audiounit output negotiates the channel layout
        // itself (VLCKit 3.x has no mix-mode API); we only open the audio
        // session up to the richest layout the route can render.
        let preferredOutputChannels: Int? = {
            guard let selectedChannels, selectedChannels > 2 else { return nil }
            return min(selectedChannels, max(2, maximumOutputChannelCount))
        }()
        let wantsMultichannelOutput = preferredOutputChannels != nil
        #else
        // iOS/iPadOS: the output route is effectively stereo — built-in speaker,
        // wired, or Bluetooth/AirPods. Deliberately do NOT drive preferred
        // output channel counts or multichannel session content here. Each of
        // those restarts VLCKit's audio output, and Bluetooth routes
        // renegotiate spatial/rendering capabilities constantly, which churned
        // the output and stuttered the sound in and out (worst on AirPods).
        // Let VLCKit downmix to the active route on its own; the rare
        // multichannel-capable iOS route (AirPlay / USB to a receiver) is
        // handled by that same downmix path. Surround is owned by the system
        // audio session here, not forced by us.
        let preferredOutputChannels: Int? = nil
        let wantsMultichannelOutput = false
        #endif

        // Idempotency guard. Bluetooth routes — AirPods especially — emit a
        // stream of route/spatial/rendering notifications during playback, and
        // every one of them used to re-poke the live VLCMediaPlayer audio output
        // (passthrough, equalizer, mix mode) and re-assert multichannel support.
        // Each re-poke tears down and rebuilds VLCKit's audio output, so the
        // sound cut in and out for a few seconds at a time — only on headphones,
        // because the built-in speaker has no spatial audio to churn. Re-apply
        // the player/session audio settings ONLY when the resolved configuration
        // actually changes; otherwise this is a no-op and the audio keeps playing.
        let signature = [
            selectedAudioTrackID.map(String.init) ?? "auto",
            String(preferredOutputChannels ?? 0),
            String(wantsMultichannelOutput),
        ].joined(separator: "|")

        if signature != lastAppliedAudioConfigSignature {
            #if os(tvOS)
            do {
                try session.setSupportsMultichannelContent(wantsMultichannelOutput)
            } catch {
                vlcKitEngineLogger.debug(
                    "Failed to set multichannel audio session content support \(wantsMultichannelOutput, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }

            if let preferredOutputChannels,
               maximumOutputChannelCount >= preferredOutputChannels,
               session.preferredOutputNumberOfChannels != preferredOutputChannels {
                do {
                    try session.setPreferredOutputNumberOfChannels(preferredOutputChannels)
                } catch {
                    vlcKitEngineLogger.debug(
                        "Failed to set preferred output channel count \(preferredOutputChannels, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            #endif

            if mediaPlayer.audio?.passthrough != false {
                mediaPlayer.audio?.passthrough = false
            }
            if mediaPlayer.equalizer != nil {
                mediaPlayer.equalizer = nil
            }
            lastAppliedAudioConfigSignature = signature
        } else {
            vlcKitEngineLogger.debug(
                "Skipped redundant VLC audio policy reason=\(reason, privacy: .public) signature=\(signature, privacy: .public)"
            )
            return
        }

        let routeSummary = outputs.map { output in
            let channelCount = output.channels?.count ?? 0
            if #available(iOS 15.0, tvOS 15.0, *) {
                return "\(output.portType.rawValue){channels=\(channelCount), spatial=\(output.isSpatialAudioEnabled)}"
            } else {
                return "\(output.portType.rawValue){channels=\(channelCount)}"
            }
        }.joined(separator: ", ")

        playbackDiagnostics = [
            PlaybackEngineDiagnostic(
                label: "VLCKit Build",
                value: Self.vendoredVLCKitAudit.detail
            ),
            PlaybackEngineDiagnostic(
                label: "VLC Audio Module",
                value: "audiounit (libvlc 3 default)"
            ),
            PlaybackEngineDiagnostic(
                label: "VLC Audio Track",
                value: "\(selectedTrackLabel) / \(selectedChannels.map { "\($0)ch" } ?? "unknown channels")"
            ),
            PlaybackEngineDiagnostic(
                label: "VLC Audio Output",
                value: "passthrough=\(self.mediaPlayer.audio?.passthrough == true ? "On" : "Off")"
            ),
            PlaybackEngineDiagnostic(
                label: "Audio Route",
                value: routeSummary.isEmpty ? "Unknown" : routeSummary
            ),
            PlaybackEngineDiagnostic(
                label: "Output Channels",
                value: "current=\(outputChannelCount), preferred=\(session.preferredOutputNumberOfChannels), max=\(maximumOutputChannelCount)"
            ),
        ]

        vlcKitEngineLogger.notice(
            "Applied VLC audio policy reason=\(reason, privacy: .public) selectedTrack=\(selectedTrackLabel, privacy: .public) selectedChannels=\(selectedChannels ?? 0, privacy: .public) passthrough=false outputChannels=\(outputChannelCount, privacy: .public) preferredOutputChannels=\(session.preferredOutputNumberOfChannels, privacy: .public) maxOutputChannels=\(maximumOutputChannelCount, privacy: .public) route=[\(routeSummary, privacy: .public)]"
        )
        #endif
    }

    private func selectedAudioTrackInfo() -> VLCTrackInfo? {
        if let selectedAudioTrackID,
           let index = vlcTrackIndex(forModelID: selectedAudioTrackID),
           let info = latestAudioTrackInfosByIndex[index] {
            return info
        }

        let currentIndex = Int(mediaPlayer.currentAudioTrackIndex)
        return latestAudioTrackInfosByIndex[currentIndex]
            ?? latestAudioTrackInfosByIndex.values.min(by: { $0.index < $1.index })
    }

    /// Returns a stable, unique model Int for an engine-local track key
    /// ("audio/<index>" / "spu/<index>"), minting one on first sight.
    /// `trackIDsByModelID` maps back so selection targets the exact VLCKit
    /// track. Reset per media load.
    private func modelID(forTrackID trackID: String) -> Int {
        if let existing = modelIDsByTrackID[trackID] {
            return existing
        }
        let id = nextTrackModelID
        nextTrackModelID += 1
        modelIDsByTrackID[trackID] = id
        trackIDsByModelID[id] = trackID
        return id
    }

    // MARK: - Audio revive

    /// True while the initial warmup must keep the user-facing state at
    /// `.loading`: the arm is pending or the revive is mid-flight.
    private var isAudioWarmupMasking: Bool {
        isInitialAudioWarmup && (needsSettleAudioRevive || audioRevivePhase != .inactive)
    }

    /// Arms the one-shot settle revive (see `needsSettleAudioRevive`) after an
    /// audio-output disturbance: media open, stall recovery, or a seek.
    /// `initialBringUp` additionally masks the warmup as `.loading` until the
    /// revive completes (loads only — mid-playback seek revives stay
    /// invisible via the `.paused` suppression instead).
    /// iOS/iPadOS only: the silent-render latches live in libvlc's iOS
    /// AudioUnit/AVAudioSession interplay; the tvOS HDMI route has shown no
    /// such failures and a pause blip there would be more visible.
    /// DORMANT by default on the stable 3.x line — see `isAudioReviveEnabled`.
    private func armSettleAudioRevive(initialBringUp: Bool = false) {
        #if os(iOS)
        guard Self.isAudioReviveEnabled else { return }
        needsSettleAudioRevive = true
        if initialBringUp {
            isInitialAudioWarmup = true
        }
        #endif
    }

    /// Gap between the CONFIRMED pause and the resume for seek revives.
    /// Sequencing correctness does not depend on it (the resume is only
    /// issued after libvlc reported the pause); 100 ms is confirmed on
    /// device to cure seek-induced silence. Overridable without a new build
    /// via the `vlcAudioReviveGapMs` user default (clamped 40–1000).
    private static var audioReviveGapMilliseconds: Int {
        let stored = UserDefaults.standard.integer(forKey: "vlcAudioReviveGapMs")
        guard stored > 0 else { return 100 }
        return min(max(stored, 40), 1_000)
    }

    /// Gap for the initial-warmup revive. 1.2 s (together with the ~1 s
    /// rendering-progress trigger) is the configuration confirmed on device
    /// to cure the silent start 100% of the time; shorter holds traded cure
    /// reliability for latency that the loading mask hides anyway.
    /// Overridable via the `vlcAudioWarmupReviveGapMs` user default
    /// (clamped 100–3000).
    private static var audioWarmupReviveGapMilliseconds: Int {
        let stored = UserDefaults.standard.integer(forKey: "vlcAudioWarmupReviveGapMs")
        guard stored > 0 else { return 1_200 }
        return min(max(stored, 100), 3_000)
    }

    /// Starts the closed-loop revive — the automated manual "pause, then
    /// play" cure. Issues the pause and enters `.awaitingPauseConfirmation`;
    /// the rest of the sequence is driven by libvlc's own state events (see
    /// `handleStateChange`), so no step can race the player's control queue.
    /// Consumes the arm ONLY when the revive actually starts; a deferred
    /// (rate-limited) attempt leaves it armed for the next trigger.
    @discardableResult
    private func beginAudioRevive(reason: String) -> Bool {
        guard audioRevivePhase == .inactive, vlcReportedPlaying else { return false }
        if let lastAudioReviveAt, Date().timeIntervalSince(lastAudioReviveAt) < 1.5 {
            return false
        }
        lastAudioReviveAt = Date()
        needsSettleAudioRevive = false
        audioRevivePhase = .awaitingPauseConfirmation
        audioReviveResumeAttempts = 0
        steadyPlaybackTicks = 0

        let attemptLabel = currentAttemptContext?.attemptLabel ?? "unknown"
        vlcKitEngineLogger.notice(
            "Playback attempt \(attemptLabel, privacy: .public) VLCKit audio revive pausing (\(reason, privacy: .public))"
        )

        mediaPlayer.pause()

        // Failsafe only: if libvlc never confirms the pause (e.g. pausing is
        // not possible in the current input state), fall through to the
        // resume leg — issuing play() is safe and idempotent in every
        // ordering, and a late-confirming pause is then handled by the
        // resume-confirmation enforcer.
        audioReviveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }

            guard let self, !Task.isCancelled,
                  self.audioRevivePhase == .awaitingPauseConfirmation else { return }
            vlcKitEngineLogger.warning(
                "VLCKit audio revive pause was never confirmed; resuming anyway"
            )
            self.scheduleAudioReviveResume()
        }
        return true
    }

    /// Entered when libvlc CONFIRMED the revive pause (or the pause-timeout
    /// failsafe fired). Waits the configured gap, then issues the resume and
    /// waits for the `.playing` confirmation.
    private func scheduleAudioReviveResume() {
        audioReviveTask?.cancel()
        audioRevivePhase = .awaitingResumeConfirmation

        let gapMilliseconds = isInitialAudioWarmup
            ? Self.audioWarmupReviveGapMilliseconds
            : Self.audioReviveGapMilliseconds
        audioReviveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(gapMilliseconds))
            } catch {
                return
            }

            guard let self, !Task.isCancelled,
                  self.audioRevivePhase == .awaitingResumeConfirmation else { return }
            vlcKitEngineLogger.notice("VLCKit audio revive resuming")
            self.mediaPlayer.play()
            // Manual resumes also refresh the video output shortly after
            // play (see play()); keep the replica exact.
            self.scheduleVideoOutputRefreshAfterResume()
            self.armAudioReviveResumeFailsafe()
        }
    }

    /// Failsafe only: if no `.playing` confirmation arrives after the resume
    /// was issued, either the transition was eventless (pause/play coalesced
    /// with no state change — complete using the raw playing flag) or the
    /// play was swallowed (retry, bounded). Every expiry action is safe in
    /// every ordering.
    private func armAudioReviveResumeFailsafe() {
        audioReviveTask?.cancel()
        audioReviveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            guard let self, !Task.isCancelled,
                  self.audioRevivePhase == .awaitingResumeConfirmation else { return }

            if self.vlcReportedPlaying {
                // No transition event because playback never visibly left
                // playing — the cure ran; finish up.
                self.completeAudioRevive()
                self.state = .playing
            } else if self.audioReviveResumeAttempts < 3 {
                self.audioReviveResumeAttempts += 1
                vlcKitEngineLogger.warning(
                    "VLCKit audio revive resume unconfirmed; retrying play (attempt \(self.audioReviveResumeAttempts, privacy: .public))"
                )
                self.mediaPlayer.play()
                self.armAudioReviveResumeFailsafe()
            } else {
                vlcKitEngineLogger.error(
                    "VLCKit audio revive gave up waiting for resume confirmation; surfacing the paused state"
                )
                self.audioRevivePhase = .inactive
                self.isInitialAudioWarmup = false
                self.state = .paused
            }
        }
    }

    /// A `.paused` event surfaced AFTER the resume was issued: a late pause
    /// confirmation raced the resume. Re-play, bounded — the user cannot be
    /// the source (user pauses go through `pause()`, which tears the revive
    /// down first), so re-playing never overrides intent.
    private func enforceAudioReviveResume() {
        guard audioReviveResumeAttempts < 3 else {
            vlcKitEngineLogger.error(
                "VLCKit audio revive could not hold playback resumed; surfacing the paused state"
            )
            audioReviveTask?.cancel()
            audioRevivePhase = .inactive
            isInitialAudioWarmup = false
            state = .paused
            return
        }
        audioReviveResumeAttempts += 1
        vlcKitEngineLogger.notice(
            "VLCKit audio revive re-playing after a late pause confirmation (attempt \(self.audioReviveResumeAttempts, privacy: .public))"
        )
        mediaPlayer.play()
        armAudioReviveResumeFailsafe()
    }

    /// The `.playing` confirmation after the resume: the cure completed.
    /// Ends the warmup mask; the caller (the `.playing` case) sets the
    /// user-facing state.
    private func completeAudioRevive() {
        audioReviveTask?.cancel()
        audioReviveTask = nil
        audioRevivePhase = .inactive
        audioReviveResumeAttempts = 0
        isInitialAudioWarmup = false
        vlcKitEngineLogger.notice("VLCKit audio revive complete")
    }

    /// Tears down an in-flight revive without consuming the arm — used when
    /// the user pauses, so their intent always wins over the machinery.
    private func cancelAudioReviveSequence() {
        audioReviveTask?.cancel()
        audioReviveTask = nil
        audioRevivePhase = .inactive
        audioReviveResumeAttempts = 0
        isInitialAudioWarmup = false
    }

    private func cancelAudioRevive() {
        cancelAudioReviveSequence()
        audioInterruptionWatchdogTask?.cancel()
        audioInterruptionWatchdogTask = nil
        needsSettleAudioRevive = false
        lastAudioReviveAt = nil
    }

    /// An interruption "began" without a matching "ended" leaves libvlc's
    /// AudioUnit render callback latched silent forever while the core keeps
    /// reporting success (the vendored patch 0015 revives only on "ended",
    /// which iOS omits entirely for some Bluetooth handoffs). The app cannot
    /// detect the silence, but it CAN see the unmatched notification: if no
    /// "ended" arrives shortly and the engine is still nominally playing —
    /// meaning nothing paused us, so the user expects sound — run the revive.
    private func handleAudioSessionInterruption(typeValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            vlcKitEngineLogger.notice(
                "VLCKit observed audio session interruption BEGAN (state=\(String(describing: self.state), privacy: .public))"
            )
            guard Self.isAudioReviveEnabled else { return }
            audioInterruptionWatchdogTask?.cancel()
            audioInterruptionWatchdogTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(2500))
                } catch {
                    return
                }

                guard let self, !Task.isCancelled else { return }
                self.audioInterruptionWatchdogTask = nil
                guard self.vlcReportedPlaying else { return }
                self.beginAudioRevive(reason: "interruption-without-ended")
            }

        case .ended:
            // The vendored libvlc revives its output on every interruption
            // end itself; the watchdog is only for the never-ended case.
            vlcKitEngineLogger.notice(
                "VLCKit observed audio session interruption ENDED (state=\(String(describing: self.state), privacy: .public))"
            )
            audioInterruptionWatchdogTask?.cancel()
            audioInterruptionWatchdogTask = nil

        @unknown default:
            break
        }
    }

    private func registerAudioSessionObserversIfNeeded() {
        #if os(iOS) || os(tvOS)
        // Observe only genuine output-route changes (plugging in headphones,
        // switching to AirPlay, etc.). Deliberately NOT the spatial-playback /
        // rendering-capability / rendering-mode notifications: AirPods emit those
        // continuously while spatial audio negotiates, and reacting to them by
        // reconfiguring the VLCMediaPlayer audio output is exactly what made the
        // sound stutter in and out on headphones. Our mix-mode/channel decision
        // depends on the route, which routeChange already covers, and the policy
        // is idempotent so a route change that resolves to the same config is a
        // no-op anyway.
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configureAudioOutputPolicy(reason: "routeChange")
            }
        }
        audioSessionObservers.append(observer)

        let interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleAudioSessionInterruption(typeValue: typeValue)
            }
        }
        audioSessionObservers.append(interruptionObserver)
        #endif
    }
}

extension VLCKitEngine: VLCMediaPlayerDelegate {
    // VLCKit 3.x delivers delegate events as notifications and has no
    // per-track callbacks; track-list changes surface through the .esAdded
    // state and the count poll in `refreshTracksIfCountsChanged`.
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        let newState = mediaPlayer.state
        Task { @MainActor [weak self] in
            self?.handleStateChange(newState)
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let timeMs = mediaPlayer.time.intValue
        let lengthMs = mediaPlayer.media?.length.intValue ?? 0
        Task { @MainActor [weak self] in
            self?.updateTime(timeMs: timeMs, lengthMs: lengthMs)
        }
    }
}

private struct VLCPlayerRepresentable: UIViewRepresentable {
    let playerView: UIView

    func makeUIView(context: Context) -> UIView {
        playerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

#if os(iOS)
/// Hosts the sample-buffer PiP display view (occluded behind the Metal view).
private struct VLCEnhancedPiPDisplayRepresentable: UIViewRepresentable {
    let displayView: VLCKitEnhancedPiPDisplayView

    func makeUIView(context: Context) -> VLCKitEnhancedPiPDisplayView {
        displayView
    }

    func updateUIView(_ uiView: VLCKitEnhancedPiPDisplayView, context: Context) {}
}

extension VLCKitEngine: VLCKitEnhancedPictureInPicturePlaybackDelegate {
    var enhancedPiPIsPlaying: Bool { state == .playing }
    var enhancedPiPCurrentTime: TimeInterval { currentTime }
    var enhancedPiPDuration: TimeInterval { duration }

    func enhancedPiPSetPlaying(_ playing: Bool) {
        if playing {
            play()
        } else {
            pause()
        }
    }

    func enhancedPiPSkip(by seconds: TimeInterval, completion: @escaping () -> Void) {
        seek(to: currentTime + seconds)
        completion()
    }
}
#endif

private extension Int {
    var nonZeroValue: Int? {
        self == 0 ? nil : self
    }
}
#endif
