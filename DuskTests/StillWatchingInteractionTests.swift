import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Dusk

@Suite("Still watching interaction", .serialized)
@MainActor
struct StillWatchingInteractionTests {
    @Test(arguments: [
        "playPause", "seek", "skipForward", "skipBackward", "doubleTap", "beginScrub",
        "updateScrub", "commitScrub", "toggleHUD", "pointerHUD", "controls", "settings",
        "panel", "audio", "subtitles", "subtitlesOff", "marker", "chapter", "speed"
    ])
    func explicitPlaybackActionsResetToZero(action: String) throws {
        let playback = PlaybackCoordinator(plexService: PlexService())
        let engine = InteractionPlaybackEngine()
        let marker = Marker(id: 42, type: "intro", startTimeOffset: 5_000, endTimeOffset: 20_000)
        let model = PlayerViewModel(engine: engine, markers: [marker])
        defer { model.cleanup() }
        model.userInteractionHandler = { playback.noteUserInteraction() }
        model.sync()
        playback.continuousPlayEpisodeRunCount = 3

        switch action {
        case "playPause": model.togglePlayPause()
        case "seek": model.seek(to: 40, revealControls: false)
        case "skipForward": model.handleSeekJump(by: 15)
        case "skipBackward": model.handleSeekJump(by: -15)
        case "doubleTap": model.handleDoubleTapSeek(by: 15)
        case "beginScrub": model.beginScrub()
        case "updateScrub": model.updateScrub(to: 40)
        case "commitScrub":
            model.scrubPosition = 40
            model.commitScrub(shouldPlay: false)
        case "toggleHUD":
            model.showControls = false
            model.toggleControls()
        case "pointerHUD":
            model.showControls = false
            model.touchControls()
        case "controls": model.noteControlsInteraction()
        case "settings": model.noteSettingsMenuInteraction()
        case "panel": model.beginControlsInteractionHold()
        case "audio": model.selectAudio(try audioTrack())
        case "subtitles": model.selectSubtitle(try subtitleTrack())
        case "subtitlesOff": model.selectSubtitle(nil)
        case "marker": model.handleSkipMarker(marker)
        case "chapter": model.seek(to: 60, revealControls: true)
        case "speed": model.setPlaybackRate(1.5)
        default: Issue.record("Unhandled action: \(action)")
        }

        #expect(playback.continuousPlayEpisodeRunCount == 0)
        // The next automatically started item continues counting from zero.
        playback.continuousPlayEpisodeRunCount += 1
        #expect(playback.continuousPlayEpisodeRunCount == 1)
    }

    @Test(arguments: [false, true])
    func trackChangesResetBeforeLocalSelectionOrServerRestart(serverTracks: Bool) throws {
        let playback = PlaybackCoordinator(plexService: PlexService())
        let model = PlayerViewModel(engine: InteractionPlaybackEngine())
        defer { model.cleanup() }
        model.userInteractionHandler = { playback.noteUserInteraction() }
        model.usesServerTrackSelection = serverTracks
        model.plexTrackSelectionHandler = { _, _ in
            #expect(playback.continuousPlayEpisodeRunCount == 0)
        }
        playback.continuousPlayEpisodeRunCount = 3
        model.selectAudio(try audioTrack())
        #expect(playback.continuousPlayEpisodeRunCount == 0)
        playback.continuousPlayEpisodeRunCount = 3
        model.selectSubtitle(try subtitleTrack())
        #expect(playback.continuousPlayEpisodeRunCount == 0)

        model.usesServerTrackSelection = false
        var external = try subtitleTrack()
        external.requiresEngineSwitch = true
        var restarted = false
        model.externalSubtitleRestartHandler = { _ in
            restarted = true
            #expect(playback.continuousPlayEpisodeRunCount == 0)
        }
        playback.continuousPlayEpisodeRunCount = 3
        model.selectSubtitle(external)
        #expect(restarted)
    }

    @Test func automaticSeeksTrackSelectionAndStateUpdatesDoNotReset() {
        let playback = PlaybackCoordinator(plexService: PlexService())
        let engine = InteractionPlaybackEngine()
        let marker = Marker(id: 42, type: "intro", startTimeOffset: 5_000, endTimeOffset: 20_000)
        let model = PlayerViewModel(engine: engine, markers: [marker])
        defer { model.cleanup() }
        model.userInteractionHandler = { playback.noteUserInteraction() }
        playback.continuousPlayEpisodeRunCount = 3
        model.configureAutomaticTrackSelection(preferences: playback.preferences, part: nil)
        model.sync()
        model.showControls = false
        engine.state = .paused
        model.sync() // An interruption reveals controls without viewer input.
        #expect(model.showControls)
        #expect(playback.continuousPlayEpisodeRunCount == 3)
        model.handleSkipMarker(marker, userInitiated: false)
        #expect(engine.currentTime == 20.5)
        #expect(playback.continuousPlayEpisodeRunCount == 3)
        model.cleanup()
        #expect(playback.continuousPlayEpisodeRunCount == 3)
    }

