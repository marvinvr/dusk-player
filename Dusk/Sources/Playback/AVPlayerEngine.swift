import AVFoundation
import SwiftUI

/// Native AVPlayer-based playback engine for MP4/MOV with standard codecs.
@MainActor @Observable
final class AVPlayerEngine: PlaybackEngine {

    // MARK: - PlaybackEngine State

    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isBuffering = false
    private(set) var error: PlaybackError?
    private(set) var availableSubtitleTracks: [SubtitleTrack] = []
    private(set) var availableAudioTracks: [AudioTrack] = []

    // MARK: - AVPlayer

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()

    // MARK: - Observers

    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?

    // MARK: - Track Mapping

    /// Stored so we can call `AVPlayerItem.select(_:in:)` later.
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var audioOptionsByID: [Int: AVMediaSelectionOption] = [:]
    private var subtitleOptionsByID: [Int: AVMediaSelectionOption] = [:]

    private var pendingStartPosition: TimeInterval?

    // MARK: - Init

    init() {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        player.appliesMediaSelectionCriteriaAutomatically = false
        setupKVOObservers()
    }

    // MARK: - Lifecycle

    func load(url: URL, startPosition: TimeInterval?) {
        removeTimeObserver()

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
        pendingStartPosition = startPosition

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        addTimeObserver()
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
        removeTimeObserver()
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
    }

    func seek(to position: TimeInterval) {
        let time = CMTime(seconds: position, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Track Selection

    func selectSubtitleTrack(_ track: SubtitleTrack?) {
        guard let item = player.currentItem, let group = subtitleGroup else { return }
        if let track, let option = subtitleOptionsByID[track.id] {
            item.select(option, in: group)
        } else {
            // nil disables subtitles
            item.select(nil, in: group)
        }
    }

    func selectAudioTrack(_ track: AudioTrack) {
        guard let item = player.currentItem,
              let group = audioGroup,
              let option = audioOptionsByID[track.id] else { return }
        item.select(option, in: group)
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
            Task {
                await loadDurationAndTracks()
                if let start = pendingStartPosition, start > 0 {
                    seek(to: start)
                    pendingStartPosition = nil
                }
                player.play()
            }
        case .failed:
            let msg = itemError?.localizedDescription ?? "Unknown playback error"
            error = .unknown(msg)
            state = .error
            isBuffering = false
        default:
            break
        }
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
