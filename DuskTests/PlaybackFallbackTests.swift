import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Dusk

@Suite("Automatic playback recovery presentation")
@MainActor
struct PlaybackFallbackTests {
    @Test func explicitSubtitleOffWaitsForTheLoadedEngine() {
        let engine = FailedPlaybackEngine(state: .idle)
        let model = PlayerViewModel(engine: engine, markers: [])
        defer { model.cleanup() }
        var rememberedChoices = 0
        model.userTrackSelectionHandler = { _, _ in rememberedChoices += 1 }
        model.hasConfiguredAutomaticTrackSelection = true
        model.explicitTrackSelection = ExplicitTrackSelection(audioStreamID: nil, subtitleStreamID: nil)
        model.applyAutomaticTrackSelectionIfNeeded()
        #expect(!model.hasAppliedAutomaticSubtitleSelection)
        #expect(engine.subtitleSelectionCount == 0)

        engine.state = .playing
        model.applyAutomaticTrackSelectionIfNeeded()
        #expect(model.hasAppliedAutomaticSubtitleSelection)
        #expect(engine.subtitleSelectionCount == 1)
        model.applyAutomaticTrackSelectionIfNeeded()
        #expect(engine.subtitleSelectionCount == 1)
        #expect(rememberedChoices == 0) // Automatic application never saves a preference.

        model.selectSubtitle(nil) // Off is already selected; the gesture still saves it.
        #expect(rememberedChoices == 1)
    }

    @Test(arguments: [
        #""DOVIPresent":true,"DOVIProfile":5,"DOVIBLCompatID":0,"bitDepth":10"#,
        #""DOVIPresent":true,"DOVIProfile":8,"DOVIBLCompatID":1"#,
        #""colorTrc":"smpte2084""#,
        #""colorTrc":"arib-std-b67""#,
    ])
    func declinedHDRTrackChangesKeepTheLoadedRemux(videoFields: String) async throws {
        let playback = PlaybackCoordinator(plexService: PlexService())
        let details = try JSONDecoder().decode(PlexMediaDetails.self, from: Data("""
            {"ratingKey":"1","key":"/library/metadata/1","type":"movie","title":"HDR",
             "Media":[{"id":1,"container":"mkv","Part":[{"id":2,"key":"/clip.mkv","Stream":[
               {"id":3,"streamType":1,"codec":"hevc",\(videoFields)}
             ]}]}]}
            """.utf8))
        let media = try #require(details.media.first)
        let url = try #require(URL(string: "https://example.invalid/remux.m3u8"))
        let engine = FailedPlaybackEngine(state: .playing)
        let attemptID = UUID()
        playback.engine = engine
        playback.ratingKey = "1"
        playback.activeItemDetails = details
        playback.activeTranscodeSessionID = "working-remux"
        playback.remuxTrackSelection = ExplicitTrackSelection(audioStreamID: 4, subtitleStreamID: nil)
        playback.debugInfo = PlaybackDebugInfo(
            title: "HDR", engine: .avPlayer, decision: .spatialAudio,
            media: media, part: media.parts[0], attemptID: attemptID,
            resolverReason: "HDR remux", sanitizedPlaybackURL: url.absoluteString
        )
        playback.playbackSource = PlaybackSource(
            url: url, startPosition: 42,
            context: PlaybackAttemptContext(
                attemptID: attemptID, title: "HDR", ratingKey: "1", engine: .avPlayer,
                resolverReason: "HDR remux", mediaID: 1, partID: 2,
                sanitizedPlaybackURL: url.absoluteString
            )
        )
        let presentationID = playback.playerPresentationID
        // Exercise repeated refused On/Off changes without opening media or
        // contacting Plex. The loaded session and its confirmed tracks win.
        for subtitleID: Int? in [5, nil, 5, nil] {
            playback.activeAudioStreamID = 6
            playback.activeSubtitleStreamID = subtitleID
            await playback.leaveSpatialAudioRemux(reason: "declined", keepsExplicitTracks: true)
            #expect(playback.engine === engine)
            #expect(playback.playerPresentationID == presentationID)
            #expect(playback.playbackSource?.url == url)
            #expect(playback.activeTranscodeSessionID == "working-remux")
            #expect(playback.activeAudioStreamID == 4)
            #expect(playback.activeSubtitleStreamID == nil)
            #expect(playback.qualitySwitchError != nil)
        }
    }

    @Test func remuxErrorsStayLoadingUntilRecoveryIsExhausted() {
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.showPlayer = true
        playback.engine = FailedPlaybackEngine()
        playback.startDirectPlayFallbackWatch()
        defer { playback.cancelDirectPlayFallbackWatch() }

        // Remuxes arm this watch too; no direct-play-only presentation gate.
        #expect(playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .recovering)
        playback.isAutomaticDirectPlayFallbackAvailable = false
        playback.isAutomaticDirectPlayFallbackActive = true
        #expect(playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .recovering)
        playback.cancelDirectPlayFallbackWatch()
        #expect(!playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .hidden)
    }

