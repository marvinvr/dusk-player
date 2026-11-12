import AVFoundation
import AudioToolbox
import CoreMedia
import OSLog
import SwiftUI
import UIKit
#if os(iOS)
import AVKit
#endif

private let avPlayerEngineLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "AVPlayerEngine"
)

/// Native AVPlayer-based playback engine for MP4/MOV with standard codecs.
///
/// Inherits `NSObject` so it can act as its own `AVPictureInPictureControllerDelegate`
/// (which requires `NSObjectProtocol`), mirroring `VLCKitEngine`.
@MainActor @Observable
final class AVPlayerEngine: NSObject, PlaybackEngine {
    /// Reads the cues of the current item, for `LiftedCueOverlay`.
    @ObservationIgnored private var legibleOutput: AVPlayerItemLegibleOutput?
    @ObservationIgnored private var latestLegibleCueText: String?
    /// The raised cue drawn over the picture; nil while AVPlayer draws its own.
    fileprivate var liftedCueOverlay: LiftedCueOverlayState?
    @ObservationIgnored private var liftedCueTargetLift: Double = 0

    // MARK: - PlaybackEngine State

    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var playbackRate: Float { player.timeControlStatus == .playing ? player.rate : 0 }
    private(set) var seekableTimeRange: ClosedRange<TimeInterval>?
    private(set) var isBuffering = false
    private(set) var error: PlaybackError?
    private(set) var currentVideoQuality: PlaybackVideoQuality?
    private(set) var availableSubtitleTracks: [SubtitleTrack] = []
    private(set) var availableAudioTracks: [AudioTrack] = []
    var selectedSubtitleTrackID: Int? {
        guard let item = player.currentItem, let group = subtitleGroup,
              let option = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return subtitleOptionsByID.first { $0.value == option }?.key
    }
    private(set) var selectedAudioTrackID: Int?
    var videoEnhancementStatus: VideoEnhancementStatus {
        if let subtitleStatus = videoEnhancementRequest.nativeSubtitleRenderingStatus(
            engine: .avPlayer,
            hasSelectedSubtitle: isRenderingNativeSubtitles
        ) {
            return subtitleStatus
        }
        if let videoEnhancementRenderer {
            return videoEnhancementRenderer.status
        }
        return videoEnhancementRequest.nonRenderingStatus
    }
    var onPlaybackEnded: (@MainActor () -> Void)?
    var supportsExternalPlayback: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
    #if os(iOS)
    private(set) var isExternalPlaybackActive = false
    #endif

    // MARK: - AVPlayer

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var videoQualityTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private let playerLayer = AVPlayerLayer()
    @ObservationIgnored nonisolated(unsafe) private var coordinatedItemIdentifier: String?
    #if os(iOS)
    private(set) var isPictureInPicturePossible = false
    private(set) var isPictureInPictureActive = false
    @ObservationIgnored private var pipController: AVPictureInPictureController?
    @ObservationIgnored nonisolated(unsafe) private var pipPossibleObserver: NSKeyValueObservation?
    @ObservationIgnored private weak var pictureInPictureDelegate: (any PlaybackPictureInPictureDelegate)?
    #endif
    /// The user's subtitle size preference, pushed in by the coordinator.
    @ObservationIgnored private var subtitleFontSize: SubtitleFontSize = .default
    @ObservationIgnored private var subtitleStyle: SubtitleStyle = .default
    @ObservationIgnored private var videoEnhancementRequest: VideoEnhancementRequest = .disabled
    @ObservationIgnored private var videoEnhancementRenderer: VideoEnhancementRenderer?
    @ObservationIgnored private var enhancedVideoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var needsEnhancedVideoRefresh = false
    private var isRenderingNativeSubtitles = false
    /// Front for `.spatialAudio` sessions (see `RemuxHLSLoader`). The
    /// asset's resource loader holds its delegate weakly, so the engine owns it
    /// for as long as the item plays.
    @ObservationIgnored private var remuxHLSLoader: RemuxHLSLoader?
    /// The FairPlay key session of an IPTV item (`IPTVAsset`); nil otherwise.
    @ObservationIgnored private var contentKeyController: FairPlayContentKeyController?
    /// IPTV only: re-request the channel when its stream ends or drops.
    @ObservationIgnored private var retunePolicy = IPTVRetunePolicy()
    @ObservationIgnored private var retuneTask: Task<Void, Never>?
    /// The current IPTV item has already scheduled its re-request (a failed
    /// key request and the item failing both report the same interruption).
    @ObservationIgnored private var isRetunePending = false
    /// Why the stream last dropped, for the error once retuning gives up.
    @ObservationIgnored private var lastRetuneReason: String?
    /// Loopback front for a Dolby Vision 7 → 8.1 session (see
    /// `DolbyVision7HLSProxy`), alive for as long as the source is loaded,
    /// and the master playlist URL it serves.
    @ObservationIgnored nonisolated(unsafe) private var dolbyVision7Proxy: DolbyVision7HLSProxy?
    @ObservationIgnored private var dolbyVision7ProxyURL: URL?
    @ObservationIgnored nonisolated(unsafe) private var enhancedVideoDisplayLink: CADisplayLink?
    @ObservationIgnored nonisolated(unsafe) private var enhancedVideoDisplayLinkTarget: AVPlayerDisplayLinkTarget?

    // MARK: - Observers

    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var timeControlStatusObserver: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var playbackEndedObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var playbackStalledObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var itemLogObservers: [NSObjectProtocol] = []
    @ObservationIgnored nonisolated(unsafe) private var subtitleSelectionObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var captionStyleObserver: NSObjectProtocol?
    #if os(iOS)
    @ObservationIgnored nonisolated(unsafe) private var externalPlaybackObserver: NSKeyValueObservation?
    #endif

    // MARK: - Track Mapping

    /// Stored so we can call `AVPlayerItem.select(_:in:)` later.
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var audioOptionsByID: [Int: AVMediaSelectionOption] = [:]
    private var subtitleOptionsByID: [Int: AVMediaSelectionOption] = [:]
    /// Preserve an explicit choice (including Off) when recovery replaces the
    /// item. AVFoundation's property-list identity survives group recreation.
    private var hasRequestedSubtitleSelection = false
    private var requestedSubtitleOption: AVMediaSelectionOption?
    private var requestedAudioOption: AVMediaSelectionOption?

    private var pendingStartPosition: TimeInterval?
    private var hasReportedPlaybackEnded = false
    private var currentAttemptContext: PlaybackAttemptContext?
    private var currentSource: PlaybackSource?
    @ObservationIgnored nonisolated(unsafe) private var loadValidationTask: Task<Void, Never>?

    // MARK: - Init

