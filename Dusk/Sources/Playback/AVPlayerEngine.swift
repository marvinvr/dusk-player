import AVFoundation
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
    private(set) var isBuffering = false
    private(set) var error: PlaybackError?
    private(set) var availableSubtitleTracks: [SubtitleTrack] = []
    private(set) var availableAudioTracks: [AudioTrack] = []
    private(set) var selectedSubtitleTrackID: Int?
    private(set) var selectedAudioTrackID: Int?
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

    // MARK: - AVPlayer

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored nonisolated(unsafe) private let playerLayer = AVPlayerLayer()
    #if os(iOS)
    private(set) var isPictureInPicturePossible = false
    private(set) var isPictureInPictureActive = false
    @ObservationIgnored private var pipController: AVPictureInPictureController?
    @ObservationIgnored nonisolated(unsafe) private var pipPossibleObserver: NSKeyValueObservation?
    @ObservationIgnored private weak var pictureInPictureDelegate: (any PlaybackPictureInPictureDelegate)?
    #endif
    @ObservationIgnored private var videoEnhancementRequest: VideoEnhancementRequest = .disabled
    @ObservationIgnored private var videoEnhancementRenderer: VideoEnhancementRenderer?
    @ObservationIgnored private var enhancedVideoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored nonisolated(unsafe) private var enhancedVideoDisplayLink: CADisplayLink?
    @ObservationIgnored nonisolated(unsafe) private var enhancedVideoDisplayLinkTarget: AVPlayerDisplayLinkTarget?

    // MARK: - Observers

    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var timeControlStatusObserver: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var playbackEndedObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var playbackStalledObserver: NSObjectProtocol?

    // MARK: - Track Mapping

    /// Stored so we can call `AVPlayerItem.select(_:in:)` later.
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var audioOptionsByID: [Int: AVMediaSelectionOption] = [:]
    private var subtitleOptionsByID: [Int: AVMediaSelectionOption] = [:]

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
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.automaticallyWaitsToMinimizeStalling = true
        setupKVOObservers()
        #if os(iOS)
        refreshPictureInPictureController()
        #endif
    }

    deinit {
        loadValidationTask?.cancel()
        #if os(iOS)
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
    }

    // MARK: - Lifecycle

    func load(source: PlaybackSource) {
        loadValidationTask?.cancel()
        removeEnhancedVideoOutput()
        removeTimeObserver()
        removePlaybackEndedObserver()
        removePlaybackStalledObserver()

        currentAttemptContext = source.context
        currentSource = source
        state = .loading
        error = nil
        isBuffering = true
        currentTime = 0
        duration = 0
        availableAudioTracks = []
        availableSubtitleTracks = []
        audioOptionsByID = [:]
        subtitleOptionsByID = [:]
        audioGroup = nil
        subtitleGroup = nil
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        pendingStartPosition = source.startPosition
        hasReportedPlaybackEnded = false

        avPlayerEngineLogger.notice(
            "Playback attempt \(source.context.attemptLabel, privacy: .public) starting in AVPlayer for ratingKey \(source.context.ratingKey, privacy: .public), media \(source.context.mediaID, privacy: .public), part \(source.context.partID, privacy: .public), URL \(source.context.sanitizedPlaybackURL, privacy: .public)"
        )

        let attemptID = source.context.attemptID
        loadValidationTask = Task { [weak self] in
            guard let self else { return }

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

    func pause() {
        player.pause()
        state = .paused
    }

    func stop() {
        loadValidationTask?.cancel()
        loadValidationTask = nil
        removeEnhancedVideoOutput()
        player.pause()
        removeTimeObserver()
        removePlaybackEndedObserver()
        removePlaybackStalledObserver()
        player.replaceCurrentItem(with: nil)

        state = .stopped
        isBuffering = false
        currentTime = 0
        duration = 0
        availableAudioTracks = []
        availableSubtitleTracks = []
        audioOptionsByID = [:]
        subtitleOptionsByID = [:]
        audioGroup = nil
        subtitleGroup = nil
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        hasReportedPlaybackEnded = false
        currentAttemptContext = nil
        currentSource = nil
    }

    func seek(to position: TimeInterval) {
        let time = CMTime(seconds: position, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
        player.pause()

        error = nil
        state = .loading
        isBuffering = true
        pendingStartPosition = recoveryPosition
        hasReportedPlaybackEnded = false
        availableAudioTracks = []
        availableSubtitleTracks = []
        audioOptionsByID = [:]
        subtitleOptionsByID = [:]
        audioGroup = nil
        subtitleGroup = nil
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil

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
        guard let item = player.currentItem, let group = subtitleGroup else { return }
        if let track, let option = subtitleOptionsByID[track.id] {
            item.select(option, in: group)
            selectedSubtitleTrackID = track.id
        } else {
            // nil disables subtitles
            item.select(nil, in: group)
            selectedSubtitleTrackID = nil
        }
    }

    func selectAudioTrack(_ track: AudioTrack) {
        guard let item = player.currentItem,
              let group = audioGroup,
              let option = audioOptionsByID[track.id] else { return }
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
            return AnyView(
                ZStack {
                    AVPlayerLayerRepresentable(playerLayer: playerLayer)
                    VideoEnhancementRepresentable(renderer: videoEnhancementRenderer)
                }
            )
        }
        return AnyView(AVPlayerLayerRepresentable(playerLayer: playerLayer))
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
            Task {
                await loadDurationAndTracks()
                if let start = pendingStartPosition, start > 0 {
                    seek(to: start)
                    pendingStartPosition = nil
                }
                player.play()
            }
        case .failed:
            let playbackError = PlaybackError.fromPlaybackFailure(
                error: itemError,
                fallback: "Playback failed while opening the direct-play stream."
            )
            if let currentAttemptContext {
                avPlayerEngineLogger.error(
                    "Playback attempt \(currentAttemptContext.attemptLabel, privacy: .public) AVPlayer failed: \(playbackError.localizedDescription, privacy: .public)"
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

        let item = AVPlayerItem(url: source.url)
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
        observePlaybackEnd(for: item)
        observePlaybackStall(for: item)
        addTimeObserver()
        loadValidationTask = nil
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

    // MARK: - Private: Time Observer

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                self?.currentTime = seconds
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
        videoEnhancementRenderer?.clear()
    }

    fileprivate func renderEnhancedFrame(hostTime: CFTimeInterval) {
        guard let enhancedVideoOutput,
              let videoEnhancementRenderer else {
            return
        }

        let itemTime = enhancedVideoOutput.itemTime(forHostTime: hostTime)
        guard enhancedVideoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return }

        var displayTime = CMTime.invalid
        guard let pixelBuffer = enhancedVideoOutput.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: &displayTime
        ) else {
            return
        }

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

    private var subtitleTextStyleRules: [AVTextStyleRule] {
        let attributes: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [1.0, 1.0, 1.0, 1.0],
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: [0.68, 0.0, 0.0, 0.0],
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: kCMTextMarkupCharacterEdgeStyle_DropShadow,
            kCMTextMarkupAttribute_RelativeFontSize as String: PlaybackSubtitleStyle.avPlayerRelativeFontSize,
        ]

        guard let rule = AVTextStyleRule(textMarkupAttributes: attributes) else {
            return []
        }

        return [rule]
    }

    // MARK: - Private: Duration & Tracks

    private func loadDurationAndTracks() async {
        guard let item = player.currentItem else { return }
        let asset = item.asset

        // Duration
        if let dur = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(dur)
            if secs.isFinite { duration = secs }
        }

        // Audio tracks via AVMediaSelectionGroup
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            audioGroup = group
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
            let selectedOption = item.currentMediaSelection.selectedMediaOption(in: group)
                ?? group.defaultOption
                ?? group.options.first
            if let selectedOption {
                item.select(selectedOption, in: group)
                selectedAudioTrackID = audioOptionsByID.first { $0.value === selectedOption }?.key
            }
        }

        // Subtitle tracks via AVMediaSelectionGroup
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            subtitleGroup = group
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
            if let selectedOption = item.currentMediaSelection.selectedMediaOption(in: group) {
                selectedSubtitleTrackID = subtitleOptionsByID.first { $0.value === selectedOption }?.key
            } else {
                selectedSubtitleTrackID = nil
            }
        }
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