    @Test func exhaustedFallbackRevealsTerminalError() async {
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.showPlayer = true
        playback.engine = FailedPlaybackEngine()
        playback.isAutomaticDirectPlayFallbackAvailable = true
        playback.isAutomaticDirectPlayFallbackActive = true
        // No active item means no replacement can be prepared.
        await playback.performDirectPlayServerStreamFallback()
        #expect(!playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .hidden)
    }

    @Test func dv7RetryKeepsTheReplacementFallbackArmed() async throws {
        let playback = PlaybackCoordinator(plexService: PlexService())
        let media = try JSONDecoder().decode(PlexMedia.self, from: Data(#"""
            {"id":1,"container":"mkv","Part":[{"id":2,"key":"/clip.mkv","Stream":[
              {"id":3,"streamType":1,"codec":"hevc","DOVIProfile":7,"DOVILevel":6,"DOVIBLCompatID":6}
            ]}]}
            """#.utf8))
        let url = try #require(URL(string: "https://example.invalid/clip.m3u8"))
        let conversion = try #require(StreamResolver.dolbyVision7ConversionTarget(in: media))
        let attemptID = UUID()
        playback.showPlayer = true
        playback.engine = FailedPlaybackEngine()
        playback.debugInfo = PlaybackDebugInfo(
            title: "DV7", engine: .avPlayer, decision: .spatialAudio,
            media: media, part: media.parts[0], attemptID: attemptID,
            resolverReason: "DV7 remux", sanitizedPlaybackURL: url.absoluteString
        )
        playback.playbackSource = PlaybackSource(
            url: url, startPosition: nil,
            context: PlaybackAttemptContext(
                attemptID: attemptID, title: "DV7", ratingKey: "1",
                engine: .avPlayer, resolverReason: "DV7 remux", mediaID: 1,
                partID: 2, sanitizedPlaybackURL: url.absoluteString
            ),
            dolbyVision7Conversion: conversion
        )
        playback.isAutomaticDirectPlayFallbackAvailable = true
        playback.isAutomaticDirectPlayFallbackActive = true

        // A queued track rebuild replaces the failed engine while the DV7
        // retry waits for it. Exercise the real retry/cleanup across that await
        // without loading media or contacting Plex.
        playback.spatialAudioTransitionTask = Task { @MainActor in
            playback.engine = FailedPlaybackEngine()
            playback.playerPresentationID = UUID()
            playback.startDirectPlayFallbackWatch()
        }
        defer { playback.cancelDirectPlayFallbackWatch() }
        await playback.performDirectPlayServerStreamFallback()
        #expect(playback.isDolbyVision7ConversionSuppressed)
        #expect(playback.isAutomaticDirectPlayFallbackAvailable)
        #expect(playback.isAutomaticDirectPlayFallbackPending)
        #expect(playback.playerLoadingState == .recovering)
    }

    /// A coordinator on a failed HDR remux, with a server, so plain direct play
    /// is genuinely available and only the policy can keep it away.
    private func failedHDRRemux() throws -> (PlaybackCoordinator, FailedPlaybackEngine) {
        let service = PlexService(urlProtocolClasses: [SubtitleDecisionProtocol.self])
        let server = try JSONDecoder().decode(PlexServer.self, from: Data(#"{"name":"Test","clientIdentifier":"hdr-server","connections":[]}"#.utf8))
        service.pool.adopt(server: server, baseURL: URL(string: "https://plex.invalid")!, token: "test", connection: nil)
        let playback = PlaybackCoordinator(plexService: service)
        let details = try JSONDecoder().decode(PlexMediaDetails.self, from: Data(#"""
            {"ratingKey":"1","key":"/library/metadata/1","type":"movie","title":"HDR",
             "Media":[{"id":1,"container":"mkv","videoCodec":"hevc","Part":[{"id":2,"key":"/clip.mkv","Stream":[
               {"id":3,"streamType":1,"codec":"hevc","bitDepth":10,"colorTrc":"smpte2084"}
             ]}]}]}
            """#.utf8))
        let media = try #require(details.media.first)
        let engine = FailedPlaybackEngine()
        playback.showPlayer = true
        playback.engine = engine
        playback.ratingKey = "1"
        playback.activeItemDetails = details
        playback.activePlaybackServerID = "hdr-server"
        playback.debugInfo = PlaybackDebugInfo(
            title: "HDR", engine: .avPlayer, decision: .spatialAudio,
            media: media, part: media.parts[0], attemptID: UUID(),
            resolverReason: "HDR remux", sanitizedPlaybackURL: "https://plex.invalid/remux.m3u8"
        )
        return (playback, engine)
    }

    // Attempts 0: Plex declines the fresh remux. 3: recovery is exhausted.
    @Test(arguments: [0, 3])
    func liveHDRRemuxFailureNeverLeavesForDirectPlay(attempts: Int) async throws {
        let (playback, engine) = try failedHDRRemux()
        defer { playback.cancelDirectPlayFallbackWatch() }
        playback.didRemuxReachPlayback = true
        playback.liveRemuxRecoveryAttempts = attempts
        await playback.performDirectPlayServerStreamFallback()
        #expect(playback.engine === engine)
        #expect(playback.debugInfo?.decision.isSpatialAudio == true)
        // The error overlay carries it; a "tracks" toast would be nonsense.
        #expect(playback.qualitySwitchError == nil)
        #expect(!playback.isAutomaticDirectPlayFallbackPending)
    }

    @Test func hdrRemuxThatNeverPlayedStillFallsBackToDirectPlay() async throws {
        let (playback, engine) = try failedHDRRemux()
        defer { playback.engine?.stop(); playback.cancelDirectPlayFallbackWatch() }
        await playback.performDirectPlayServerStreamFallback()
        #expect(playback.engine !== engine)
        #expect(playback.debugInfo?.decision.isDirectPlay == true)
    }

    @Test func aPausedSessionNeverRunsStallRecovery() {
        let engine = FailedPlaybackEngine(state: .paused)
        engine.currentTime = 42
        engine.isBuffering = true
        let model = PlayerViewModel(engine: engine, markers: [])
        defer { model.cleanup() }
        model.sync()

        model.stalledPlaybackStartedAt = Date().addingTimeInterval(-60)
        model.sync()
        #expect(engine.stallRecoveryCount == 0)
        // A long pause does not count towards a stall right after resuming.
        #expect(model.stalledPlaybackStartedAt == nil)

        engine.state = .playing
        model.sync()
        #expect(engine.stallRecoveryCount == 0)
        model.stalledPlaybackStartedAt = Date().addingTimeInterval(-60)
        model.sync()
        #expect(engine.stallRecoveryCount == 1)
    }
}

@Suite("Plex server subtitle delivery", .serialized)
@MainActor
struct PlexServerSubtitleTests {
    private func playback(refuses: Bool = false) throws -> PlaybackCoordinator {
        let service = PlexService(urlProtocolClasses: [SubtitleDecisionProtocol.self])
        let server = try JSONDecoder().decode(PlexServer.self, from: Data(#"{"name":"Test","clientIdentifier":"subtitle-server","connections":[]}"#.utf8))
        service.pool.adopt(server: server, baseURL: URL(string: refuses ? "https://refuse.plex.invalid" : "https://plex.invalid")!, token: "test", connection: nil)
        let playback = PlaybackCoordinator(plexService: service)
        let details = try JSONDecoder().decode(PlexMediaDetails.self, from: Data(#"""
            {"ratingKey":"1","key":"/library/metadata/1","type":"episode","title":"PGS",
             "Media":[{"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"dca",
               "width":1920,"height":1080,"bitrate":30000,"Part":[{"id":2,"key":"/clip.mkv","Stream":[
                 {"id":3,"streamType":1,"codec":"hevc","bitDepth":8,"colorTrc":"bt709"},
                 {"id":4,"streamType":2,"codec":"dca","channels":6,"languageCode":"eng"},
                 {"id":5,"streamType":3,"codec":"pgs","languageCode":"eng","forced":true,"default":true},
                 {"id":6,"streamType":3,"codec":"pgs","languageCode":"eng"}
               ]}]}]}
            """#.utf8))
        let media = try #require(details.media.first)
        playback.activeItemDetails = details
        playback.ratingKey = "1"
        playback.activePlaybackServerID = "subtitle-server"
        playback.activeAudioStreamID = 4
        playback.activeSubtitleStreamID = 5
        playback.engine = FailedPlaybackEngine(state: .paused)
        playback.debugInfo = PlaybackDebugInfo(
            title: "PGS", engine: .vlcKit, decision: .directPlay, media: media, part: media.parts[0],
            attemptID: UUID(), resolverReason: "MKV/DTS/PGS", sanitizedPlaybackURL: "https://plex.invalid/clip.mkv"
        )
        return playback
    }

    private func query(_ playback: PlaybackCoordinator) throws -> [String: String] {
        let url = try #require(playback.playbackSource?.url)
        return Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map {
            ($0.name, $0.value ?? "")
        })
    }

    @Test func mkvHEVCDTSAndPGSStayOnVLCKitForDirectPlay() throws {
        let playback = try playback()
        let info = try #require(playback.debugInfo)
        #expect(StreamResolver.evaluate(media: info.media).engine == .vlcKit)
        #expect(!playback.usesServerTrackSelection)
    }

    @Test func qualitySwitchCarriesThePGSBurnAndAudioSelection() async throws {
        let playback = try playback()
        defer { playback.engine?.stop(); playback.cancelDirectPlayFallbackWatch() }
        await playback.switchQuality(to: .p720_4Mbps)
        let query = try query(playback)
        #expect(query["audioStreamID"] == "4")
        #expect(query["subtitleStreamID"] == "5")
        #expect(query["subtitles"] == "burn")
        #expect(playback.usesServerTrackSelection)
        #expect(playback.debugInfo?.qualityPreset == .p720_4Mbps)
        #expect(playback.playbackSource?.shouldAutoPlay == false)
    }

    @Test(arguments: [false, true])
    func serverPGSPickerRebuildsOnOffOnAndKeepsQuality(manualQuality: Bool) async throws {
        let playback = try playback()
        defer { playback.engine?.stop(); playback.cancelDirectPlayFallbackWatch() }
        if manualQuality {
            await playback.switchQuality(to: .p720_4Mbps)
        } else {
            playback.engine = FailedPlaybackEngine()
            await playback.performDirectPlayServerStreamFallback()
        }
        #expect(try query(playback)["subtitleStreamID"] == "5")
        #expect(playback.usesServerTrackSelection)
        let preferences = UserPreferences()
        let model = PlayerViewModel(engine: playback.engine!)
        defer { model.cleanup() }
        for subtitleID: Int? in [6, nil, 5] {
            model.configureAutomaticTrackSelection(
                preferences: preferences, part: playback.debugInfo?.part,
                usesServerTrackSelection: playback.usesServerTrackSelection,
                selectedAudioStreamID: playback.activeAudioStreamID,
                selectedSubtitleStreamID: playback.activeSubtitleStreamID
            )
            #expect(model.subtitleTracks.count == 2) // Original PGS tracks, absent from HLS.
            model.plexTrackSelectionHandler = { audio, subtitle in
                playback.selectPlexStreamsForPlayback(audioStreamID: audio, subtitleStreamID: subtitle)
            }
            let pausedEngine = FailedPlaybackEngine(state: .paused)
            pausedEngine.currentTime = 12
            playback.engine = pausedEngine
            model.selectSubtitle(subtitleID.flatMap { id in model.subtitleTracks.first { $0.id == id } })
            await playback.spatialAudioTransitionTask?.value
            let query = try query(playback)
            #expect(query["subtitleStreamID"] == subtitleID.map(String.init))
            #expect(query["subtitles"] == (subtitleID == nil ? "none" : "burn"))
            #expect(query["audioStreamID"] == "4")
            #expect(playback.playbackSource?.shouldAutoPlay == false)
            #expect(playback.playbackSource?.startPosition == 12)
            #expect(playback.debugInfo?.qualityPreset == (manualQuality ? .p720_4Mbps : .original))
        }
    }

    @Test func refusedTrackChangeKeepsTheLoadedStreamAndConfirmedSelection() async throws {
        let playback = try playback(refuses: true)
        let engine = playback.engine
        playback.remuxTrackSelection = ExplicitTrackSelection(audioStreamID: 4, subtitleStreamID: 5)
        playback.activeSubtitleStreamID = 6
        await playback.rebuildServerStreamSession(reason: "refused selection")
        #expect(playback.engine === engine)
        #expect(playback.activeSubtitleStreamID == 5)
        #expect(playback.activeAudioStreamID == 4)
        #expect(playback.qualitySwitchError != nil)
    }
}

private final class SubtitleDecisionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let code = request.url?.host == "refuse.plex.invalid" ? 2000 : 1001
        client?.urlProtocol(self, didLoad: Data("{\"MediaContainer\":{\"generalDecisionCode\":\(code)}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class FailedPlaybackEngine: PlaybackEngine {
    var state: PlaybackState
    var subtitleSelectionCount = 0
    var error: PlaybackError? { state == .error ? .unknown("The decoder failed.") : nil }
    init(state: PlaybackState = .error) { self.state = state }
    var currentTime: TimeInterval = 0
    let duration: TimeInterval = 0
    var isBuffering = false
    var stallRecoveryCount = 0
    let videoEnhancementStatus = VideoEnhancementStatus.disabled
    var onPlaybackEnded: (@MainActor () -> Void)?
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }
    private let player = AVPlayer()

    func load(source: PlaybackSource) {}
    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {}
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Float) {}
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() { stallRecoveryCount += 1 }
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) { subtitleSelectionCount += 1 }
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