    override init() {
        super.init()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        player.playbackCoordinator.delegate = self
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.automaticallyWaitsToMinimizeStalling = true
        #if os(tvOS)
        // The coordinator owns display sleep for both engines, including
        // paused playback and the retained engine behind the Up Next screen.
        player.preventsDisplaySleepDuringVideoPlayback = false
        #endif
        #if os(iOS)
        player.allowsExternalPlayback = true
        player.externalPlaybackVideoGravity = .resizeAspect
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        externalPlaybackObserver = player.observe(
            \.isExternalPlaybackActive,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            let isActive = player.isExternalPlaybackActive
            Task { @MainActor [weak self] in
                self?.isExternalPlaybackActive = isActive
            }
        }
        #endif
        setupKVOObservers()
        #if DEBUG
        // Simulator verification runs must stay silent on the host Mac.
        if ScreenshotMode.mutesPlayback { player.isMuted = true }
        #endif
        // The renderer restyles live; only the folded-in system text size has
        // to be refreshed here.
        captionStyleObserver = NotificationCenter.default.addObserver(
            forName: SystemCaptionStyle.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                player.currentItem?.textStyleRules = subtitleTextStyleRules
            }
        }
        #if os(iOS)
        refreshPictureInPictureController()
        #endif
    }

    deinit {
        loadValidationTask?.cancel()
        dolbyVision7Proxy?.stop()
        #if os(iOS)
        externalPlaybackObserver?.invalidate()
        externalPlaybackObserver = nil
        pipPossibleObserver?.invalidate()
        pipPossibleObserver = nil
        #endif
        enhancedVideoDisplayLink?.invalidate()
        enhancedVideoDisplayLink = nil
        enhancedVideoDisplayLinkTarget = nil
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let playbackEndedObserver {
            NotificationCenter.default.removeObserver(playbackEndedObserver)
            self.playbackEndedObserver = nil
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
            self.playbackStalledObserver = nil
        }
        itemLogObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemLogObservers = []
        if let subtitleSelectionObserver {
            NotificationCenter.default.removeObserver(subtitleSelectionObserver)
        }
        if let captionStyleObserver {
            NotificationCenter.default.removeObserver(captionStyleObserver)
        }
    }

    // MARK: - Lifecycle

    func load(source: PlaybackSource) {
        liftedCueOverlay = nil
        latestLegibleCueText = nil
        guard (try? PlexTransportSecurity.validate(URLRequest(url: source.url))) != nil else {
            stop()
            error = .networkError("A secure connection is required to send the Plex token.")
            state = .error
            return
        }
        loadValidationTask?.cancel()
        stopDolbyVision7Proxy()
        invalidateContentKeyController()
        cancelIPTVRetune()
        retunePolicy.reset()
        lastRetuneReason = nil
        removeEnhancedVideoOutput()
        removeTimeObserver()
        removePlaybackEndedObserver()
        removePlaybackStalledObserver()
        removeSubtitleSelectionObserver()
        player.defaultRate = 1

        currentAttemptContext = source.context
        currentSource = source
        state = .loading
        error = nil
        isBuffering = true
        currentTime = 0
        duration = 0
        seekableTimeRange = nil
        availableAudioTracks = []
        availableSubtitleTracks = []
        audioOptionsByID = [:]
        subtitleOptionsByID = [:]
        audioGroup = nil
        subtitleGroup = nil
        selectedAudioTrackID = nil
        pendingStartPosition = source.startPosition
        hasRequestedSubtitleSelection = false
        requestedSubtitleOption = nil
        requestedAudioOption = nil
        hasReportedPlaybackEnded = false

        #if os(tvOS)
        restoreMultichannelAudioSession()
        #endif

        avPlayerEngineLogger.notice(
            "Playback attempt \(source.context.attemptLabel, privacy: .public) starting in AVPlayer for ratingKey \(source.context.ratingKey, privacy: .public), media \(source.context.mediaID, privacy: .public), part \(source.context.partID, privacy: .public), URL \(source.context.sanitizedPlaybackURL, privacy: .public)"
        )

        let attemptID = source.context.attemptID
        loadValidationTask = Task { [weak self] in
            guard let self else { return }

            if let target = source.dolbyVision7Conversion {
                // The proxy's preflight fetches the master playlist, which
                // validates the URL too.
                await self.startDolbyVision7Proxy(source: source, target: target, attemptID: attemptID)
                return
            }

            // IPTV streams need their source's headers to answer at all, and
            // are not Plex direct-play files: AVPlayer reports their errors.
            if source.iptvStream == nil,
               let validationError = await PlaybackError.validateDirectPlayURL(source.url) {
                guard !Task.isCancelled else { return }
                self.failLoad(
                    validationError,
                    attemptID: attemptID,
                    message: "direct-play validation failed"
                )
                return
            }

            guard !Task.isCancelled else { return }
            self.finishValidatedLoad(source: source, attemptID: attemptID)
        }
    }

    #if os(tvOS)
    /// libvlc switches `supportsMultichannelContent` OFF on the shared audio
    /// session every time it starts its own audio output — `avas_SetActive`
    /// passes its own spatial-audio flag, which is still false on the first
    /// bring-up — and on tvOS nothing ever switches it back on:
    /// `DuskApp.configurePlaybackAudioSession` runs once at launch and
    /// `PlaybackNowPlayingController` owns the session on iOS only. Without
    /// this, one VLCKit title leaves every later AVPlayer title downmixed to
    /// stereo for the rest of the app's lifetime, even though AVPlayer feeds
    /// tvOS multichannel AC-3/E-AC-3 natively.
    private func restoreMultichannelAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setSupportsMultichannelContent(true)
        } catch {
            avPlayerEngineLogger.debug(
                "Failed to restore multichannel audio session content support: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    #endif

    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {
        videoEnhancementRequest = request
        videoEnhancementRenderer = VideoEnhancementRenderer(request: request)
        #if os(iOS)
        // PiP renders from the `AVPlayerLayer`. Even with Video Enhancement active
        // the layer stays in the hierarchy (behind the Metal view — see
        // `makePlayerView()`), so native PiP keeps working; the floating window
        // just shows the non-upscaled stream straight from AVPlayer.
        refreshPictureInPictureController()
        #endif
    }

    func play() {
        player.play()
    }

    var playbackCoordinator: AVPlaybackCoordinator {
        player.playbackCoordinator
    }

    func configureCoordinatedPlayback(itemIdentifier: String?) {
        coordinatedItemIdentifier = itemIdentifier
    }

    func pause() {
        player.pause()
        state = .paused
    }

    func setPlaybackRate(_ rate: Float) {
        let resolvedRate = max(rate, 0.1)
        player.defaultRate = resolvedRate

        // Writing a non-zero current rate also starts a paused AVPlayer. Keep
        // rate changes transport-neutral so releasing a hold cannot undo a
        // pause delivered by another control in the meantime.
        if player.timeControlStatus != .paused {
            player.rate = resolvedRate
        }
    }

    func stop() {
        loadValidationTask?.cancel()
        loadValidationTask = nil
        stopDolbyVision7Proxy()
        invalidateContentKeyController()
        cancelIPTVRetune()
        stopVideoQualityMonitor()
        removeEnhancedVideoOutput()
        player.pause()
        player.defaultRate = 1
        removeTimeObserver()
        removePlaybackEndedObserver()
        removePlaybackStalledObserver()
        removeSubtitleSelectionObserver()
        player.replaceCurrentItem(with: nil)

        state = .stopped
        isBuffering = false
        currentTime = 0
        duration = 0
        seekableTimeRange = nil
        availableAudioTracks = []
        availableSubtitleTracks = []
        audioOptionsByID = [:]
        subtitleOptionsByID = [:]
        audioGroup = nil
        subtitleGroup = nil
        selectedAudioTrackID = nil
        hasReportedPlaybackEnded = false
        currentAttemptContext = nil
        currentSource = nil
        hasRequestedSubtitleSelection = false
        requestedSubtitleOption = nil
        requestedAudioOption = nil
    }

    func seek(to position: TimeInterval) {
        seek(to: position, precise: true)
    }

    /// `precise: true` (and the plain `seek(to:)`) is frame-accurate — used for
    /// scrub commits and the initial resume seek, where the position is exact.
    /// `precise: false` allows ~2 s of tolerance each side so AVPlayer can land
    /// on a nearby keyframe instead of decoding up to the exact frame, which is
    /// much faster on long-GOP content and fine for transient double-tap/remote
    /// skip jumps.
    func seek(to position: TimeInterval, precise: Bool) {
        // Publish the target straight away, as VLCKit does. The periodic
        // observer only reports once the seek resolves, so without this the
        // play bar (and the marker state derived from it) keeps describing the
        // pre-seek position while the seek is in flight. A seek that lands
        // elsewhere corrects itself on the next observer tick.
        currentTime = clampedPosition(position)

        let time = CMTime(seconds: position, preferredTimescale: 1000)
        if precise {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let tolerance = CMTime(seconds: 2, preferredTimescale: 1000)
            player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }

    private func clampedPosition(_ position: TimeInterval) -> TimeInterval {
        if let seekableTimeRange {
            return min(max(position, seekableTimeRange.lowerBound), seekableTimeRange.upperBound)
        }
        if duration > 0 {
            return min(max(position, 0), duration)
        }
        return max(position, 0)
    }

    func recoverFromStall() {
        guard let source = currentSource else {
            player.play()
            return
        }

        let recoveryPosition = recoveryStartPosition(for: source)
        if let currentAttemptContext {
            avPlayerEngineLogger.notice(
                "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) AVPlayer recovering stalled playback at \(recoveryPosition, privacy: .public)s"
            )
        }

        loadValidationTask?.cancel()
        removeEnhancedVideoOutput()
        removeTimeObserver()
        removePlaybackEndedObserver()
        removePlaybackStalledObserver()
        removeSubtitleSelectionObserver()
        player.pause()

        error = nil
        state = .loading
        isBuffering = true
        pendingStartPosition = recoveryPosition
        hasReportedPlaybackEnded = false
        availableAudioTracks = []
        availableSubtitleTracks = []
        // Keep audio/subtitle option identities until discovery replaces them: a
        // picker already on screen may submit a choice during this rebuild.
        audioGroup = nil
        subtitleGroup = nil
        selectedAudioTrackID = nil

        finishValidatedLoad(source: source, attemptID: source.context.attemptID)
    }

    func setVideoFillEnabled(_ enabled: Bool) {
        playerLayer.videoGravity = enabled ? .resizeAspectFill : .resizeAspect
        videoEnhancementRenderer?.setVideoFillEnabled(enabled)
    }

    #if os(iOS)
    // MARK: - Picture in Picture

    func setPictureInPictureDelegate(_ delegate: (any PlaybackPictureInPictureDelegate)?) {
        pictureInPictureDelegate = delegate
    }

    func startPictureInPicture() {
        guard let pipController else { return }
        guard pipController.isPictureInPicturePossible else {
            avPlayerEngineLogger.notice("AVPlayer PiP start ignored: controller not possible")
            return
        }
        pipController.startPictureInPicture()
    }

    func stopPictureInPicture() {
        pipController?.stopPictureInPicture()
    }

    /// Builds the native `AVPictureInPictureController` from the player layer, or
    /// tears it down when the device lacks PiP support. The controller is kept
    /// alive in Video Enhancement mode too: `makePlayerView()` keeps the
    /// `AVPlayerLayer` in the hierarchy behind the Metal view, so it still has a
    /// live layer to project the (non-upscaled) stream into the floating window.
    private func refreshPictureInPictureController() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            teardownPictureInPictureController()
            return
        }
        guard pipController == nil else { return }

        let source = AVPictureInPictureController.ContentSource(playerLayer: playerLayer)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // Hand playback off to the floating window automatically when the app
        // is backgrounded mid-playback, matching standard video-app behavior.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
        pipPossibleObserver = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard let self, self.isPictureInPicturePossible != possible else { return }
                avPlayerEngineLogger.debug("AVPlayer PiP possible=\(possible, privacy: .public)")
                self.isPictureInPicturePossible = possible
            }
        }
    }

    private func teardownPictureInPictureController() {
        pipPossibleObserver?.invalidate()
        pipPossibleObserver = nil
        pipController?.delegate = nil
        pipController = nil
        isPictureInPicturePossible = false
        isPictureInPictureActive = false
    }
    #endif

    func handleReturnToForeground() {
        #if os(iOS)
        // The floating window renders from this very layer: detaching the
        // player now (the app becomes active while PiP keeps running) would
        // blank or kill the window. The layer's pipeline was never torn down
        // in that case anyway.
        if isPictureInPictureActive { return }
        #endif
        // Re-attach the player to its layer to restore the GPU rendering pipeline
        // that iOS tears down when the app is backgrounded.
        playerLayer.player = nil
        playerLayer.player = player

        // Force AVPlayer to decode and display the current keyframe now,
        // so the frame is already visible before the user presses play.
        let currentTime = player.currentTime()
        if currentTime.isValid && !currentTime.isIndefinite {
            player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: - Track Selection

    func selectSubtitleTrack(_ track: SubtitleTrack?) {
        if let track {
            guard let option = subtitleOptionsByID[track.id] else { return }
            requestedSubtitleOption = option
        } else {
            requestedSubtitleOption = nil
        }
        hasRequestedSubtitleSelection = true
        applyRequestedSubtitleSelection()
    }

    private func applyRequestedSubtitleSelection() {
        guard hasRequestedSubtitleSelection,
              let item = player.currentItem, let group = subtitleGroup else { return }
        let option: AVMediaSelectionOption?
        if let requestedSubtitleOption {
            guard let match = group.mediaSelectionOption(
                withPropertyList: requestedSubtitleOption.propertyList()
            ) else { return }
            option = match
        } else {
            option = nil
        }
        item.select(option, in: group)
        updateNativeSubtitleRendering()
    }

    private func updateNativeSubtitleRendering() {
        let isSelected: Bool
        if let item = player.currentItem, let group = subtitleGroup {
            isSelected = item.currentMediaSelection.selectedMediaOption(in: group) != nil
        } else {
            isSelected = false
        }
        guard isRenderingNativeSubtitles != isSelected else { return }
        isRenderingNativeSubtitles = isSelected
        // Discard pre-caption frames before the Metal view is mounted again.
        videoEnhancementRenderer?.clear()
        needsEnhancedVideoRefresh = !isSelected
    }

    func selectAudioTrack(_ track: AudioTrack) {
        guard let option = audioOptionsByID[track.id] else { return }
        requestedAudioOption = option
        guard let item = player.currentItem,
              let group = audioGroup else { return }
        item.select(option, in: group)
        selectedAudioTrackID = track.id
    }

    // MARK: - Rendering

    func makePlayerView() -> AnyView {
        // Both platforms render through AVPlayerLayer, not AVPlayerViewController.
        // PlaybackNowPlayingController is the sole Now Playing/remote-command
        // owner. If a controller is introduced, disable its
        // updatesNowPlayingInfoCenter before attaching the player.
        if let videoEnhancementRenderer {
            // The Metal view shows the upscaled picture full-screen. Keep the real
            // `AVPlayerLayer` underneath it (fully occluded by the opaque Metal
            // view) so it stays in the view hierarchy: that is what lets native
            // Picture in Picture stay possible while enhancement is on. The PiP
            // window then projects the non-upscaled stream directly from AVPlayer.
            return AnyView(ZStack {
                EnhancedPlayerView(engine: self, renderer: videoEnhancementRenderer)
                LiftedCueOverlay(engine: self)
            })
        }
        return AnyView(ZStack {
            AVPlayerLayerRepresentable(playerLayer: playerLayer)
            LiftedCueOverlay(engine: self)
        })
    }

    // PlayerViewModel caches engineView. Observe the engine inside this view,
    // so subtitle changes reveal the native layer immediately, even paused.
    private struct EnhancedPlayerView: View {
        let engine: AVPlayerEngine
        let renderer: VideoEnhancementRenderer

        var body: some View {
            ZStack {
                AVPlayerLayerRepresentable(playerLayer: engine.playerLayer)
                if !engine.isRenderingNativeSubtitles {
                    VideoEnhancementRepresentable(renderer: renderer)
                }
            }
        }
    }

    // MARK: - Private: KVO

    private func setupKVOObservers() {
        // Item readiness / failure
        statusObserver = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            let status = player.currentItem?.status
            let itemError = player.currentItem?.error
            Task { @MainActor [weak self] in
                self?.handleItemStatus(status, itemError: itemError)
            }
        }

        // Playing / paused / buffering
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                self?.handleTimeControlStatus(status)
            }
        }
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status?, itemError: Error?) {
        switch status {
        case .readyToPlay:
            if let currentAttemptContext {
                avPlayerEngineLogger.notice(
                    "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) AVPlayer item ready"
                )
            }
            guard let attemptID = currentAttemptContext?.attemptID,
                  let item = player.currentItem else { return }
            Task { [weak self] in
                await self?.prepareReadyItemForPlayback(item, attemptID: attemptID)
            }
        case .failed:
            // Live channels retune; a catch-up programme is a finite stream
            // and fails like any other.
            if let stream = currentSource?.iptvStream, !stream.isCatchUp {
                let cause = contentKeyController?.lastError ?? itemError
                if IPTVRetunePolicy.isRetryable(cause) {
                    let reason = contentKeyController?.lastError?.localizedDescription
                        ?? IPTVAsset.failureMessage(for: itemError)
                    if let currentAttemptContext {
                        avPlayerEngineLogger.notice(
                            "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) IPTV stream dropped, retuning [\(Self.errorChainDescription(itemError), privacy: .public)]"
                        )
                    }
                    scheduleIPTVRetune(reason: reason)
                    return
                }
            }
            if let stream = currentSource?.iptvStream, stream.isCatchUp,
               contentKeyController?.lastError == nil,
               let attemptID = currentAttemptContext?.attemptID {
                failIPTVCatchUp(stream, itemError: itemError, attemptID: attemptID)
                return
            }
            let playbackError: PlaybackError
            if let keyError = contentKeyController?.lastError {
                playbackError = .unknown(keyError.localizedDescription)
            } else if currentSource?.iptvStream != nil {
                // Not a Plex file: the Plex direct-play wording would mislead.
                playbackError = .unknown(IPTVAsset.failureMessage(for: itemError))
            } else {
                playbackError = PlaybackError.fromPlaybackFailure(
                    error: itemError,
                    fallback: "Playback failed while opening the direct-play stream."
                )
            }
            if let currentAttemptContext {
                avPlayerEngineLogger.error(
                    "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) AVPlayer failed: \(playbackError.localizedDescription, privacy: .public) [\(Self.errorChainDescription(itemError), privacy: .public)]\(Self.lastErrorLogDescription(self.player.currentItem), privacy: .public)"
                )
            }
            error = playbackError
            state = .error
            isBuffering = false
        default:
            break
        }
    }

    private func finishValidatedLoad(source: PlaybackSource, attemptID: UUID) {
        guard currentAttemptContext?.attemptID == attemptID else { return }

        let item: AVPlayerItem
        if source.dolbyVision7Conversion != nil {
            // Never the bare remux in its place: without the proxy, fail so
            // the coordinator retries the remux without conversion.
            guard let dolbyVision7ProxyURL else {
                failLoad(
                    .unknown("Dolby Vision 7 conversion is unavailable for this stream."),
                    attemptID: attemptID,
                    message: "Dolby Vision 7 proxy is not running"
                )
                return
            }
            remuxHLSLoader = nil
            item = AVPlayerItem(url: dolbyVision7ProxyURL)
        } else if source.usesRemuxHLSLoader {
            let loader = RemuxHLSLoader(
                restoresDolbyAtmos: source.restoresDolbyAtmos,
                dolbyVision: source.dolbyVisionRemux
            )
            if let asset = RemuxHLSLoader.makeAsset(url: source.url, loader: loader) {
                remuxHLSLoader = loader
                item = AVPlayerItem(asset: asset)
            } else {
                remuxHLSLoader = nil
                item = AVPlayerItem(url: source.url)
            }
        } else if let stream = source.iptvStream {
            remuxHLSLoader = nil
            invalidateContentKeyController()
            let asset = IPTVAsset.makeAsset(for: stream)
            if FairPlayContentKeyController.isSupported {
                let controller = FairPlayContentKeyController(client: IPTVAsset.licenseClient(for: stream))
                controller.onError = { [weak self] error in
                    self?.failIPTVKeyRequest(error, attemptID: attemptID)
                }
                controller.attach(to: asset)
                contentKeyController = controller
            } else if stream.drm?.keySystem == .fairPlay {
                failLoad(
                    .unknown(FairPlayError.unavailableOnSimulator.localizedDescription),
                    attemptID: attemptID,
                    message: "FairPlay unavailable"
                )
                return
            }
            item = AVPlayerItem(asset: asset)
        } else {
            remuxHLSLoader = nil
            item = AVPlayerItem(url: source.url)
        }
        item.preferredForwardBufferDuration = PlaybackBufferPolicy.avPlayerForwardBufferDuration
        item.textStyleRules = subtitleTextStyleRules
        let legibleOutput = AVPlayerItemLegibleOutput()
        legibleOutput.setDelegate(self, queue: .main)
        item.add(legibleOutput)
        self.legibleOutput = legibleOutput

        if videoEnhancementRenderer != nil {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            item.add(output)
            enhancedVideoOutput = output
            startEnhancedVideoDisplayLink()
        }

        player.replaceCurrentItem(with: item)
        observeSubtitleSelection(for: item)
        observePlaybackEnd(for: item)
        observePlaybackStall(for: item)
        observeItemLogs(for: item)
        addTimeObserver()
        startVideoQualityMonitor(for: item)
        loadValidationTask = nil

        // A live stream asks to play right away instead of after
        // `.readyToPlay`. A cold Plex Live TV tune opens with a playlist of
        // one or two 1 s segments; at rate 0 AVPlayer loads it once and the
        // item never becomes ready (reproduced in the simulator: still not
        // ready after 40 s), so a play() gated on readiness never comes.
        // With a rate requested it reloads the growing playlist and starts
        // as soon as the window allows (`automaticallyWaitsToMinimizeStalling`);
        // the play() after readiness is then a no-op. The other half of that
        // spinner was incomplete segments (see `transcodeQueryItems`).
        if source.isLiveStream, source.shouldAutoPlay, (source.startPosition ?? 0) <= 0 {
            player.play()
        }
    }

    // MARK: - Private: Dolby Vision 7 conversion

    /// Brings the loopback proxy up for `source` and loads its master
    /// playlist; a failed preflight fails the load, which the coordinator
    /// answers by retrying the remux without conversion.
    private func startDolbyVision7Proxy(
        source: PlaybackSource,
        target: DolbyVisionConfiguration,
        attemptID: UUID
    ) async {
        let proxy = DolbyVision7HLSProxy(
            upstreamMasterURL: source.url,
            target: target,
            restoresDolbyAtmos: source.restoresDolbyAtmos
        )
        proxy.onFatalError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.failDolbyVision7Conversion(error, attemptID: attemptID)
            }
        }
        dolbyVision7Proxy = proxy

        do {
            let url = try await proxy.start()
            guard !Task.isCancelled, dolbyVision7Proxy === proxy else {
                if dolbyVision7Proxy === proxy {
                    stopDolbyVision7Proxy()
                } else {
                    proxy.stop()
                }
                return
            }
            dolbyVision7ProxyURL = url
            finishValidatedLoad(source: source, attemptID: attemptID)
        } catch {
            let isCurrentProxy = dolbyVision7Proxy === proxy
            if isCurrentProxy {
                stopDolbyVision7Proxy()
            }
            guard isCurrentProxy, !Task.isCancelled else { return }
            failLoad(
                .unknown("Dolby Vision 7 conversion is unavailable for this stream."),
                attemptID: attemptID,
                message: "Dolby Vision 7 proxy preflight failed (\(String(describing: error)))"
            )
        }
    }

    /// The proxy hit something it cannot convert mid-session.
    private func failDolbyVision7Conversion(_ conversionError: DolbyVision7ConversionError, attemptID: UUID) {
        guard currentAttemptContext?.attemptID == attemptID, state != .error else { return }
        avPlayerEngineLogger.error(
            "Playback attempt \(self.currentAttemptContext?.attemptLabel ?? "unknown", privacy: .public) Dolby Vision 7 conversion failed: \(String(describing: conversionError), privacy: .public)"
        )
        player.pause()
        error = .unknown("Dolby Vision 7 conversion failed.")
        state = .error
        isBuffering = false
    }

    // MARK: - IPTV retune

    private func noteIPTVPlaybackProgress() {
        guard currentSource?.iptvStream != nil else { return }
        if player.timeControlStatus == .playing {
            retunePolicy.playing(at: .now)
        } else {
            retunePolicy.notPlaying()
        }
    }

    /// Stays in the player on a spinner and re-requests the same channel URL
    /// after the policy's backoff, with a fresh item and a fresh FairPlay key
    /// session. Gives up — the normal error, with Retry — only when the
    /// channel has kept failing for `IPTVRetunePolicy.giveUpAfter`.
    private func scheduleIPTVRetune(reason: String) {
        guard let source = currentSource, let stream = source.iptvStream, !stream.isCatchUp,
              !isRetunePending else { return }
        lastRetuneReason = reason
        let attemptID = source.context.attemptID

        switch retunePolicy.interrupted(at: .now) {
        case .giveUp:
            cancelIPTVRetune()
            failLoad(
                .unknown("This channel stopped responding. \(lastRetuneReason ?? "")"
                    .trimmingCharacters(in: .whitespaces)),
                attemptID: attemptID,
                message: "IPTV retune gave up"
            )
        case .retune(let delay):
            isRetunePending = true
            error = nil
            state = .loading
            isBuffering = true
            avPlayerEngineLogger.notice(
                "Playback attempt \(source.context.attemptLabel, privacy: .public) IPTV retune in \(delay, privacy: .public)s"
            )
            retuneTask?.cancel()
            retuneTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self,
                      self.currentAttemptContext?.attemptID == attemptID else { return }
                self.retuneIPTV(source)
            }
        }
    }

    private func retuneIPTV(_ source: PlaybackSource) {
        retuneTask = nil
        stopVideoQualityMonitor()
        removeEnhancedVideoOutput()
        removeTimeObserver()
        removePlaybackEndedObserver()
        removePlaybackStalledObserver()
        removeSubtitleSelectionObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)

        pendingStartPosition = nil
        hasReportedPlaybackEnded = false
        availableAudioTracks = []
        availableSubtitleTracks = []
        audioGroup = nil
        subtitleGroup = nil
        selectedAudioTrackID = nil
        isRetunePending = false

        // A new asset and (on device) a new key session: the next item may
        // be FairPlay-protected even when the slate before it was not.
        finishValidatedLoad(source: source, attemptID: source.context.attemptID)
    }

    private func cancelIPTVRetune() {
        retuneTask?.cancel()
        retuneTask = nil
        isRetunePending = false
    }

    private func invalidateContentKeyController() {
        contentKeyController?.onError = nil
        contentKeyController?.invalidate()
        contentKeyController = nil
    }

    /// A failed key request surfaces with its own reason right away; waiting
    /// for the item to fail showed a generic AVFoundation message, or nothing
    /// at all while the player kept buffering.
    private func failIPTVKeyRequest(_ keyError: Error, attemptID: UUID) {
        guard currentAttemptContext?.attemptID == attemptID, state != .error else { return }
        if currentSource?.iptvStream?.isCatchUp != true, IPTVRetunePolicy.isRetryable(keyError) {
            scheduleIPTVRetune(reason: keyError.localizedDescription)
            return
        }
        failLoad(.unknown(keyError.localizedDescription), attemptID: attemptID, message: "FairPlay key request failed")
    }

    /// A catch-up item that failed stays on the spinner for the moment it
    /// takes to ask the server why, then fails with the server's reason. The
    /// attempt check drops the answer when the viewer has already left.
    private func failIPTVCatchUp(_ stream: IPTVPlayableChannel, itemError: Error?, attemptID: UUID) {
        Task { @MainActor [weak self] in
            let refusal = await IPTVAsset.catchUpRefusal(for: stream)
            self?.failLoad(
                .unknown(refusal ?? IPTVAsset.failureMessage(for: itemError, isCatchUp: true)),
                attemptID: attemptID,
                message: "IPTV catch-up failed [\(Self.errorChainDescription(itemError))]"
            )
        }
    }

    private func stopDolbyVision7Proxy() {
        dolbyVision7Proxy?.stop()
        dolbyVision7Proxy = nil
        dolbyVision7ProxyURL = nil
    }

    private func failLoad(_ error: PlaybackError, attemptID: UUID, message: String) {
        guard currentAttemptContext?.attemptID == attemptID else { return }

        if let currentAttemptContext {
            avPlayerEngineLogger.error(
                "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) AVPlayer \(message, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        self.error = error
        state = .error
        isBuffering = false
        loadValidationTask = nil
    }

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            state = .playing
            isBuffering = false
        case .paused:
            // Only transition to .paused from .playing — don't overwrite
            // .loading or .stopped states.
            if state == .playing {
                state = .paused
            }
            // A stopped player is waiting for nothing. Left set, this reads as a
            // stall for as long as the viewer stays paused, and stall recovery
            // then reloads the item. Not while loading: that wait is real.
            if state == .paused {
                isBuffering = false
            }
        case .waitingToPlayAtSpecifiedRate:
            // Delivered asynchronously, so a pause may have overtaken it.
            guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            isBuffering = true
            if state == .paused {
                // Resumed, and the stream has to refill first: that is a stall
                // like any other, spinner included, not a frozen paused frame.
                state = hasReportedPlaybackEnded ? .stopped : .playing
            } else {
                state = hasReportedPlaybackEnded ? .stopped : state
            }
        @unknown default:
            break
        }
    }

    private func prepareReadyItemForPlayback(
        _ item: AVPlayerItem,
        attemptID: UUID
    ) async {
        await loadDurationAndTracks(for: item)
        guard currentAttemptContext?.attemptID == attemptID,
              player.currentItem === item else { return }

        if let start = pendingStartPosition, start > 0 {
            let target = CMTime(seconds: start, preferredTimescale: 1000)
            let finished = await player.seek(
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            guard currentAttemptContext?.attemptID == attemptID,
                  player.currentItem === item else { return }
            guard finished else {
                avPlayerEngineLogger.error(
                    "Playback attempt \(self.currentAttemptContext?.attemptLabel ?? "unknown", privacy: .public) AVPlayer resume seek was interrupted at \(start, privacy: .public)s"
                )
                error = .unknown("Couldn’t resume playback at the saved position.")
                state = .error
                isBuffering = false
                return
            }
            pendingStartPosition = nil
            avPlayerEngineLogger.notice(
                "Playback attempt \(self.currentAttemptContext?.attemptLabel ?? "unknown", privacy: .public) AVPlayer resumed at \(start, privacy: .public)s"
            )
        }

        applyRequestedSubtitleSelection()
        if currentSource?.shouldAutoPlay == false {
            state = .paused
            isBuffering = false
        } else {
            player.play()
        }
    }

    // MARK: - Private: Time Observer

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            let seekableRange = self?.player.currentItem?.seekableTimeRanges.last?.timeRangeValue
            Task { @MainActor [weak self] in
                self?.currentTime = seconds
                self?.noteIPTVPlaybackProgress()
                if let seekableRange {
                    let start = CMTimeGetSeconds(seekableRange.start)
                    let end = CMTimeGetSeconds(CMTimeRangeGetEnd(seekableRange))
                    if start.isFinite, end.isFinite, end >= start {
                        self?.seekableTimeRange = start...end
                    }
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func observePlaybackEnd(for item: AVPlayerItem) {
        playbackEndedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded()
            }
        }
    }

    private func observePlaybackStall(for item: AVPlayerItem) {
        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.timeControlStatus != .paused else { return }
                if let context = self.currentAttemptContext {
                    avPlayerEngineLogger.notice(
                        "Playback attempt \(context.attemptLabel, privacy: .public) AVPlayer stalled at \(self.player.currentTime().seconds, privacy: .public)s"
                    )
                }
                self.isBuffering = true
            }
        }
    }

    /// Mirrors the item's access and error logs into the unified log, so a
    /// stream that never starts shows which playlist or segment AVPlayer
    /// fetched last and what it rejected (Plex Live TV hung on a spinner
    /// with nothing but the server log to go on). URLs lose their query: it
    /// can carry the Plex token or IPTV credentials.
    private func observeItemLogs(for item: AVPlayerItem) {
        let center = NotificationCenter.default
        let access = center.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let event = item?.accessLog()?.events.last else { return }
            let line = "requests \(event.numberOfMediaRequests), stalls \(event.numberOfStalls), startup \(String(format: "%.2f", event.startupTime))s, indicated \(Int(event.indicatedBitrate)), observed \(Int(event.observedBitrate)), transferred \(event.numberOfBytesTransferred) B, uri \(Self.logSafeURI(event.uri))"
            Task { @MainActor [weak self] in
                guard let label = self?.currentAttemptContext?.attemptLabel else { return }
                avPlayerEngineLogger.notice(
                    "Playback attempt \(label, privacy: .public) AVPlayer access log: \(line, privacy: .public)"
                )
            }
        }
        let errors = center.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let event = item?.errorLog()?.events.last else { return }
            let line = "\(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "-"), uri \(Self.logSafeURI(event.uri))"
            Task { @MainActor [weak self] in
                guard let label = self?.currentAttemptContext?.attemptLabel else { return }
                avPlayerEngineLogger.error(
                    "Playback attempt \(label, privacy: .public) AVPlayer error log: \(line, privacy: .public)"
                )
            }
        }
        itemLogObservers = [access, errors]
    }

    nonisolated private static func logSafeURI(_ uri: String?) -> String {
        guard let uri, var components = URLComponents(string: uri) else { return uri ?? "-" }
        components.query = nil
        components.user = nil
        components.password = nil
        return components.string ?? "-"
    }

    private func removePlaybackEndedObserver() {
        if let playbackEndedObserver {
            NotificationCenter.default.removeObserver(playbackEndedObserver)
            self.playbackEndedObserver = nil
        }
    }

    private func removePlaybackStalledObserver() {
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
            self.playbackStalledObserver = nil
        }
        itemLogObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemLogObservers = []
    }

    private func startEnhancedVideoDisplayLink() {
        enhancedVideoDisplayLink?.invalidate()
        let target = AVPlayerDisplayLinkTarget(engine: self)
        let displayLink = CADisplayLink(target: target, selector: #selector(AVPlayerDisplayLinkTarget.tick(_:)))
        displayLink.add(to: .main, forMode: .common)
        enhancedVideoDisplayLinkTarget = target
        enhancedVideoDisplayLink = displayLink
    }

    private func removeEnhancedVideoOutput() {
        enhancedVideoDisplayLink?.invalidate()
        enhancedVideoDisplayLink = nil
        enhancedVideoDisplayLinkTarget = nil
        if let enhancedVideoOutput,
           let item = player.currentItem {
            item.remove(enhancedVideoOutput)
        }
        enhancedVideoOutput = nil
        needsEnhancedVideoRefresh = false
        videoEnhancementRenderer?.clear()
    }

    private func observeSubtitleSelection(for item: AVPlayerItem) {
        // Includes AVFoundation automatic/accessibility choices and changes
        // while paused, in addition to Dusk's manual/automatic track picker.
        subtitleSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.updateNativeSubtitleRendering()
            }
        }
    }

    private func removeSubtitleSelectionObserver() {
        if let subtitleSelectionObserver {
            NotificationCenter.default.removeObserver(subtitleSelectionObserver)
            self.subtitleSelectionObserver = nil
        }
        isRenderingNativeSubtitles = false
    }

    fileprivate func renderEnhancedFrame(hostTime: CFTimeInterval) {
        updateNativeSubtitleRendering()
        guard !isRenderingNativeSubtitles else { return }
        guard let enhancedVideoOutput,
              let videoEnhancementRenderer else {
            return
        }

        let itemTime = enhancedVideoOutput.itemTime(forHostTime: hostTime)
        // Turning subtitles off while paused must redraw the current frame,
        // even if this output already delivered it before captions were on.
        guard needsEnhancedVideoRefresh || enhancedVideoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return }

        var displayTime = CMTime.invalid
        guard let pixelBuffer = enhancedVideoOutput.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: &displayTime
        ) else {
            return
        }

        needsEnhancedVideoRefresh = false
        videoEnhancementRenderer.submit(pixelBuffer: pixelBuffer)
    }

    private func handlePlaybackEnded() {
        // A live IPTV channel never "ends": `EXT-X-ENDLIST` is a source
        // finishing its off-air slate (or the live session), so ask for the
        // channel again and stay in the player.
        if let stream = currentSource?.iptvStream, !stream.isCatchUp {
            scheduleIPTVRetune(reason: "The channel’s stream ended.")
            return
        }
        guard !hasReportedPlaybackEnded else { return }
        hasReportedPlaybackEnded = true
        if let currentAttemptContext {
            avPlayerEngineLogger.notice(
                "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) AVPlayer reached end of playback"
            )
        }
        currentTime = duration
        state = .stopped
        isBuffering = false
        onPlaybackEnded?()
    }

    private func recoveryStartPosition(for source: PlaybackSource) -> TimeInterval {
        let observedTime = CMTimeGetSeconds(player.currentTime())
        let engineTime = observedTime.isFinite ? observedTime : currentTime
        let fallback = source.startPosition ?? 0
        return max(0, engineTime.isFinite ? engineTime : fallback)
    }

    /// Applies the new size to the live item as well: `textStyleRules` is
    /// settable on an `AVPlayerItem` that is already playing, so the size
    /// changes on screen without reloading anything.
    func applySubtitleFontSize(_ size: SubtitleFontSize) {
        guard subtitleFontSize != size else { return }
        subtitleFontSize = size
        player.currentItem?.textStyleRules = subtitleTextStyleRules
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        guard subtitleStyle != style else { return }
        subtitleStyle = style
        player.currentItem?.textStyleRules = subtitleTextStyleRules
    }

    /// AVPlayer's renderer cannot move a cue already on screen (a rule's line
    /// position only applies from the next cue, and tx3g ignores rules), so
    /// while raised the cues come from the legible output and are drawn by
    /// `LiftedCueOverlay` instead.
    func setSubtitleClearance(_ clearance: SubtitleClearance?) {
        let videoSize = player.currentItem?.presentationSize ?? .zero
        let fillsContainer = playerLayer.videoGravity == .resizeAspectFill
        let lift = clearance?.lift(
            videoSize: videoSize,
            fillsContainer: fillsContainer,
            restingCueBottom: LiftedCueOverlay.restingCueBottom
        ) ?? 0
        setLiftedCueOverlay(lift: lift, clearance: clearance, videoSize: videoSize, fillsContainer: fillsContainer)
    }

    private func setLiftedCueOverlay(
        lift: Double,
        clearance: SubtitleClearance?,
        videoSize: CGSize,
        fillsContainer: Bool
    ) {
        guard lift > 0, let clearance else {
            guard var overlay = liftedCueOverlay else { return }
            overlay.lift = 0
            liftedCueOverlay = overlay
            handBackLiftedCueIfDone()
            return
        }

        liftedCueTargetLift = lift
        let pictureHeight = clearance.pictureHeight(videoSize: videoSize, fillsContainer: fillsContainer)
        var overlay = liftedCueOverlay ?? LiftedCueOverlayState(
            text: latestLegibleCueText,
            style: .current(for: subtitleStyle),
            textScale: Double(PlaybackSubtitleStyle.avPlayerRelativeFontSize(for: subtitleFontSize)) / 100,
            pictureHeight: pictureHeight,
            pictureBottomInset: (clearance.containerSize.height - pictureHeight) / 2,
            lift: 0
        )
        let isNew = liftedCueOverlay == nil
        overlay.pictureHeight = pictureHeight
        overlay.pictureBottomInset = (clearance.containerSize.height - pictureHeight) / 2
        legibleOutput?.suppressesPlayerRendering = true

        if isNew {
            flushRenderedNativeCue()
            // Mount at the cue's own place first, so it visibly rises from there.
            liftedCueOverlay = overlay
            Task { @MainActor [weak self] in
                guard let self, self.liftedCueOverlay != nil else { return }
                self.liftedCueOverlay?.lift = self.liftedCueTargetLift
            }
        } else {
            overlay.lift = lift
            liftedCueOverlay = overlay
        }
    }

    /// Suppressing rendering only applies from the next cue. Dropping the track
    /// clears the one on screen, which would otherwise stay behind the raised
    /// copy for the rest of its time. HLS needs about a second to let go of it;
    /// the overlay holds the text meanwhile.
    private func flushRenderedNativeCue() {
        guard latestLegibleCueText != nil, let item = player.currentItem, let subtitleGroup,
              let option = item.currentMediaSelection.selectedMediaOption(in: subtitleGroup) else { return }
        item.select(nil, in: subtitleGroup)
        Task { @MainActor [weak item] in
            try? await Task.sleep(for: .seconds(1))
            // A track picked in the meantime wins.
            guard let item, item.currentMediaSelection.selectedMediaOption(in: subtitleGroup) == nil else { return }
            item.select(option, in: subtitleGroup)
        }
    }

    /// Native rendering only redraws from the next cue, so the overlay keeps a
    /// cue still on screen until it ends, then hands the track back.
    private func handBackLiftedCueIfDone() {
        guard let overlay = liftedCueOverlay, overlay.lift == 0, overlay.text == nil else { return }
        liftedCueOverlay = nil
        legibleOutput?.suppressesPlayerRendering = false
    }

    fileprivate func noteLegibleCue(_ text: String?) {
        latestLegibleCueText = text
        guard liftedCueOverlay != nil else { return }
        liftedCueOverlay?.text = text
        handBackLiftedCueIfDone()
    }

    /// System style: size only. Colours, background, edge and font come from
    /// the system caption style (`SystemCaptionStyle`), which AVPlayer's
    /// renderer applies by itself for every attribute these rules leave alone.
    /// A size rule replaces the system's text size, so that is folded back in
    /// here. Dusk style: the rules override the system look as well.
    private var subtitleTextStyleRules: [AVTextStyleRule] {
        let caption = SystemCaptionStyle.current(for: subtitleStyle)
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String:
                PlaybackSubtitleStyle.avPlayerRelativeFontSize(
                    for: subtitleFontSize,
                    systemScale: caption.relativeSize
                ),
        ]
        if subtitleStyle == .dusk {
            let foreground = caption.foreground
            let background = caption.background
            attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] =
                [foreground.alpha, foreground.red, foreground.green, foreground.blue]
            attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] =
                [background.alpha, background.red, background.green, background.blue]
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] =
                kCMTextMarkupCharacterEdgeStyle_DropShadow
            attributes[kCMTextMarkupAttribute_FontFamilyName as String] =
                VLCTextRendererStyle.defaultFont
        }

        guard let rule = AVTextStyleRule(textMarkupAttributes: attributes) else {
            return []
        }

        return [rule]
    }

    // MARK: - Private: Duration & Tracks

    private func loadDurationAndTracks(for item: AVPlayerItem) async {
        guard player.currentItem === item else { return }
        let asset = item.asset

        // Duration
        if let dur = try? await asset.load(.duration) {
            guard player.currentItem === item else { return }
            let secs = CMTimeGetSeconds(dur)
            if secs.isFinite { duration = secs }
        }

        // Diagnostic only; it can poll for a few seconds on HLS, so it must
        // not hold up the track lists below.
        Task { [weak self] in await self?.logAudioFormat(of: item) }

        // Audio tracks via AVMediaSelectionGroup
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            guard player.currentItem === item else { return }
            audioGroup = group
            availableAudioTracks = []
            audioOptionsByID = [:]
            for (i, option) in group.options.enumerated() {
                let langCode = option.locale?.language.languageCode?.identifier
                let lang = langCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                availableAudioTracks.append(AudioTrack(
                    id: i,
                    displayTitle: option.displayName,
                    language: lang,
                    languageCode: langCode,
                    codec: nil,
                    channels: nil,
                    channelLayout: nil
                ))
                audioOptionsByID[i] = option
            }
            let selectedOption = requestedAudioOption.flatMap {
                group.mediaSelectionOption(withPropertyList: $0.propertyList())
            } ?? item.currentMediaSelection.selectedMediaOption(in: group)
                ?? group.defaultOption
                ?? group.options.first
            if let selectedOption {
                item.select(selectedOption, in: group)
                selectedAudioTrackID = audioOptionsByID.first { $0.value === selectedOption }?.key
            }
        }

        // Subtitle tracks via AVMediaSelectionGroup
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            guard player.currentItem === item else { return }
            subtitleGroup = group
            availableSubtitleTracks = []
            subtitleOptionsByID = [:]
            for (i, option) in group.options.enumerated() {
                let langCode = option.locale?.language.languageCode?.identifier
                let lang = langCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                availableSubtitleTracks.append(SubtitleTrack(
                    id: i,
                    displayTitle: option.displayName,
                    language: lang,
                    languageCode: langCode,
                    codec: nil,
                    isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
                    isHearingImpaired: option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility),
                    isExternal: false,
                    externalURL: nil
                ))
                subtitleOptionsByID[i] = option
            }
            applyRequestedSubtitleSelection()
            updateNativeSubtitleRendering()
        }
    }
}

