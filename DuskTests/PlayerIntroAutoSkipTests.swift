import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Dusk

@Suite("Intro auto-skip configuration", .serialized)
@MainActor
struct PlayerIntroAutoSkipTests {
    @Test func startupSyncDoesNotArmDefaultModeBeforeOffPreferenceIsApplied() {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .off
        defer { preferences.autoSkipIntroMode = previousMode }

        let marker = PlexMarker(
            id: 42,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { viewModel.cleanup() }

        // The first timer sync can run before PlayerSessionView applies the
        // saved settings. It must not use PlayerViewModel's default mode.
        viewModel.sync()
        #expect(viewModel.autoSkipCountdownMarkerID == nil)

        viewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil
        )
        #expect(viewModel.autoSkipIntroMode == .off)
        // Off still arms the countdown. Expiry hides the chip; it does not skip.
        #expect(viewModel.autoSkipCountdownMarkerID == marker.id)

        preferences.autoSkipIntroMode = .always
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        #expect(viewModel.autoSkipCountdownMarkerID == marker.id)

        preferences.autoSkipIntroMode = .off
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        #expect(viewModel.autoSkipCountdownMarkerID == marker.id)
    }

    @Test func countdownExpiryWithAutoSkipOffHidesChipWithoutSkipping() async throws {
        let harness = makeHarness(mode: .off)
        defer { harness.restore() }

        #expect(harness.viewModel.autoSkipCountdownMarkerID == harness.marker.id)

        try await waitForCountdown()
        harness.viewModel.sync()

        #expect(harness.handlerCalls() == 0)
        #expect(harness.engine.seekTargets.isEmpty)
        #expect(harness.viewModel.activeSkipMarker == nil)
        #expect(harness.viewModel.countdownDismissedMarkerID == harness.marker.id)
        #expect(harness.engine.currentTime == 10)

        // Leaving the marker clears the dismissal; seeking back shows the chip.
        harness.engine.currentTime = 30
        harness.viewModel.sync()
        #expect(harness.viewModel.countdownDismissedMarkerID == nil)
        #expect(harness.viewModel.activeSkipMarker == nil)

        harness.engine.currentTime = 10
        harness.viewModel.sync()
        #expect(harness.viewModel.activeSkipMarker?.id == harness.marker.id)
        #expect(harness.viewModel.autoSkipCountdownMarkerID == harness.marker.id)
    }

    @Test func countdownExpiryOnFirstEpisodeDoesNotSkipWhenModeExcludesIt() async throws {
        let harness = makeHarness(mode: .alwaysExceptFirstEpisode, isFirstEpisodeInSeason: true)
        defer { harness.restore() }

        try await waitForCountdown()
        harness.viewModel.sync()

        #expect(harness.handlerCalls() == 0)
        #expect(harness.engine.seekTargets.isEmpty)
        #expect(harness.viewModel.activeSkipMarker == nil)
        #expect(harness.viewModel.countdownDismissedMarkerID == harness.marker.id)
    }

    @Test func countdownExpiryWithAutoSkipOnStillSkips() async throws {
        let harness = makeHarness(mode: .always, skipOnHandler: true)
        defer { harness.restore() }

        try await waitForCountdown()
        harness.viewModel.sync()

        #expect(harness.handlerCalls() == 1)
        #expect(harness.engine.seekTargets == [20.5])
        #expect(harness.viewModel.countdownDismissedMarkerID == nil)
        #expect(harness.viewModel.activeSkipMarker == nil)
        #expect(harness.viewModel.spentAutoSkipMarkerIDs.contains(harness.marker.id))
    }

    private func waitForCountdown() async throws {
        try await Task.sleep(for: .milliseconds(1_000))
    }

    private func makeHarness(
        mode: AutoSkipIntroMode,
        isFirstEpisodeInSeason: Bool = false,
        skipOnHandler: Bool = false
    ) -> IntroAutoSkipHarness {
        let previousDuration = PlayerViewModel.autoSkipCountdownDuration
        PlayerViewModel.autoSkipCountdownDuration = 0.05

        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = mode

        let marker = PlexMarker(
            id: 42,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        var handlerCalls = 0
        let harness = IntroAutoSkipHarness(
            preferences: preferences,
            previousMode: previousMode,
            previousDuration: previousDuration,
            marker: marker,
            engine: engine,
            viewModel: viewModel,
            handlerCalls: { handlerCalls }
        )
        viewModel.autoSkipHandler = { [weak viewModel] _ in
            handlerCalls += 1
            if skipOnHandler {
                viewModel?.skipActiveMarker()
            }
        }
        // `activeSkipMarker` reads the view model's clock, which sync copies
        // off the engine. Configure then arms the countdown for that marker.
        viewModel.sync()
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        viewModel.isFirstEpisodeInSeason = isFirstEpisodeInSeason
        return harness
    }
}

@MainActor
private struct IntroAutoSkipHarness {
    let preferences: UserPreferences
    let previousMode: AutoSkipIntroMode
    let previousDuration: TimeInterval
    let marker: PlexMarker
    let engine: IntroAutoSkipPlaybackEngine
    let viewModel: PlayerViewModel
    let handlerCalls: () -> Int

    func restore() {
        viewModel.cleanup()
        preferences.autoSkipIntroMode = previousMode
        PlayerViewModel.autoSkipCountdownDuration = previousDuration
    }
}

@MainActor
private final class IntroAutoSkipPlaybackEngine: PlaybackEngine {
    let state: PlaybackState = .playing
    var currentTime: TimeInterval
    private(set) var seekTargets: [TimeInterval] = []
    let duration: TimeInterval = 120
    let isBuffering = false
    let error: PlaybackError? = nil
    let videoEnhancementStatus = VideoEnhancementStatus.disabled
    var onPlaybackEnded: (@MainActor () -> Void)?
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    private let player = AVPlayer()

    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }

    init(currentTime: TimeInterval) {
        self.currentTime = currentTime
    }

    func load(source: PlaybackSource) {}
    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {}
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to position: TimeInterval) {
        seekTargets.append(position)
        currentTime = position
    }
    func setPlaybackRate(_ rate: Float) {}
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