    @Test func resetKeepsThresholdCountdownAndDisabledSettings() throws {
        let preferences = UserPreferences()
        let previousEnabled = preferences.continuousPlayEnabled
        let previousLimit = preferences.continuousPlayPassoutProtectionEpisodeLimit
        defer {
            preferences.continuousPlayEnabled = previousEnabled
            preferences.continuousPlayPassoutProtectionEpisodeLimit = previousLimit
        }
        preferences.continuousPlayEnabled = true
        preferences.continuousPlayPassoutProtectionEpisodeLimit = 3
        let playback = PlaybackCoordinator(plexService: PlexService(), preferences: preferences)
        defer { playback.cancelUpNextCountdown() }
        let candidate = UpNextCandidate(item: PlaybackQueueItem(
            id: MediaItemID(serverID: "interaction-test", ratingKey: "2"), type: .episode, title: "Next"
        ), queueIndex: nil)
        playback.continuousPlayEpisodeRunCount = 3
        playback.presentUpNext(for: candidate)
        #expect(playback.upNextPresentation?.autoplayBlockedByPassoutProtection == true)
        playback.noteUserInteraction()
        #expect(playback.continuousPlayEpisodeRunCount == 0)
        playback.presentUpNext(for: candidate)
        let countdown = try #require(playback.upNextPresentation)
        #expect(countdown.shouldAutoplay)
        #expect(countdown.countdownDuration == preferences.continuousPlayCountdown.rawValue)
        playback.noteUserInteraction()
        #expect(playback.upNextPresentation?.countdownStartedAt == countdown.countdownStartedAt)
        #expect(playback.upNextPresentation?.secondsRemaining == countdown.secondsRemaining)
        #expect(preferences.continuousPlayPassoutProtectionEpisodeLimit == 3)
        playback.continuousPlayEpisodeRunCount = 2
        playback.presentUpNext(for: candidate)
        #expect(playback.upNextPresentation?.shouldAutoplay == true)
        playback.continuousPlayEpisodeRunCount += 1
        playback.presentUpNext(for: candidate)
        #expect(playback.upNextPresentation?.autoplayBlockedByPassoutProtection == true)
        preferences.continuousPlayEnabled = false
        playback.noteUserInteraction()
        playback.presentUpNext(for: candidate)
        #expect(playback.upNextPresentation?.shouldAutoplay == false)
    }

    #if os(tvOS)
    @Test func remoteHUDPanelAndScrubInputResetButVisibilitySyncDoesNot() {
        let playback = PlaybackCoordinator(plexService: PlexService())
        let model = PlayerViewModel(engine: InteractionPlaybackEngine())
        defer { model.cleanup() }
        model.userInteractionHandler = { playback.noteUserInteraction() }
        let hud = PlayerTVHUDController()
        hud.viewModel = model
        hud.availablePanelTabs = [.info, .audio]
        playback.continuousPlayEpisodeRunCount = 3
        hud.syncControlsVisibility(true)
        #expect(playback.continuousPlayEpisodeRunCount == 3)
        hud.syncControlsVisibility(false)
        hud.handle(.touchTap)
        #expect(playback.continuousPlayEpisodeRunCount == 0)
        playback.continuousPlayEpisodeRunCount = 3
        hud.openPanel(.audio)
        #expect(playback.continuousPlayEpisodeRunCount == 0)
        hud.closePanel()
        playback.continuousPlayEpisodeRunCount = 3
        hud.handle(.panBegan)
        #expect(playback.continuousPlayEpisodeRunCount == 0)
        hud.handle(.menu)
    }
    #endif

    private func audioTrack() throws -> AudioTrack {
        AudioTrack(stream: try JSONDecoder().decode(MediaStream.self, from: Data(
            #"{"id":11,"streamType":2,"codec":"aac","language":"English","languageCode":"eng"}"#.utf8
        )))
    }

    private func subtitleTrack() throws -> SubtitleTrack {
        SubtitleTrack(stream: try JSONDecoder().decode(MediaStream.self, from: Data(
            #"{"id":12,"streamType":3,"codec":"srt","language":"English","languageCode":"eng"}"#.utf8
        )))
    }
}

@MainActor
private final class InteractionPlaybackEngine: PlaybackEngine {
    var state: PlaybackState = .playing
    var currentTime: TimeInterval = 10
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
    func load(source: PlaybackSource) {}
    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {}
    func play() { state = .playing }
    func pause() { state = .paused }
    func stop() { state = .stopped }
    func seek(to position: TimeInterval) { currentTime = position }
    func setPlaybackRate(_ rate: Float) {}
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