// MARK: - Current video quality

extension AVPlayerEngine {
    /// How often the playing quality is re-read. An HLS variant switch shows up
    /// within this; reading is cheap, and nothing is written unless it changed.
    private static let videoQualityInterval: Duration = .seconds(2)

    fileprivate func startVideoQualityMonitor(for item: AVPlayerItem) {
        stopVideoQualityMonitor()
        videoQualityTask = Task { [weak self, weak item] in
            while !Task.isCancelled {
                // Scoped so it ends before the sleep: the task must not keep the
                // engine alive.
                do {
                    guard let item, let engine = self, engine.player.currentItem === item else { return }
                    await engine.refreshVideoQuality(of: item)
                }
                try? await Task.sleep(for: AVPlayerEngine.videoQualityInterval)
            }
        }
    }

    fileprivate func stopVideoQualityMonitor() {
        videoQualityTask?.cancel()
        videoQualityTask = nil
        currentVideoQuality = nil
    }

    private func refreshVideoQuality(of item: AVPlayerItem) async {
        var quality = PlaybackVideoQuality()

        // Follows the variant on screen, unlike anything read from the asset.
        let size = item.presentationSize
        if size.width > 0, size.height > 0 {
            quality.width = Int(exactly: size.width.rounded())
            quality.height = Int(exactly: size.height.rounded())
        }

        // `indicatedBitrate` is the playing variant's declared BANDWIDTH;
        // negative or zero when the stream has none (progressive files,
        // playlists without a master).
        let accessLogEvent = item.accessLog()?.events.last
        let indicatedBitrate = accessLogEvent?.indicatedBitrate ?? 0
        if indicatedBitrate > 0 {
            quality.bitrate = Int(exactly: indicatedBitrate.rounded())
        }

        let variants = await hlsVariants(of: item)
        if let variant = Self.playingVariant(among: variants, indicatedBitrate: indicatedBitrate, size: size) {
            let attributes = variant.videoAttributes
            quality.frameRate = attributes?.nominalFrameRate.flatMap(PlaybackVideoQuality.snappedFrameRate)
            if let attributes {
                let fourCCs = attributes.codecTypes.map(Self.videoFourCC)
                quality.codec = PlaybackVideoQuality.codecName(for: fourCCs.first)
                quality.dynamicRange = fourCCs.contains(where: PlaybackVideoQuality.isDolbyVisionCodec)
                    ? PlaybackVideoQuality.dolbyVisionLabel
                    : Self.dynamicRangeLabel(attributes.videoRange)
            }
        }

        // The track fills what the playlist didn't declare, and is all there is
        // for a progressive file. HLS item tracks appear once segments arrive.
        let itemTrack = item.tracks.first { $0.assetTrack?.mediaType == .video }
        if let assetTrack = itemTrack?.assetTrack {
            if let description = try? await assetTrack.load(.formatDescriptions).first {
                let fourCC = Self.videoFourCC(CMFormatDescriptionGetMediaSubType(description))
                quality.codec = quality.codec ?? PlaybackVideoQuality.codecName(for: fourCC)
                quality.dynamicRange = quality.dynamicRange ?? Self.dynamicRangeLabel(of: description, fourCC: fourCC)
            }
            if quality.frameRate == nil, let nominal = try? await assetTrack.load(.nominalFrameRate) {
                quality.frameRate = PlaybackVideoQuality.snappedFrameRate(Double(nominal))
            }
            if quality.bitrate == nil, let estimated = try? await assetTrack.load(.estimatedDataRate), estimated > 0 {
                quality.bitrate = Int(exactly: estimated.rounded())
                quality.bitrateIsEstimate = true
            }
        }
        if quality.frameRate == nil, let measured = itemTrack?.currentVideoFrameRate {
            quality.frameRate = PlaybackVideoQuality.snappedFrameRate(Double(measured))
        }
        if quality.bitrate == nil, let average = accessLogEvent?.averageVideoBitrate, average > 0 {
            quality.bitrate = Int(exactly: average.rounded())
            quality.bitrateIsEstimate = true
        }

        // The awaits above can outlive the item.
        guard player.currentItem === item, !quality.isEmpty else { return }
        let settled = quality.holdingEstimatedBitrate(from: currentVideoQuality)
        if settled != currentVideoQuality {
            currentVideoQuality = settled
        }
    }

