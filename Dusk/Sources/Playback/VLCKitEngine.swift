#if canImport(MobileVLCKit)
import MobileVLCKit
import SwiftUI

/// PlaybackEngine implementation backed by VLCKit (MobileVLCKit 3.7.2).
///
/// Handles MKV, DTS, PGS subtitles, and any other format that AVPlayer
/// cannot natively decode. VLCKit renders into a UIView which is wrapped
/// for SwiftUI via `makePlayerView()`.
@MainActor
@Observable
final class VLCKitEngine: NSObject, PlaybackEngine {
    // MARK: - PlaybackEngine State

    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isBuffering = false
    private(set) var error: PlaybackError?
    private(set) var availableSubtitleTracks: [SubtitleTrack] = []
    private(set) var availableAudioTracks: [AudioTrack] = []

    // MARK: - VLCKit Internals

    /// Marked nonisolated(unsafe) because VLCKit calls delegate methods
    /// from its own background thread — we read player properties there,
    /// then dispatch state updates back to MainActor.
    nonisolated(unsafe) private let mediaPlayer: VLCMediaPlayer
    nonisolated(unsafe) private let vlcView: UIView

    private var pendingStartPosition: TimeInterval?
    private var hasAppliedStartPosition = false

    // MARK: - Init

    override init() {
        let player = VLCMediaPlayer()
        let view = UIView()
        view.backgroundColor = .black
        self.mediaPlayer = player
        self.vlcView = view
        super.init()
        player.delegate = self
        player.drawable = view
    }

    deinit {
        mediaPlayer.stop()
        mediaPlayer.delegate = nil
        mediaPlayer.drawable = nil
    }

    // MARK: - PlaybackEngine Lifecycle

    func load(url: URL, startPosition: TimeInterval?) {
        state = .loading
        isBuffering = true
        error = nil
        currentTime = 0
        duration = 0
        hasAppliedStartPosition = false
        pendingStartPosition = startPosition
        availableSubtitleTracks = []
        availableAudioTracks = []

        let media = VLCMedia(url: url)
        mediaPlayer.media = media
        mediaPlayer.play()
    }

    func play() {
        mediaPlayer.play()
    }

    func pause() {
        mediaPlayer.pause()
    }

    func stop() {
        mediaPlayer.stop()
        state = .stopped
    }

    func seek(to position: TimeInterval) {
        let ms = Int32(position * 1000)
        mediaPlayer.time = VLCTime(int: ms)
    }

    // MARK: - Track Selection

    func selectSubtitleTrack(_ track: SubtitleTrack?) {
        guard let track else {
            mediaPlayer.currentVideoSubTitleIndex = -1
            return
        }
        mediaPlayer.currentVideoSubTitleIndex = Int32(track.id)
    }

    func selectAudioTrack(_ track: AudioTrack) {
        mediaPlayer.currentAudioTrackIndex = Int32(track.id)
    }

    // MARK: - Rendering

    func makePlayerView() -> AnyView {
        AnyView(VLCPlayerRepresentable(playerView: vlcView))
    }

    // MARK: - Internal State Handlers

    fileprivate func handleStateChange(_ vlcState: VLCMediaPlayerState) {
        switch vlcState {
        case .opening, .buffering:
            isBuffering = true
            if state != .playing && state != .paused {
                state = .loading
            }

        case .esAdded:
            // Elementary stream discovered — refresh track lists.
            refreshTracks()

        case .playing:
            isBuffering = false
            state = .playing

            // Seek to resume position on first transition to playing
            if !hasAppliedStartPosition, let start = pendingStartPosition, start > 0 {
                hasAppliedStartPosition = true
                seek(to: start)
            }

            refreshTracks()

        case .paused:
            isBuffering = false
            state = .paused

        case .stopped:
            isBuffering = false
            state = .stopped

        case .ended:
            isBuffering = false
            state = .stopped

        case .error:
            isBuffering = false
            state = .error
            error = .unknown("VLCKit playback error")

        @unknown default:
            break
        }
    }

    fileprivate func updateTime(timeMs: Int32, lengthMs: Int32) {
        currentTime = max(0, TimeInterval(timeMs) / 1000.0)
        if lengthMs > 0 {
            duration = TimeInterval(lengthMs) / 1000.0
        }
    }

    /// Build AudioTrack/SubtitleTrack arrays from VLCKit's track name/index lists.
    /// Both arrays include "Disabled" at position 0 (with ID -1), which we skip.
    private func refreshTracks() {
        // Audio
        let audioNames = mediaPlayer.audioTrackNames as? [String] ?? []
        let audioIndexes = mediaPlayer.audioTrackIndexes as? [NSNumber] ?? []
        let count = min(audioNames.count, audioIndexes.count)

        if count > 1 {
            availableAudioTracks = (1..<count).map { i in
                AudioTrack(
                    id: audioIndexes[i].intValue,
                    displayTitle: audioNames[i],
                    language: nil,
                    languageCode: nil,
                    codec: nil,
                    channels: nil,
                    channelLayout: nil
                )
            }
        } else {
            availableAudioTracks = []
        }

        // Subtitles
        let subNames = mediaPlayer.videoSubTitlesNames as? [String] ?? []
        let subIndexes = mediaPlayer.videoSubTitlesIndexes as? [NSNumber] ?? []
        let subCount = min(subNames.count, subIndexes.count)

        if subCount > 1 {
            availableSubtitleTracks = (1..<subCount).map { i in
                SubtitleTrack(
                    id: subIndexes[i].intValue,
                    displayTitle: subNames[i],
                    language: nil,
                    languageCode: nil,
                    codec: nil,
                    isForced: false,
                    isHearingImpaired: false,
                    isExternal: false,
                    externalURL: nil
                )
            }
        } else {
            availableSubtitleTracks = []
        }
    }
}

// MARK: - VLCMediaPlayerDelegate

extension VLCKitEngine: VLCMediaPlayerDelegate {
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

// MARK: - SwiftUI UIViewRepresentable

private struct VLCPlayerRepresentable: UIViewRepresentable {
    let playerView: UIView

    func makeUIView(context: Context) -> UIView {
        playerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

#endif
