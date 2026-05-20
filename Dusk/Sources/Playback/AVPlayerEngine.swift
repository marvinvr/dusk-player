import AVFoundation
import CoreMedia
import OSLog
import SwiftUI

private let avPlayerEngineLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "AVPlayerEngine"
)

/// Native AVPlayer-based playback engine for MP4/MOV with standard codecs.
@MainActor @Observable
final class AVPlayerEngine: PlaybackEngine {
    private static let preferredForwardBufferDuration: TimeInterval = 15

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
    var onPlaybackEnded: (@MainActor () -> Void)?

    // MARK: - AVPlayer

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored nonisolated(unsafe) private let playerLayer = AVPlayerLayer()

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

    init() {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.automaticallyWaitsToMinimizeStalling = true
        setupKVOObservers()
    }

    deinit {
        loadValidationTask?.cancel()
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
        AnyView(AVPlayerLayerRepresentable(playerLayer: playerLayer))
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
        item.preferredForwardBufferDuration = Self.preferredForwardBufferDuration
        item.textStyleRules = subtitleTextStyleRules
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