    /// Empty for a progressive file. Already loaded by the time the item plays,
    /// so this costs no extra playlist request.
    private func hlsVariants(of item: AVPlayerItem) async -> [AVAssetVariant] {
        guard let asset = item.asset as? AVURLAsset else { return [] }
        return (try? await asset.load(.variants)) ?? []
    }

    /// The variant behind the current picture: BANDWIDTH is what the access log
    /// indicates, and the picture size settles the rest (a master can repeat a
    /// video rung per audio rendition, which describes the same video anyway).
    private static func playingVariant(
        among variants: [AVAssetVariant],
        indicatedBitrate: Double,
        size: CGSize
    ) -> AVAssetVariant? {
        if variants.count == 1 { return variants[0] }
        if indicatedBitrate > 0,
           let match = variants.first(where: { $0.peakBitRate == indicatedBitrate || $0.averageBitRate == indicatedBitrate }) {
            return match
        }
        guard size.width > 0 else { return nil }
        return variants.first { variant in
            guard let declared = variant.videoAttributes?.presentationSize else { return false }
            return abs(declared.width - size.width) < 2 && abs(declared.height - size.height) < 2
        }
    }

    private static func dynamicRangeLabel(_ range: AVVideoRange) -> String? {
        switch range {
        case .sdr: PlaybackVideoQuality.sdrLabel
        case .pq: PlaybackVideoQuality.hdr10Label
        case .hlg: PlaybackVideoQuality.hlgLabel
        default: nil
        }
    }

