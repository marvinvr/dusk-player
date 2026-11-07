import AVFoundation
import Foundation
import MediaPlayer
import SwiftUI
import Testing
@testable import Dusk

// The system info/command centers are process-wide. Always tear the session
// down, including when an expectation fails, so targets cannot leak to a test.
@Suite("System Now Playing", .serialized)
@MainActor
struct PlaybackNowPlayingTests {
    @Test func episodeMetadataIncludesVideoIdentityAndHierarchy() throws {
        let controller = PlaybackNowPlayingController()
        let engine = NowPlayingEngine()
        defer { controller.endSession() }
        try begin(controller, engine: engine, episode: true)

        let info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Example Show S2E3: Episode Title")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Example Show")
        #expect(info[MPMediaItemPropertyDiscNumber] as? Int == 2)
        #expect(info[MPMediaItemPropertyAlbumTrackNumber] as? Int == 3)
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 120)
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(MPNowPlayingInfoCenter.default().playbackState == .playing)

        let commands = MPRemoteCommandCenter.shared()
        #expect(commands.playCommand.isEnabled)
        #expect(commands.pauseCommand.isEnabled)
        #expect(commands.togglePlayPauseCommand.isEnabled)
        #expect(commands.skipForwardCommand.isEnabled)
        #expect(commands.skipBackwardCommand.isEnabled)
        #expect(commands.seekForwardCommand.isEnabled)
        #expect(commands.seekBackwardCommand.isEnabled)
        #expect(commands.changePlaybackPositionCommand.isEnabled)
        #expect(commands.skipForwardCommand.preferredIntervals == [30])
        #expect(commands.skipBackwardCommand.preferredIntervals == [10])
    }

    @Test func remoteTransportSmallSeeksAndSpeedChangesUpdateTheClock() throws {
        let controller = PlaybackNowPlayingController()
        let engine = NowPlayingEngine()
        defer { controller.endSession() }
        try begin(controller, engine: engine)

        #expect(controller.handleRemoteAction(.pause) == .success)
        #expect(engine.state == .paused)
        #expect(MPNowPlayingInfoCenter.default().playbackState == .paused)
        #expect(infoDouble(MPNowPlayingInfoPropertyPlaybackRate) == 0)
        #expect(controller.handleRemoteAction(.seek(42)) == .success)
        #expect(engine.currentTime == 42)
        #expect(infoDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime) == 42)
        #expect(engine.state == .paused)

        #expect(controller.handleRemoteAction(.play) == .success)
        engine.setPlaybackRate(2)
        sync(controller, engine: engine)
        #expect(infoDouble(MPNowPlayingInfoPropertyPlaybackRate) == 2)
        // A seek smaller than the old eight-second publication threshold must
        // still replace the system's extrapolated position immediately.
        engine.currentTime = 44
        sync(controller, engine: engine)
        #expect(infoDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime) == 44)
        #expect(controller.handleRemoteAction(.togglePlayPause) == .success)
        #expect(engine.state == .paused)
        #expect(infoDouble(MPNowPlayingInfoPropertyPlaybackRate) == 0)
    }

    @Test func skipAndContinuousSeekPreservePauseAndClampToLiveWindow() {
        let controller = PlaybackNowPlayingController()
        let engine = NowPlayingEngine()
        engine.state = .paused
        engine.seekableTimeRange = 30...90
        let plex = PlexService()
        defer { controller.endSession() }
        controller.beginLiveSession(
            title: "Program", channelTitle: "Channel", artworkPath: nil,
            serverID: nil, engine: engine, plexService: plex,
            skipBackwardInterval: 10, skipForwardInterval: 30
        )

        #expect(controller.handleRemoteAction(.skip(-50)) == .success)
        #expect(engine.currentTime == 30)
        #expect(controller.handleRemoteAction(.seek(200)) == .success)
        #expect(engine.currentTime == 90)
        #expect(controller.handleRemoteAction(.beginSeeking(forward: false)) == .success)
        #expect(engine.currentTime == 80)
        #expect(controller.handleRemoteAction(.endSeeking) == .success)
        #expect(engine.state == .paused)
        #expect(controller.handleRemoteAction(.seek(.nan)) == .commandFailed)
        #expect(controller.handleRemoteAction(.skip(.infinity)) == .commandFailed)

        controller.updateLiveProgramTitle("Next Program")
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Next Program")
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
    }

    @Test func replacementItemDropsOldHierarchyAndStopRemovesMetadataAndCommands() throws {
        let controller = PlaybackNowPlayingController()
        let engine = NowPlayingEngine()
        defer { controller.endSession() }
        try begin(controller, engine: engine, episode: true)
        // Up Next and engine/track replacement all enter through beginSession.
        let nextEngine = NowPlayingEngine()
        try begin(controller, engine: nextEngine)
        let info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Movie Title")
        #expect(info[MPMediaItemPropertyDiscNumber] == nil)
        #expect(info[MPMediaItemPropertyAlbumTrackNumber] == nil)
        #expect(info[MPMediaItemPropertyArtwork] == nil)

        nextEngine.stop()
        sync(controller, engine: nextEngine)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
        #expect(MPNowPlayingInfoCenter.default().playbackState == .stopped)
        #expect(!MPRemoteCommandCenter.shared().playCommand.isEnabled)
        controller.endSession()
        #expect(controller.handleRemoteAction(.play) == .noSuchContent)
        #expect(!MPRemoteCommandCenter.shared().playCommand.isEnabled)
        #expect(!MPRemoteCommandCenter.shared().seekForwardCommand.isEnabled)
        #expect(!MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled)
        sync(controller, engine: nextEngine)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    }

    @Test func reusedStoppedEngineKeepsInitialMetadataUntilItLoads() throws {
        let controller = PlaybackNowPlayingController()
        let engine = NowPlayingEngine()
        engine.state = .stopped
        defer { controller.endSession() }
        try begin(controller, engine: engine)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Movie Title")
        engine.state = .loading
        sync(controller, engine: engine)
        #expect(MPNowPlayingInfoCenter.default().playbackState == .interrupted)
        engine.play()
        sync(controller, engine: engine)
        #expect(MPNowPlayingInfoCenter.default().playbackState == .playing)

        let unusedController = PlaybackNowPlayingController()
        unusedController.endSession()
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo != nil)
    }

    private func begin(
        _ controller: PlaybackNowPlayingController,
        engine: NowPlayingEngine,
        episode: Bool = false
    ) throws {
        let json = episode
            ? #"{"ratingKey":"1","key":"/library/metadata/1","type":"episode","title":"Episode Title","grandparentTitle":"Example Show","parentIndex":2,"index":3,"duration":120000}"#
            : #"{"ratingKey":"2","key":"/library/metadata/2","type":"movie","title":"Movie Title","year":2026,"duration":120000}"#
        let details = try JSONDecoder().decode(PlexMediaDetails.self, from: Data(json.utf8))
        controller.beginSession(
            details: details, engine: engine, plexService: PlexService(),
            skipBackwardInterval: 10, skipForwardInterval: 30
        )
    }

    private func sync(_ controller: PlaybackNowPlayingController, engine: NowPlayingEngine) {
        controller.updatePlaybackState(state: engine.state, currentTime: engine.currentTime, duration: engine.duration)
    }

    private func infoDouble(_ key: String) -> Double? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[key] as? Double
    }
}

@MainActor
private final class NowPlayingEngine: PlaybackEngine {
    var state: PlaybackState = .playing
    var currentTime: TimeInterval = 40
    var duration: TimeInterval = 120
    var seekableTimeRange: ClosedRange<TimeInterval>?
    private var rate: Float = 1
    var playbackRate: Float { state == .playing ? rate : 0 }
    let isBuffering = false
    let error: PlaybackError? = nil
    let videoEnhancementStatus = VideoEnhancementStatus.disabled
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    var onPlaybackEnded: (@MainActor () -> Void)?
    private let player = AVPlayer()
    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }

    func load(source: PlaybackSource) { state = .loading }
    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {}
    func play() { state = .playing }
    func pause() { state = .paused }
    func stop() { state = .stopped }
    func seek(to position: TimeInterval) { currentTime = position }
    func setPlaybackRate(_ rate: Float) { self.rate = rate }
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
