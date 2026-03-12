import Foundation
import SwiftUI

/// Manages player UI state: syncs from the engine via timer, handles overlay
/// visibility, scrubbing, and forwards control actions to the engine.
@MainActor @Observable
final class PlayerViewModel {

    // MARK: - Engine State (synced periodically)

    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isBuffering = false
    private(set) var hasStartedPlayback = false
    private(set) var playbackError: PlaybackError?
    private(set) var subtitleTracks: [SubtitleTrack] = []
    private(set) var audioTracks: [AudioTrack] = []

    // MARK: - UI State

    var showControls = true
    var showSubtitlePicker = false
    var showAudioPicker = false
    var isScrubbing = false
    var scrubPosition: TimeInterval = 0

    // MARK: - Private

    private let engine: any PlaybackEngine
    private var hasLoadedSource = false
    @ObservationIgnored nonisolated(unsafe) private var syncTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var hideTimer: Timer?

    // MARK: - Init / Cleanup

    init(engine: any PlaybackEngine) {
        self.engine = engine
        startSync()
        scheduleHide()
    }

    deinit {
        syncTimer?.invalidate()
        hideTimer?.invalidate()
    }

    func cleanup() {
        syncTimer?.invalidate()
        hideTimer?.invalidate()
        syncTimer = nil
        hideTimer = nil
        // Pause (not stop) so the coordinator can read final position
        // for timeline reporting before tearing down the engine.
        engine.pause()
    }

    func startPlaybackIfNeeded(source: PlaybackSource) {
        guard !hasLoadedSource else { return }
        hasLoadedSource = true
        engine.load(url: source.url, startPosition: source.startPosition)
    }

    // MARK: - Sync

    private func startSync() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sync()
            }
        }
    }

    private func sync() {
        state = engine.state
        if !isScrubbing {
            currentTime = engine.currentTime
        }
        duration = engine.duration
        isBuffering = engine.isBuffering
        if !hasStartedPlayback, (state == .playing || currentTime > 0) {
            hasStartedPlayback = true
        }
        playbackError = engine.error
        subtitleTracks = engine.availableSubtitleTracks
        audioTracks = engine.availableAudioTracks
    }

    // MARK: - Playback Controls

    func togglePlayPause() {
        if state == .playing {
            engine.pause()
        } else {
            engine.play()
        }
        touchControls()
    }

    func skipForward() {
        guard duration > 0 else { return }
        engine.seek(to: min(currentTime + 15, duration))
        touchControls()
    }

    func skipBackward() {
        engine.seek(to: max(currentTime - 15, 0))
        touchControls()
    }

    // MARK: - Scrubbing

    func beginScrub() {
        isScrubbing = true
        scrubPosition = currentTime
        hideTimer?.invalidate()
    }

    func updateScrub(to position: TimeInterval) {
        scrubPosition = max(0, min(position, duration))
    }

    func endScrub() {
        engine.seek(to: scrubPosition)
        isScrubbing = false
        touchControls()
    }

    // MARK: - Track Selection

    func selectSubtitle(_ track: SubtitleTrack?) {
        engine.selectSubtitleTrack(track)
        showSubtitlePicker = false
    }

    func selectAudio(_ track: AudioTrack) {
        engine.selectAudioTrack(track)
        showAudioPicker = false
    }

    // MARK: - Overlay Visibility

    func toggleControls() {
        showControls.toggle()
        if showControls {
            scheduleHide()
        } else {
            hideTimer?.invalidate()
        }
    }

    func touchControls() {
        showControls = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .playing, !self.isScrubbing {
                    self.showControls = false
                }
            }
        }
    }

    // MARK: - Computed Helpers

    var engineView: AnyView {
        engine.makePlayerView()
    }

    var displayPosition: TimeInterval {
        isScrubbing ? scrubPosition : currentTime
    }

    var shouldShowBufferingIndicator: Bool {
        isBuffering && !hasStartedPlayback && playbackError == nil
    }

    var formattedTime: String {
        formatTime(displayPosition)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
