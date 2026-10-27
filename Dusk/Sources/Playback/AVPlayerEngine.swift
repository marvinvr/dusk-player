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
    // MARK: - PlaybackEngine State

    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var seekableTimeRange: ClosedRange<TimeInterval>?
    private(set) var isBuffering = false
    private(set) var error: PlaybackError?
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
        if let subtitleSelectionObserver {
            NotificationCenter.default.removeObserver(subtitleSelectionObserver)
        }
        if let captionStyleObserver {
            NotificationCenter.default.removeObserver(captionStyleObserver)
        }
    }

    // MARK: - Lifecycle

    func load(source: PlaybackSource) {
        loadValidationTask?.cancel()
        stopDolbyVision7Proxy()
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

            if let validationError = await PlaybackError.validateDirectPlayURL(source.url) {
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
        guard let pipController, pipController.isPictureInPicturePossible else { return }
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
                self?.isPictureInPicturePossible = possible
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
        if let videoEnhancementRenderer {
            // The Metal view shows the upscaled picture full-screen. Keep the real
            // `AVPlayerLayer` underneath it (fully occluded by the opaque Metal
            // view) so it stays in the view hierarchy: that is what lets native
            // Picture in Picture stay possible while enhancement is on. The PiP
            // window then projects the non-upscaled stream directly from AVPlayer.
            return AnyView(EnhancedPlayerView(engine: self, renderer: videoEnhancementRenderer))
        }
        return AnyView(AVPlayerLayerRepresentable(playerLayer: playerLayer))
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
            let playbackError = PlaybackError.fromPlaybackFailure(
                error: itemError,
                fallback: "Playback failed while opening the direct-play stream."
            )
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
        } else {
            remuxHLSLoader = nil
            item = AVPlayerItem(url: source.url)
        }
        item.preferredForwardBufferDuration = PlaybackBufferPolicy.avPlayerForwardBufferDuration
        item.textStyleRules = subtitleTextStyleRules

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
        addTimeObserver()
        loadValidationTask = nil
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
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = true
            if state != .paused {
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
                self?.isBuffering = true
            }
        }
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
            isPictureInPictureActive = true
            pictureInPictureDelegate?.pictureInPictureActiveDidChange(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated {
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
