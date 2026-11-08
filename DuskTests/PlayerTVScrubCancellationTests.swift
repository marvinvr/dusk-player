#if os(tvOS)
import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Dusk

@MainActor
struct PlayerTVScrubCancellationTests {
    @Test func backCancelsTouchPreviewBeforeItCanDismissPlayback() {
        let engine = ScrubPlaybackEngine()
        let viewModel = PlayerViewModel(engine: engine)
        viewModel.sync()
        let hud = PlayerTVHUDController()
        hud.viewModel = viewModel
        var dismissals = 0
        hud.onDismissPlayer = { dismissals += 1 }
        defer { hud.cleanup(); viewModel.cleanup() }

        hud.handle(.panBegan)
        hud.handle(.panChanged(translationX: 220, velocityX: 300))
        #expect((hud.scrubTarget ?? 0) > engine.currentTime)
        hud.handle(.panEnded)
        hud.handle(.menu)
        #expect(hud.mode == .hidden)
        #expect(hud.previewPosition == nil)
        #expect(engine.seeks.isEmpty)
        #expect(engine.state == .playing)
        #expect(engine.currentTime == 120)
        #expect(engine.playPauseCalls == 0)
        #expect(dismissals == 0)

        // Only the next Back, with no pending preview, may close the player.
        hud.handle(.menu)
        #expect(dismissals == 1)
    }

    @Test func backDuringActivePanReleasesArrowSuppressionAndIgnoresTrailingPan() {
        let engine = ScrubPlaybackEngine()
        let viewModel = PlayerViewModel(engine: engine)
        viewModel.sync()
        let hud = PlayerTVHUDController()
        hud.viewModel = viewModel
        defer { hud.cleanup(); viewModel.cleanup() }

        hud.handle(.panBegan)
        hud.handle(.panChanged(translationX: 150, velocityX: 300))
        hud.handle(.menu)
        hud.handle(.panChanged(translationX: 300, velocityX: 300))
        #expect(hud.previewPosition == nil)
        hud.handle(.arrowDown(.up))
        #expect(hud.mode == .transport)
        #expect(engine.seeks.isEmpty)
    }

    @Test func visibilityRaceCannotDiscardPreviewAndPausedPlaybackStaysPaused() {
        let engine = ScrubPlaybackEngine()
        engine.state = .paused
        let viewModel = PlayerViewModel(engine: engine)
        viewModel.sync()
        let hud = PlayerTVHUDController()
        hud.viewModel = viewModel
        hud.syncControlsVisibility(true)
        defer { hud.cleanup(); viewModel.cleanup() }

        hud.handle(.panBegan)
        let originalTarget = hud.scrubTarget
        viewModel.showControls = false
        hud.syncControlsVisibility(false)
        #expect(hud.mode == .scrubbing)
        #expect(hud.scrubTarget == originalTarget)
        #expect(viewModel.showControls)
        hud.handle(.menu)
        #expect(hud.mode == .transport)
        #expect(hud.previewPosition == nil)
        #expect(engine.state == .paused)
        #expect(engine.playPauseCalls == 0)
        #expect(engine.seeks.isEmpty)
    }

    @Test func backAlsoCancelsDebouncedClickSeekBeforeItReachesEngine() async throws {
        let engine = ScrubPlaybackEngine()
        let viewModel = PlayerViewModel(engine: engine)
        viewModel.sync()
        let hud = PlayerTVHUDController()
        hud.viewModel = viewModel
        var dismissals = 0
        hud.onDismissPlayer = { dismissals += 1 }
        defer { hud.cleanup(); viewModel.cleanup() }

        hud.handle(.arrowDown(.right))
        hud.handle(.arrowUp(.right))
        #expect(hud.seekPreviewPosition != nil)
        hud.handle(.menu)
        try await Task.sleep(for: PlayerTVHUDLayout.seekCommitDebounce + .milliseconds(100))
        #expect(hud.previewPosition == nil)
        #expect(hud.transientBadge == nil)
        #expect(engine.seeks.isEmpty)
        #expect(dismissals == 0)
    }

    @Test func unsetSeekIntervalsMatchTheSettingsDefault() {
        let hud = PlayerTVHUDController()
        let fallback = PlayerSeekInterval.fifteenSeconds.timeInterval
        #expect(hud.backwardSeekInterval == fallback)
        #expect(hud.forwardSeekInterval == fallback)
    }

    @Test func clickSeekAndSkipButtonsUseTheConfiguredIntervals() async throws {
        let engine = ScrubPlaybackEngine()
        let viewModel = PlayerViewModel(engine: engine)
        viewModel.sync()
        let hud = PlayerTVHUDController()
        hud.viewModel = viewModel
        hud.backwardSeekInterval = 30
        hud.forwardSeekInterval = 45
        hud.actions = [
            .skipBackward(seconds: 30),
            .skipForward(seconds: 45),
        ]
        defer { hud.cleanup(); viewModel.cleanup() }

        hud.handle(.arrowDown(.right))
        #expect(hud.seekPreviewPosition == 165)
        #expect(hud.transientBadge == .seek(direction: .forward, seconds: 45))
        hud.handle(.arrowUp(.right))
        try await Task.sleep(for: PlayerTVHUDLayout.seekCommitDebounce + .milliseconds(100))
        #expect(engine.seeks == [165])

        hud.handle(.arrowDown(.up))
        hud.handle(.arrowDown(.up))
        hud.handle(.select)
        #expect(hud.seekPreviewPosition == 90)
        #expect(hud.transientBadge == .seek(direction: .backward, seconds: 30))
        try await Task.sleep(for: PlayerTVHUDLayout.seekCommitDebounce + .milliseconds(100))
        #expect(engine.seeks == [165, 90])
    }

