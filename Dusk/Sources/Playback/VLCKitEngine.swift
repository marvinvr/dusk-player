#if canImport(VLCKit)
import CoreVideo
import OSLog
import SwiftUI
import UIKit
import VLCKit
#if os(iOS) || os(tvOS)
import AVFoundation
#endif
#endif

#if canImport(VLCKit)
private let vlcKitEngineLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "VLCKitEngine"
)

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

    init(renderer: VideoEnhancementRenderer) {
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

/// PlaybackEngine implementation backed by upstream VLCKit 4.x.
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
    /// Native sample-buffer PiP for the Video Enhancement path. Present only
    /// while enhancement is active (the drawable-backed PiP host cannot render
    /// while libvlc feeds the Metal upscaler through raw callbacks).
    @ObservationIgnored private var enhancedPictureInPictureOutput: VLCKitEnhancedPictureInPictureOutput?
    #endif

    nonisolated(unsafe) private let mediaPlayer: VLCMediaPlayer
    private let renderingHost: any VLCKitRenderingHost

    private var pendingStartPosition: TimeInterval?
    private var hasAppliedStartPosition = false
    private var hasReportedPlaybackEnded = false
    private var suppressPlaybackEndedEvent = false
    private var ignoreNextStoppedEvent = false
    private var pendingSeekTarget: TimeInterval?
    private var pendingSeekStartedAt: Date?
    private var currentAttemptContext: PlaybackAttemptContext?
    private var currentSource: PlaybackSource?
    private var lastAppliedAudioMixMode: VLCMediaPlayer.AudioMixMode = .modeUnset
    private var lastAppliedAudioConfigSignature: String?
    // VLCKit 4 identifies player tracks by a stable string `trackId`. The int
    // `identifier` inherited from `VLCMediaTrack` is not a reliable selector for
    // player tracks, so matching on it silently selected the wrong track and
    // switching audio/subtitle tracks never took effect. Map each `trackId` to a
    // stable unique Int for the `AudioTrack`/`SubtitleTrack` models, and back to
    // the `trackId` for selection. Shared across audio/subtitle (trackIds are
    // unique per type, e.g. "audio/0" vs "spu/0").
    private var trackIDsByModelID: [Int: String] = [:]
    private var modelIDsByTrackID: [String: Int] = [:]
    private var nextTrackModelID = 1
    @ObservationIgnored nonisolated(unsafe) private var audioSessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored nonisolated(unsafe) private var seekVerificationTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var loadValidationTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var videoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsVideoRefreshOnPlay = false
    @ObservationIgnored private var videoEnhancementRequest: VideoEnhancementRequest = .disabled
    @ObservationIgnored private var videoEnhancementRenderer: VideoEnhancementRenderer?
    @ObservationIgnored nonisolated(unsafe) private var rawVideoFrameSink: VLCKitVideoEnhancementFrameSink?
    @ObservationIgnored nonisolated(unsafe) private var rawVideoOutput: DuskVLCRawVideoOutput?

    /// Shared libvlc instances, configured on top of VLCKit's default options
    /// (`VLCLibrary.initWithOptions:` appends to them).
    ///
    /// `--aout=audiounit_ios,any` pins the audio output to the classic
    /// pull-model AudioUnit module instead of libvlc 4's new default
    /// `avsamplebuffer` (AVSampleBufferAudioRenderer, capability 100 vs 99).
    /// avsamplebuffer drives the core playback clock from a 1-second periodic
    /// time observer of an AVSampleBufferRenderSynchronizer, a mechanism with
    /// documented iOS-specific drift (fine on macOS/simulator, which is why
    /// the dropouts never reproduce off-device), and mpv deliberately ships
    /// the equivalent output opt-in rather than default. When the reported
    /// clock lurches, libvlc's aout core reacts with "playback too late /
    /// too early" silence insertions and buffer flushes — audible as cyclic
    /// audio dropouts a few seconds long that a pause/resume temporarily
    /// clears. audiounit_ios reports timing from the real-time CoreAudio
    /// render callback instead. The ",any" suffix keeps a fallback if the
    /// module is ever missing so playback never starts without audio.
    /// `UserPreferences.vlcUseAVSampleBufferAudio` (Settings → Playback
    /// Advanced) restores the libvlc default for on-device A/B testing;
    /// it is read once per engine, so it applies to the next playback.
    nonisolated(unsafe) private static let audioUnitLibrary =
        VLCLibrary(options: ["--aout=audiounit_ios,any"])
    nonisolated(unsafe) private static let libvlcDefaultLibrary =
        VLCLibrary(options: [])

    /// Mirrors `UserPreferences.Keys.vlcUseAVSampleBufferAudio` (Settings).
    private static let useAVSampleBufferAudioDefaultsKey = "vlcUseAVSampleBufferAudio"

    private static func chooseLibrary() -> VLCLibrary {
        UserDefaults.standard.bool(forKey: useAVSampleBufferAudioDefaultsKey)
            ? libvlcDefaultLibrary
            : audioUnitLibrary
    }

    override init() {
        let player = VLCMediaPlayer(library: Self.chooseLibrary())
        let renderingHost = makeVLCKitRenderingHost()
        self.mediaPlayer = player
        self.renderingHost = renderingHost
        super.init()

        player.delegate = self
        player.timeChangeUpdateInterval = 0.25
        player.minimalTimePeriod = 250_000
        renderingHost.attach(to: player, engine: self)
        configurePictureInPictureBridge()
        configureAudioOutputPolicy()
        registerAudioSessionObserversIfNeeded()
    }

    deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        loadValidationTask?.cancel()
        seekVerificationTask?.cancel()
        videoRefreshTask?.cancel()
        mediaPlayer.stop()
        rawVideoOutput?.detach()
        mediaPlayer.delegate = nil
        renderingHost.detach(from: mediaPlayer)
    }

    func load(source: PlaybackSource) {
        loadValidationTask?.cancel()
        videoRefreshTask?.cancel()
        videoRefreshTask = nil
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
        availableSubtitleTracks = []
        availableAudioTracks = []
        selectedSubtitleTrackID = nil
        selectedAudioTrackID = nil
        playbackDiagnostics = []
        lastAppliedAudioMixMode = .modeUnset
        lastAppliedAudioConfigSignature = nil
        trackIDsByModelID = [:]
        modelIDsByTrackID = [:]
        nextTrackModelID = 1
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
        videoEnhancementRequest = request
        videoEnhancementRenderer = VideoEnhancementRenderer(request: request)

        if let videoEnhancementRenderer {
            renderingHost.detach(from: mediaPlayer)
            let frameSink = VLCKitVideoEnhancementFrameSink(renderer: videoEnhancementRenderer)
            rawVideoFrameSink = frameSink
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
        seekVerificationTask?.cancel()
        seekVerificationTask = nil
        videoRefreshTask?.cancel()
        videoRefreshTask = nil
        mediaPlayer.pause()
        state = .paused
        syncRendererPlaybackState()
    }

    func stop() {
        loadValidationTask?.cancel()
        loadValidationTask = nil
        videoRefreshTask?.cancel()
        videoRefreshTask = nil
        clearPendingSeek()
        suppressPlaybackEndedEvent = true
        ignoreNextStoppedEvent = false
        mediaPlayer.stop()
        rawVideoOutput?.detach()
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

    /// VLCKit 4.x drives PiP through a native `AVPictureInPictureController` it
    /// builds behind the `VLCPictureInPictureDrawable` host — this is the
    /// Apple-sanctioned native path, not the old non-native hack. The host vends
    /// the window controller asynchronously; we mirror its readiness and active
    /// state into observable flags for the player UI and relay lifecycle events
    /// to the coordinator.
    func setPictureInPictureDelegate(_ delegate: (any PlaybackPictureInPictureDelegate)?) {
        pictureInPictureDelegate = delegate
    }

    func startPictureInPicture() {
        guard isPictureInPicturePossible else { return }
        if let enhancedPictureInPictureOutput {
            enhancedPictureInPictureOutput.start()
        } else {
            (renderingHost as? IOSVLCKitRenderingHost)?.startPictureInPicture()
        }
    }

    func stopPictureInPicture() {
        if let enhancedPictureInPictureOutput {
            enhancedPictureInPictureOutput.stop()
        } else {
            (renderingHost as? IOSVLCKitRenderingHost)?.stopPictureInPicture()
        }
    }

    /// Builds the sample-buffer PiP output for the Video Enhancement path and
    /// bridges its readiness/active/restore events into the engine's observable
    /// PiP state and the coordinator delegate.
    private func configureEnhancedPictureInPicture(frameSink: VLCKitVideoEnhancementFrameSink) {
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

    private func configurePictureInPictureBridge() {
        guard let iosHost = renderingHost as? IOSVLCKitRenderingHost else { return }
        iosHost.onPictureInPictureReadyChanged = { [weak self] in
            self?.refreshPictureInPicturePossible()
        }
        iosHost.onPictureInPictureActiveChanged = { [weak self] isActive in
            guard let self else { return }
            self.isPictureInPictureActive = isActive
            if isActive {
                self.pictureInPictureDelegate?.pictureInPictureActiveDidChange(true)
            } else {
                // VLCKit's binding can't distinguish a restore-tap from a close,
                // so always offer to restore the player UI first (non-destructive
                // — playback is never silently lost), then report the stop.
                self.pictureInPictureDelegate?.pictureInPictureRestorePlayerUI { _ in }
                self.pictureInPictureDelegate?.pictureInPictureActiveDidChange(false)
            }
        }
    }

    private func refreshPictureInPicturePossible() {
        // With Video Enhancement active, VLCKit's own drawable is detached and the
        // sample-buffer output owns PiP instead.
        if let enhancedPictureInPictureOutput {
            isPictureInPicturePossible = enhancedPictureInPictureOutput.isPictureInPicturePossible
            return
        }
        guard let iosHost = renderingHost as? IOSVLCKitRenderingHost else {
            isPictureInPicturePossible = false
            return
        }
        // The native PiP drawable is only live when VLCKit renders into the
        // host; Video Enhancement detaches it for the Metal path.
        isPictureInPicturePossible = iosHost.isPictureInPictureReady && rawVideoOutput == nil
    }
    #else
    private func configurePictureInPictureBridge() {}
    #endif

    func seek(to position: TimeInterval) {
        let clampedPosition: TimeInterval
        if duration > 0 {
            clampedPosition = min(max(position, 0), duration)
        } else {
            clampedPosition = max(position, 0)
        }

        pendingSeekTarget = clampedPosition
        pendingSeekStartedAt = Date()
        currentTime = clampedPosition

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
            mediaPlayer.deselectAllTextTracks()
            selectedSubtitleTrackID = nil
            return
        }

        if let trackID = trackIDsByModelID[track.id],
           let vlcTrack = mediaPlayer.textTracks.first(where: { $0.trackId == trackID }) {
            vlcTrack.isSelectedExclusively = true
        }
        selectedSubtitleTrackID = track.id
    }

    func selectAudioTrack(_ track: AudioTrack) {
        if let trackID = trackIDsByModelID[track.id],
           let vlcTrack = mediaPlayer.audioTracks.first(where: { $0.trackId == trackID }) {
            vlcTrack.isSelectedExclusively = true
        }
        selectedAudioTrackID = track.id
        configureAudioOutputPolicy(reason: "audio-track-selected")
    }

    /// Automatic audio selection must wait for steady-state playback. Switching
    /// the audio ES makes libvlc restart the audio output for the input format
    /// change (e.g. TrueHD 7.1 → AC-3 5.1); if that restart lands inside the
    /// startup window — output bring-up, passthrough probing, audio session
    /// activation, the resume seek's flush — a failed `aout_OutputNew` marks
    /// the stream dead (`mixer_format.i_format = 0`) and libvlc never retries:
    /// video plays, audio is simply absent until a pause/resume forces another
    /// restart. Steady state means: actually playing, not buffering, the
    /// pending start-position seek issued AND settled (`pendingSeekTarget`
    /// only clears once time updates reach the target), and a real time tick
    /// observed — i.e. the pipeline is demonstrably rendering, the same
    /// conditions under which manual track switches are reliable.
    var isReadyForAutomaticAudioSelection: Bool {
        guard state == .playing, !isBuffering else { return false }
        guard hasAppliedStartPosition || (pendingStartPosition ?? 0) <= 0 else { return false }
        return pendingSeekTarget == nil && currentTime > 0
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
        return AnyView(VLCPlayerRepresentable(playerView: renderingHost.playerView))
    }

    fileprivate func handleStateChange(_ vlcState: VLCMediaPlayerState) {
        logStateChange(vlcState)
        switch vlcState {
        case .opening, .buffering:
            isBuffering = true
            if state != .playing && state != .paused {
                state = .loading
            }

        case .playing:
            isBuffering = false
            state = .playing
            suppressPlaybackEndedEvent = false
            configureAudioOutputPolicy(reason: "entered-playing-state")

            if !hasAppliedStartPosition, let start = pendingStartPosition, start > 0 {
                hasAppliedStartPosition = true
                seek(to: start)
            }

            refreshTracks()

        case .paused:
            isBuffering = false
            state = .paused

        case .stopping:
            isBuffering = false

        case .stopped:
            if ignoreNextStoppedEvent {
                ignoreNextStoppedEvent = false
                break
            }

            isBuffering = false
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
    }

    fileprivate func updateTime(timeMs: Int32, lengthMs: Int32) {
        let updatedTime = max(0, TimeInterval(timeMs) / 1000.0)
        if lengthMs > 0 {
            duration = TimeInterval(lengthMs) / 1000.0
        }

        if shouldAcceptUpdatedTime(updatedTime) {
            currentTime = updatedTime
        }
        syncRendererPlaybackState()
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
        if duration > 0 {
            let normalizedPosition = min(max(position / duration, 0), 1)
            if normalizedPosition.isFinite {
                mediaPlayer.position = normalizedPosition
            }
        }

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
        // Re-selecting the active video track nudges VLCKit to rebuild the
        // video output when audio has resumed but rendering is still stale.
        guard let selectedTrack = mediaPlayer.videoTracks.first(where: \.isSelected)
            ?? mediaPlayer.videoTracks.first else {
            return
        }

        selectedTrack.isSelectedExclusively = true
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

        guard let media = VLCMedia(url: source.url) else {
            failLoad(
                .unknown("Playback failed while opening the direct-play stream."),
                attemptID: attemptID,
                message: "VLCKit could not create media"
            )
            return
        }

        applySubtitleStyling(to: media)
        applyNetworkBufferingOptions(to: media)
        configureAudioOutputPolicy(reason: "before-play")
        mediaPlayer.media = media
        if let rawVideoOutput {
            _ = rawVideoOutput.attach(to: mediaPlayer)
        }
        mediaPlayer.currentSubTitleFontScale = PlaybackSubtitleStyle.vlcSubtitleFontScale
        mediaPlayer.play()
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

    private func logStateChange(_ vlcState: VLCMediaPlayerState) {
        let attemptLabel = currentAttemptContext?.attemptLabel ?? "unknown"
        let parsedStatus = String(describing: mediaPlayer.media?.parsedStatus)
        vlcKitEngineLogger.debug(
            "Playback attempt \(attemptLabel, privacy: .public) VLCKit state=\(String(describing: vlcState), privacy: .public) parsedStatus=\(parsedStatus, privacy: .public) currentTime=\(self.currentTime, privacy: .public) duration=\(self.duration, privacy: .public) buffering=\(self.isBuffering, privacy: .public)"
        )
    }

    private func refreshTracks() {
        availableAudioTracks = mediaPlayer.audioTracks.map { track in
            AudioTrack(
                id: modelID(forTrackID: track.trackId),
                displayTitle: trackDisplayTitle(for: track),
                language: track.language,
                languageCode: normalizedLanguageCode(from: track.language),
                codec: track.codecName(),
                channels: Int(track.audio?.channelsNumber ?? 0).nonZeroValue,
                channelLayout: nil,
                isDecodable: Self.canDecodeAudioCodec(track.codec)
            )
        }
        selectedAudioTrackID = mediaPlayer.audioTracks.first(where: \.isSelected).map { modelID(forTrackID: $0.trackId) }
        configureAudioOutputPolicy(reason: "tracks-refreshed")

        availableSubtitleTracks = mediaPlayer.textTracks.map { track in
            SubtitleTrack(
                id: modelID(forTrackID: track.trackId),
                displayTitle: trackDisplayTitle(for: track),
                language: track.language,
                languageCode: normalizedLanguageCode(from: track.language),
                codec: track.codecName(),
                isForced: false,
                isHearingImpaired: false,
                isExternal: false,
                externalURL: nil
            )
        }
        selectedSubtitleTrackID = mediaPlayer.textTracks.first(where: \.isSelected).map { modelID(forTrackID: $0.trackId) }
    }

    /// Audio codecs present in containers that the vendored VLCKit build cannot
    /// decode. Tracks matching these are skipped by automatic selection, and
    /// picking one in the picker reroutes playback through a server transcode
    /// (see `PlayerViewModel.selectAudio`).
    ///
    /// Currently empty: the vendored frameworks are built with
    /// `ci_scripts/vlc-patches/0013`, which re-enables ffmpeg's TrueHD/MLP
    /// decoders that VLCKit's stock iOS build disables ("Codec `mlpa' is not
    /// supported"). If the frameworks are ever refreshed WITHOUT that patch
    /// (a plain `./ci_scripts/install_vlckit.sh` run), re-add
    /// `fourCC("m", "l", "p", "a")` (TrueHD) and `fourCC("m", "l", "p", " ")`
    /// (MLP) here or those tracks will select a dead decoder and go silent.
    private static let undecodableAudioFourCCs: Set<UInt32> = []

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

    private func trackDisplayTitle(for track: VLCMediaPlayer.Track) -> String {
        if !track.trackName.isEmpty {
            return track.trackName
        }

        if let description = track.trackDescription, !description.isEmpty {
            return description
        }

        if let language = track.language, !language.isEmpty {
            return language
        }

        return "Unknown"
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
        let selectedTrack = selectedVLCTrack()
        let selectedTrackLabel = selectedTrack.map { self.trackDisplayTitle(for: $0) } ?? "Unknown"
        let selectedChannels = selectedTrack.flatMap { Int($0.audio?.channelsNumber ?? 0).nonZeroValue }
        let outputChannelCount = max(
            Int(session.outputNumberOfChannels),
            outputs.compactMap { $0.channels?.count }.max() ?? 0
        )
        let maximumOutputChannelCount = max(Int(session.maximumOutputNumberOfChannels), outputChannelCount)
        #if os(tvOS)
        // tvOS drives true multichannel output to the connected receiver over
        // HDMI/eARC, so pick the richest surround layout the route can render.
        let desiredMixMode = desiredAudioMixMode(forChannelCount: selectedChannels)
        let targetMixMode = audioMixMode(
            forDesired: desiredMixMode,
            maximumOutputChannelCount: maximumOutputChannelCount
        )
        let preferredOutputChannels = preferredOutputChannelCount(for: targetMixMode)
        let wantsMultichannelOutput = preferredOutputChannels != nil
        #else
        // iOS/iPadOS: the output route is effectively stereo — built-in speaker,
        // wired, or Bluetooth/AirPods. Deliberately do NOT drive surround mix
        // modes, preferred output channel counts, or multichannel session
        // content here. Each of those restarts VLCKit's audio output, and
        // Bluetooth routes renegotiate spatial/rendering capabilities
        // constantly, which churned the output and stuttered the sound in and
        // out (worst on AirPods). Leave the mix mode unset and let VLCKit downmix
        // to the active route on its own; the rare multichannel-capable iOS route
        // (AirPlay / USB to a receiver) is handled by that same downmix path.
        // Surround is owned by the system audio session here, not forced by us.
        let targetMixMode: VLCMediaPlayer.AudioMixMode = .modeUnset
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
            audioMixModeLabel(targetMixMode),
            String(preferredOutputChannels ?? 0),
            String(wantsMultichannelOutput),
        ].joined(separator: "|")

        if signature != lastAppliedAudioConfigSignature {
            #if os(tvOS)
            if #available(tvOS 15.0, *) {
                do {
                    try session.setSupportsMultichannelContent(wantsMultichannelOutput)
                } catch {
                    vlcKitEngineLogger.debug(
                        "Failed to set multichannel audio session content support \(wantsMultichannelOutput, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
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
            if mediaPlayer.audioMixMode != targetMixMode {
                mediaPlayer.audioMixMode = targetMixMode
            }
            lastAppliedAudioMixMode = mediaPlayer.audioMixMode
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
                label: "VLC Audio Track",
                value: "\(selectedTrackLabel) / \(selectedChannels.map { "\($0)ch" } ?? "unknown channels")"
            ),
            PlaybackEngineDiagnostic(
                label: "VLC Audio Output",
                value: "mix=\(self.audioMixModeLabel(self.lastAppliedAudioMixMode)), passthrough=\(self.mediaPlayer.audio?.passthrough == true ? "On" : "Off")"
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
            "Applied VLC audio policy reason=\(reason, privacy: .public) selectedTrack=\(selectedTrackLabel, privacy: .public) selectedChannels=\(selectedChannels ?? 0, privacy: .public) mixMode=\(self.audioMixModeLabel(self.lastAppliedAudioMixMode), privacy: .public) passthrough=false outputChannels=\(outputChannelCount, privacy: .public) preferredOutputChannels=\(session.preferredOutputNumberOfChannels, privacy: .public) maxOutputChannels=\(maximumOutputChannelCount, privacy: .public) route=[\(routeSummary, privacy: .public)]"
        )
        #endif
    }

    private func selectedVLCTrack() -> VLCMediaPlayer.Track? {
        if let selectedAudioTrackID,
           let trackID = trackIDsByModelID[selectedAudioTrackID],
           let track = mediaPlayer.audioTracks.first(where: { $0.trackId == trackID }) {
            return track
        }

        return mediaPlayer.audioTracks.first(where: \.isSelected)
            ?? mediaPlayer.audioTracks.first
    }

    /// Returns a stable, unique model Int for a VLCKit `trackId`, minting one on
    /// first sight. `trackIDsByModelID` maps back so selection targets the exact
    /// VLCKit track. Reset per media load.
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

    #if os(tvOS)
    private func desiredAudioMixMode(forChannelCount channels: Int?) -> VLCMediaPlayer.AudioMixMode {
        guard let channels else { return .modeUnset }

        if channels >= 8 {
            return .mode7_1
        }
        if channels >= 6 {
            return .mode5_1
        }
        if channels >= 4 {
            return .mode4_0
        }

        return .modeUnset
    }

    /// Clamp a desired surround mix mode to what the current output route can
    /// render (tvOS only — iOS does not drive surround). Requesting a layout with
    /// more channels than the receiver supports (e.g. a 7.1 source to a 5.1
    /// receiver) can stall the audio output, so stereo/binaural/unset modes pass
    /// through untouched while surround modes step down to the largest layout that
    /// fits, falling back to an explicit stereo downmix.
    private func audioMixMode(
        forDesired desired: VLCMediaPlayer.AudioMixMode,
        maximumOutputChannelCount: Int
    ) -> VLCMediaPlayer.AudioMixMode {
        guard let requiredChannels = preferredOutputChannelCount(for: desired) else {
            return desired
        }

        if maximumOutputChannelCount >= requiredChannels {
            return desired
        }

        // Descending channel order so the first match is the richest layout
        // the route can still render.
        let surroundFallbacks: [(mode: VLCMediaPlayer.AudioMixMode, channels: Int)] = [
            (.mode5_1, 6),
            (.mode4_0, 4),
        ]
        for fallback in surroundFallbacks
        where fallback.channels < requiredChannels && maximumOutputChannelCount >= fallback.channels {
            return fallback.mode
        }

        return .modeStereo
    }

    private func preferredOutputChannelCount(for mode: VLCMediaPlayer.AudioMixMode) -> Int? {
        switch mode {
        case .mode7_1:
            8
        case .mode5_1:
            6
        case .mode4_0:
            4
        default:
            nil
        }
    }
    #endif

    private func audioMixModeLabel(_ mode: VLCMediaPlayer.AudioMixMode) -> String {
        switch mode {
        case .modeUnset:
            "Unset"
        case .modeStereo:
            "Stereo"
        case .modeBinaural:
            "Binaural"
        case .mode4_0:
            "4.0"
        case .mode5_1:
            "5.1"
        case .mode7_1:
            "7.1"
        @unknown default:
            String(describing: mode)
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
        #endif
    }
}

extension VLCKitEngine: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            self?.handleStateChange(newState)
        }
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        let timeMs = mediaPlayer.time.intValue
        Task { @MainActor [weak self] in
            self?.updateTime(timeMs: timeMs, lengthMs: Int32(length))
            self?.renderingHost.invalidatePlaybackState()
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let timeMs = mediaPlayer.time.intValue
        let lengthMs = mediaPlayer.media?.length.intValue ?? 0
        Task { @MainActor [weak self] in
            self?.updateTime(timeMs: timeMs, lengthMs: lengthMs)
        }
    }

    nonisolated func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor [weak self] in
            self?.refreshTracks()
        }
    }

    nonisolated func mediaPlayerTrackRemoved(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor [weak self] in
            self?.refreshTracks()
        }
    }

    nonisolated func mediaPlayerTrackUpdated(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor [weak self] in
            self?.refreshTracks()
        }
    }

    nonisolated func mediaPlayerTrackSelected(
        _ trackType: VLCMedia.TrackType,
        selectedId: String,
        unselectedId: String
    ) {
        Task { @MainActor [weak self] in
            self?.refreshTracks()
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
