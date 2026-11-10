import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Dusk

@Suite("Manual audio offset (#67)")
struct AudioOffsetPolicyTests {
    private func session(
        _ engine: PlaybackEngineType,
        _ decision: PlaybackDecision = .directPlay,
        hdr: Bool = false,
        vlcDecodes: Bool = true
    ) -> AudioOffsetPolicy.Session {
        AudioOffsetPolicy.Session(engine: engine, decision: decision, containsHDRVideo: hdr, vlcKitCanDecodeVideo: vlcDecodes)
    }

    @Test(arguments: [PlaybackDecision.directPlay, .localDownload, .serverStream, .transcode(.p720_4Mbps), .spatialAudio])
    func sdrAVPlayerSwitchesToVLCKitForANonZeroOffset(decision: PlaybackDecision) {
        let session = session(.avPlayer, decision)
        #expect(AudioOffsetPolicy.availability(for: session) == .available)
        #expect(AudioOffsetPolicy.action(settingOffset: 50, in: session) == .switchToVLCKit)
        #expect(AudioOffsetPolicy.action(settingOffset: -50, in: session) == .switchToVLCKit)
        #expect(AudioOffsetPolicy.action(settingOffset: 0, in: session) == AudioOffsetPolicy.Action.none)
    }

    @Test(arguments: [PlaybackDecision.directPlay, .localDownload, .spatialAudio])
    func hdrOnAVPlayerIsBlocked(decision: PlaybackDecision) {
        let session = session(.avPlayer, decision, hdr: true)
        #expect(AudioOffsetPolicy.availability(for: session) == .hdrVideo)
        #expect(AudioOffsetPolicy.action(settingOffset: 50, in: session) == .blocked(reason: "Not available for HDR video"))
    }

    @Test func vlcKitAppliesLiveEvenForHDRAndLiveTV() {
        for session in [session(.vlcKit), session(.vlcKit, hdr: true), session(.vlcKit, .liveTV)] {
            #expect(AudioOffsetPolicy.action(settingOffset: 150, in: session) == .applyLive)
            #expect(AudioOffsetPolicy.action(settingOffset: 0, in: session) == .applyLive)
        }
    }

    @Test func airPlayLiveTVOnAVPlayerAndUndecodableVideoAreBlocked() {
        #expect(AudioOffsetPolicy.availability(for: session(.avPlayer, .airPlay)) == .airPlay)
        #expect(AudioOffsetPolicy.availability(for: session(.avPlayer, .liveTV)) == .liveTV)
        #expect(AudioOffsetPolicy.availability(for: session(.avPlayer, vlcDecodes: false)) == .unsupportedVideo)
    }

    @Test func aPinnedItemStaysOnVLCKitAcrossReplacements() {
        for decision in [PlaybackDecision.directPlay, .serverStream, .transcode(.p1080_8Mbps), .spatialAudio] {
            #expect(AudioOffsetPolicy.replacementEngine(
                requested: .avPlayer, isPinnedToVLCKit: true, decision: decision, containsHDRVideo: false
            ) == .vlcKit)
        }
        // Not pinned, AirPlay/live TV, or HDR: the requested engine stands.
        #expect(AudioOffsetPolicy.replacementEngine(
            requested: .avPlayer, isPinnedToVLCKit: false, decision: .directPlay, containsHDRVideo: false
        ) == .avPlayer)
        #expect(AudioOffsetPolicy.replacementEngine(
            requested: .avPlayer, isPinnedToVLCKit: true, decision: .airPlay, containsHDRVideo: false
        ) == .avPlayer)
        #expect(AudioOffsetPolicy.replacementEngine(
            requested: .avPlayer, isPinnedToVLCKit: true, decision: .liveTV, containsHDRVideo: false
        ) == .avPlayer)
        #expect(AudioOffsetPolicy.replacementEngine(
            requested: .avPlayer, isPinnedToVLCKit: true, decision: .spatialAudio, containsHDRVideo: true
        ) == .avPlayer)
    }

    @Test func clampingAndTitles() {
        #expect(AudioOffsetPolicy.clamped(2500) == 2000)
        #expect(AudioOffsetPolicy.clamped(-2500) == -2000)
        #expect(AudioOffsetPolicy.title(for: 0) == "0 ms")
        #expect(AudioOffsetPolicy.title(for: 150) == "+150 ms")
        #expect(AudioOffsetPolicy.title(for: -200) == "\u{2212}200 ms")
    }
}