    @Test func swipeOnActionRowMovesSelectionAndNeverScrubs() {
        let engine = ScrubPlaybackEngine()
        let viewModel = PlayerViewModel(engine: engine)
        viewModel.sync()
        let hud = PlayerTVHUDController()
        hud.viewModel = viewModel
        hud.actions = [.panel(.subtitles), .panel(.audio), .panel(.info)]
        hud.syncControlsVisibility(true)
        defer { hud.cleanup(); viewModel.cleanup() }

        hud.handle(.arrowDown(.up))
        #expect(hud.transportFocus == .action(0))

        hud.handle(.panBegan)
        hud.handle(.panChanged(translationX: PlayerTVHUDLayout.actionRowSwipeFirstStep, velocityX: 300))
        #expect(hud.transportFocus == .action(1))
        // Two more steps of travel: one reaches the last button, one clamps.
        let clamped = PlayerTVHUDLayout.actionRowSwipeFirstStep + 2 * PlayerTVHUDLayout.actionRowSwipeStep
        hud.handle(.panChanged(translationX: clamped, velocityX: 300))
        #expect(hud.transportFocus == .action(2))
        #expect(hud.mode == .transport)
        #expect(hud.previewPosition == nil)
        // Travel past the end is not owed back: one step in reverse moves.
        hud.handle(.panChanged(translationX: clamped - PlayerTVHUDLayout.actionRowSwipeStep, velocityX: -300))
        #expect(hud.transportFocus == .action(1))
        hud.handle(.panEnded)
        #expect(engine.seeks.isEmpty)

        // Back on the bar, the same swipe scrubs again.
        hud.handle(.arrowDown(.down))
        #expect(hud.transportFocus == .bar)
        hud.handle(.panBegan)
        #expect(hud.mode == .scrubbing)
        hud.handle(.panEnded)
        hud.handle(.menu)
        #expect(hud.mode == .transport)
    }

    @Test func oneFlickReportedAsPanAndArrowStepsOnce() {
        let engine = ScrubPlaybackEngine()
        let viewModel = PlayerViewModel(engine: engine)
        viewModel.sync()
        let hud = PlayerTVHUDController()
        hud.viewModel = viewModel
        hud.actions = [.panel(.subtitles), .panel(.audio), .panel(.info), .panel(.quality)]
        hud.syncControlsVisibility(true)
        defer { hud.cleanup(); viewModel.cleanup() }

        hud.handle(.arrowDown(.up))

        // Pan first, arrow right after it.
        hud.handle(.panBegan)
        hud.handle(.panChanged(translationX: PlayerTVHUDLayout.actionRowSwipeFirstStep, velocityX: 3000))
        hud.handle(.panEnded)
        hud.handle(.arrowDown(.right))
        hud.handle(.arrowUp(.right))
        #expect(hud.transportFocus == .action(1))

        // Arrow first, pan right after it.
        hud.handle(.arrowDown(.right))
        hud.handle(.arrowUp(.right))
        #expect(hud.transportFocus == .action(2))
        hud.handle(.panBegan)
        hud.handle(.panChanged(translationX: PlayerTVHUDLayout.actionRowSwipeFirstStep, velocityX: 3000))
        hud.handle(.panEnded)
        #expect(hud.transportFocus == .action(2))
    }

    @Test func actionRowSwipeDoesNotTurnIntoAScrubWhenTheHUDHidesUnderIt() {
        let engine = ScrubPlaybackEngine()
        let viewModel = PlayerViewModel(engine: engine)
        viewModel.sync()
        let hud = PlayerTVHUDController()
        hud.viewModel = viewModel
        hud.actions = [.panel(.subtitles), .panel(.audio)]
        hud.syncControlsVisibility(true)
        defer { hud.cleanup(); viewModel.cleanup() }

        hud.handle(.arrowDown(.up))
        hud.handle(.panBegan)
        hud.syncControlsVisibility(false)
        hud.handle(.panChanged(translationX: 2000, velocityX: 300))
        #expect(hud.mode == .hidden)
        #expect(hud.previewPosition == nil)
        hud.handle(.panEnded)

        // From the hidden state the next swipe is a scrub again.
        hud.handle(.panBegan)
        #expect(hud.mode == .scrubbing)
    }
}

@MainActor
private final class ScrubPlaybackEngine: PlaybackEngine {
    var state: PlaybackState = .playing
    let currentTime: TimeInterval = 120
    let duration: TimeInterval = 600
    let isBuffering = false
    let error: PlaybackError? = nil
    let videoEnhancementStatus = VideoEnhancementStatus.disabled
    var onPlaybackEnded: (@MainActor () -> Void)?
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    var seeks: [TimeInterval] = []
    var playPauseCalls = 0
    private let player = AVPlayer()
    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }

    func load(source: PlaybackSource) {}
    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {}
    func play() { playPauseCalls += 1 }
    func pause() { playPauseCalls += 1 }
    func stop() {}
    func seek(to position: TimeInterval) { seeks.append(position) }
    func setPlaybackRate(_ rate: Float) {}
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
#endif