    private static func dynamicRangeLabel(of description: CMFormatDescription, fourCC: String) -> String {
        if PlaybackVideoQuality.isDolbyVisionCodec(fourCC) {
            return PlaybackVideoQuality.dolbyVisionLabel
        }
        let transfer = CMFormatDescriptionGetExtension(
            description,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String
        if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String {
            return PlaybackVideoQuality.hdr10Label
        }
        if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String {
            return PlaybackVideoQuality.hlgLabel
        }
        return PlaybackVideoQuality.sdrLabel
    }

    /// CoreMedia subtypes pack their characters big endian.
    private static func videoFourCC(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension AVPlayerEngine {
    /// Logs the audio format AVFoundation will decode, including whether it
    /// exposes the Dolby Atmos (E-AC-3 JOC, `ec+3`) layer — the signal that
    /// Atmos reaches HDMI and AirPods spatial audio gets object audio.
    fileprivate func logAudioFormat(of item: AVPlayerItem) async {
        // HLS assets report no tracks of their own; the item's tracks carry
        // the asset tracks once it is ready.
        var audioTrack = try? await item.asset.loadTracks(withMediaType: .audio).first
        if audioTrack == nil {
            for _ in 0..<20 where audioTrack == nil {
                audioTrack = item.tracks.compactMap(\.assetTrack).first { $0.mediaType == .audio }
                if audioTrack == nil { try? await Task.sleep(for: .milliseconds(250)) }
            }
        }
        guard let track = audioTrack,
              let description = try? await track.load(.formatDescriptions).first,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return
        }
        let format = Self.fourCCString(streamDescription.mFormatID)
        let isAtmos = Self.formatListContains(Self.kAudioFormatEnhancedAC3JOC, in: description)
        // Native decoding owns the compressed stream's channel layout. Log
        // its actual tag rather than inferring a PCM order from Plex's count.
        let layoutTag = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil)?
            .pointee.mChannelLayoutTag
        avPlayerEngineLogger.notice(
            "AVPlayer audio format \(format, privacy: .public), \(streamDescription.mChannelsPerFrame, privacy: .public) ch, layoutTag=\(layoutTag.map(String.init) ?? "unspecified", privacy: .public), Dolby Atmos: \(isAtmos ? "yes" : "no", privacy: .public)"
        )
    }

    /// `domain code` pairs down the underlying-error chain, for diagnosis.
    fileprivate static func errorChainDescription(_ error: Error?) -> String {
        var parts: [String] = []
        var current = error as NSError?
        while let nsError = current, parts.count < 4 {
            parts.append("\(nsError.domain) \(nsError.code)")
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.isEmpty ? "no error" : parts.joined(separator: " <- ")
    }

    fileprivate static func lastErrorLogDescription(_ item: AVPlayerItem?) -> String {
        guard let event = item?.errorLog()?.events.last else { return "" }
        return " errorLog: \(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "")"
    }

    /// E-AC-3 JOC (Dolby Atmos) surfaces as an extra `ec+3` layer in the
    /// format list AudioToolbox derives from the track's magic cookie.
    private static let kAudioFormatEnhancedAC3JOC: AudioFormatID = 0x6563_2B33 // 'ec+3'

    private static func formatListContains(_ formatID: AudioFormatID, in description: CMAudioFormatDescription) -> Bool {
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return false
        }
        var cookieSize = 0
        guard let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &cookieSize),
              cookieSize > 0 else {
            return streamDescription.mFormatID == formatID
        }
        var info = AudioFormatInfo(
            mASBD: streamDescription,
            mMagicCookie: cookie,
            mMagicCookieSize: UInt32(cookieSize)
        )
        var size: UInt32 = 0
        let infoSize = UInt32(MemoryLayout<AudioFormatInfo>.size)
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList, infoSize, &info, &size) == noErr,
              size > 0 else {
            return false
        }
        var items = [AudioFormatListItem](
            repeating: AudioFormatListItem(),
            count: Int(size) / MemoryLayout<AudioFormatListItem>.size
        )
        guard AudioFormatGetProperty(kAudioFormatProperty_FormatList, infoSize, &info, &size, &items) == noErr else {
            return false
        }
        return items.contains { $0.mASBD.mFormatID == formatID }
    }

    private static func fourCCString(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}