@Suite("Manual audio offset on the coordinator (#67)", .serialized)
@MainActor
struct AudioOffsetCoordinatorTests {
    private func playback(engine: PlaybackEngineType, hdr: Bool, fake: AudioDelayRecordingEngine) throws -> PlaybackCoordinator {
        let playback = PlaybackCoordinator(plexService: PlexService())
        let video = hdr
            ? #"{"id":3,"streamType":1,"codec":"hevc","bitDepth":10,"colorTrc":"smpte2084"}"#
            : #"{"id":3,"streamType":1,"codec":"h264","bitDepth":8,"colorTrc":"bt709"}"#
        let details = try JSONDecoder().decode(PlexMediaDetails.self, from: Data("""
            {"ratingKey":"1","key":"/library/metadata/1","type":"movie","title":"Clip",
             "Media":[{"id":1,"container":"mp4","Part":[{"id":2,"key":"/clip.mp4","Stream":[
               \(video),
               {"id":4,"streamType":2,"codec":"aac","channels":2,"languageCode":"eng"}
             ]}]}]}
            """.utf8))
        let media = try #require(details.media.first)
        let url = try #require(URL(string: "https://example.invalid/clip.mp4"))
        let attemptID = UUID()
        playback.engine = fake
        playback.ratingKey = "1"
        playback.activeItemDetails = details
        playback.activeAudioStreamID = 4
        playback.debugInfo = PlaybackDebugInfo(
            title: "Clip", engine: engine, decision: .directPlay,
            media: media, part: media.parts[0], attemptID: attemptID,
            resolverReason: "test", sanitizedPlaybackURL: url.absoluteString
        )
        playback.playbackSource = PlaybackSource(
            url: url, startPosition: nil,
            context: PlaybackAttemptContext(
                attemptID: attemptID, title: "Clip", ratingKey: "1", engine: engine,
                resolverReason: "test", mediaID: 1, partID: 2,
                sanitizedPlaybackURL: url.absoluteString
            )
        )
        return playback
    }

    @Test func sdrAVPlayerSwitchesAtThePositionAndNeverSwitchesBack() throws {
        let fake = AudioDelayRecordingEngine(state: .playing, supportsDelay: false)
        fake.currentTime = 42
        let playback = try playback(engine: .avPlayer, hdr: false, fake: fake)
        defer { playback.engine?.stop(); playback.cancelDirectPlayFallbackWatch() }

        playback.setAudioOffset(milliseconds: 50)
        #expect(playback.engine !== fake)
        #expect(playback.debugInfo?.engine == .vlcKit)
        #expect(playback.engine?.supportsAudioDelay == true)
        #expect(playback.playbackSource?.startPosition == 42)
        #expect(playback.audioOffsetMilliseconds == 50)
        #expect(playback.isAudioOffsetPinnedToVLCKit)

        let vlcEngine = playback.engine
        playback.setAudioOffset(milliseconds: 0)
        #expect(playback.engine === vlcEngine)
        #expect(playback.debugInfo?.engine == .vlcKit)
        #expect(playback.audioOffsetMilliseconds == 0)
    }

    @Test func hdrOnAVPlayerKeepsPlayingUntouched() throws {
        let fake = AudioDelayRecordingEngine(state: .playing, supportsDelay: false)
        let playback = try playback(engine: .avPlayer, hdr: true, fake: fake)
        #expect(playback.audioOffsetAvailability == .hdrVideo)
        playback.setAudioOffset(milliseconds: 50)
        #expect(playback.engine === fake)
        #expect(playback.debugInfo?.engine == .avPlayer)
        #expect(playback.audioOffsetMilliseconds == 0)
    }

    @Test func vlcKitAppliesTheDelayLive() throws {
        let fake = AudioDelayRecordingEngine(state: .playing, supportsDelay: true)
        let playback = try playback(engine: .vlcKit, hdr: false, fake: fake)
        playback.setAudioOffset(milliseconds: 100)
        playback.setAudioOffset(milliseconds: -2500)
        playback.setAudioOffset(milliseconds: 0)
        #expect(playback.engine === fake)
        #expect(fake.appliedDelays == [100, -2000, 0])
    }
}

private final class AudioDelayRecordingEngine: PlaybackEngine {
    var state: PlaybackState
    let supportsAudioDelay: Bool
    var appliedDelays: [Int] = []
    init(state: PlaybackState, supportsDelay: Bool) {
        self.state = state
        self.supportsAudioDelay = supportsDelay
    }
    func setAudioDelay(milliseconds: Int) { appliedDelays.append(milliseconds) }

    var error: PlaybackError? { nil }
    var currentTime: TimeInterval = 0
    let duration: TimeInterval = 600
    var isBuffering = false
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
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