#if os(iOS)
/// Carries a non-`Sendable` value (an AVKit completion handler) across into a
/// main-actor closure. Safe here because the handler is created and invoked on
/// the main thread only.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// AVKit calls these on the main thread; `assumeIsolated` keeps the hops
// synchronous so the restore handshake stays in order with `didStop`.
extension AVPlayerEngine: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated {
            avPlayerEngineLogger.notice("AVPlayer PiP did start")
            isPictureInPictureActive = true
            pictureInPictureDelegate?.pictureInPictureActiveDidChange(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated {
            avPlayerEngineLogger.notice("AVPlayer PiP did stop")
            isPictureInPictureActive = false
            pictureInPictureDelegate?.pictureInPictureActiveDidChange(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // AVKit hands us this handler on the main thread and we only ever call it
        // on the main thread; box it so it can cross into the main-actor closure
        // under strict concurrency.
        let handler = UncheckedSendableBox(completionHandler)
        MainActor.assumeIsolated {
            if let pictureInPictureDelegate {
                pictureInPictureDelegate.pictureInPictureRestorePlayerUI(completion: handler.value)
            } else {
                handler.value(true)
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        MainActor.assumeIsolated {
            avPlayerEngineLogger.error(
                "AVPlayer PiP failed to start: \(error.localizedDescription, privacy: .public)"
            )
            isPictureInPictureActive = false
        }
    }
}
#endif

// A Plex item can be delivered from different URLs on each participant (local
// download, direct play, or a per-user transcode). Give AVFoundation the same
// explicit identity VLCKit uses so mixed-engine groups still synchronize.
extension AVPlayerEngine: AVPlayerPlaybackCoordinatorDelegate {
    nonisolated func playbackCoordinator(
        _ coordinator: AVPlayerPlaybackCoordinator,
        identifierFor playerItem: AVPlayerItem
    ) -> String {
        coordinatedItemIdentifier ?? playerItem.asset.description
    }
}

// MARK: - SwiftUI Bridge

/// Wraps an `AVPlayerLayer` for use in SwiftUI.
extension AVPlayerEngine: AVPlayerItemLegibleOutputPushDelegate {
    nonisolated func legibleOutput(
        _ output: AVPlayerItemLegibleOutput,
        didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers nativeSamples: [Any],
        forItemTime itemTime: CMTime
    ) {
        let text = strings.map(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        MainActor.assumeIsolated {
            noteLegibleCue(text.isEmpty ? nil : text)
        }
    }
}

fileprivate struct LiftedCueOverlayState {
    var text: String?
    var style: SystemCaptionStyle
    var textScale: Double
    var pictureHeight: CGFloat
    var pictureBottomInset: CGFloat
    var lift: Double
}

/// Draws a raised subtitle in the caption style's colours, matching where and
/// how large AVPlayer's own renderer draws it, so taking over is hardly visible.
private struct LiftedCueOverlay: View {
    /// An unpositioned cue's bottom edge above the picture's bottom, as a
    /// fraction of the picture height.
    static let restingCueBottom = 0.05
    /// The renderer's text height at 100%, as a fraction of the picture.
    private static let fontHeight = 0.047

    let engine: AVPlayerEngine

    var body: some View {
        if let overlay = engine.liftedCueOverlay {
            VStack {
                Spacer(minLength: 0)
                if let text = overlay.text {
                    Text(text)
                        .font(font(overlay))
                        .foregroundStyle(Color(overlay.style.foreground))
                        .shadow(color: .black.opacity(overlay.style.edge == .none ? 0 : 0.6), radius: 1, y: 1)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, overlay.pictureHeight * 0.02)
                        .background(
                            Color(overlay.style.background),
                            in: RoundedRectangle(cornerRadius: overlay.pictureHeight * 0.016, style: .continuous)
                        )
                }
            }
            .padding(.bottom, overlay.pictureBottomInset + overlay.pictureHeight * Self.restingCueBottom)
            .offset(y: -overlay.lift * overlay.pictureHeight)
            .animation(.easeInOut(duration: 0.3), value: overlay.lift)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func font(_ overlay: LiftedCueOverlayState) -> Font {
        let size = overlay.pictureHeight * Self.fontHeight * overlay.textScale * overlay.style.relativeSize
        if let family = overlay.style.fontFamily {
            return .custom(family, fixedSize: size)
        }
        return .system(size: size)
    }
}

private extension Color {
    init(_ color: SystemCaptionStyle.Color) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

private struct AVPlayerLayerRepresentable: UIViewRepresentable {
    let playerLayer: AVPlayerLayer

    func makeUIView(context: Context) -> AVPlayerUIView {
        AVPlayerUIView(playerLayer: playerLayer)
    }

    func updateUIView(_ uiView: AVPlayerUIView, context: Context) {}
}

/// UIView that hosts an `AVPlayerLayer` and keeps it sized to bounds.
final class AVPlayerUIView: UIView {
    private let playerLayer: AVPlayerLayer

    init(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Disable implicit CALayer animation so the layer resizes instantly.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private final class AVPlayerDisplayLinkTarget: NSObject {
    weak var engine: AVPlayerEngine?

    init(engine: AVPlayerEngine) {
        self.engine = engine
    }

    @objc func tick(_ displayLink: CADisplayLink) {
        let timestamp = displayLink.timestamp
        Task { @MainActor [weak engine] in
            engine?.renderEnhancedFrame(hostTime: timestamp)
        }
    }
}
