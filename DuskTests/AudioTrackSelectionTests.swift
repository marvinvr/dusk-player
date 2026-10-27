import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Dusk

@Suite("Manual audio selection", .serialized)
@MainActor
struct AudioTrackSelectionTests {
    @Test(arguments: [false, true])
    func manualChoiceBeatsLanguageSelectionAndReconfiguration(readyAtStartup: Bool) throws {
        let preferences = UserPreferences()
        let previousLanguage = preferences.defaultAudioLanguage
        preferences.defaultAudioLanguage = "en"
        defer { preferences.defaultAudioLanguage = previousLanguage }
        let part = try makePart()
        let engine = AudioSelectionEngine(tracks: part.streams.map(AudioTrack.init(stream:)))
        engine.isReadyForAutomaticAudioSelection = readyAtStartup
        let model = PlayerViewModel(engine: engine)
        defer { model.cleanup() }
        model.configureAutomaticTrackSelection(preferences: preferences, part: part)
        #expect(model.hasAppliedAutomaticAudioSelection == readyAtStartup)

        var saved: [Int?] = []
        model.userTrackSelectionHandler = { type, streamID in
            if type == .audio { saved.append(streamID) }
        }
        let italian = try #require(model.audioTracks.first { $0.plexStreamID == 12 })
        model.selectAudio(italian)
        engine.isReadyForAutomaticAudioSelection = true
        model.sync()
        #expect(engine.selectedAudioTrackID == italian.id)
        #expect(engine.audioSelections == [italian.id])
        // Player onAppear can configure the same live engine again.
        model.configureAutomaticTrackSelection(preferences: preferences, part: part)
        model.sync()
        #expect(engine.selectedAudioTrackID == italian.id)
        #expect(engine.audioSelections == [italian.id])
        #expect(saved == [12])
    }

    @Test func serverPickerKeepsManualChoiceAcrossSynchronization() throws {
        let preferences = UserPreferences()
        let part = try makePart()
        let engine = AudioSelectionEngine(tracks: [])
        let model = PlayerViewModel(engine: engine)
        defer { model.cleanup() }
        model.configureAutomaticTrackSelection(
            preferences: preferences, part: part,
            usesServerTrackSelection: true, selectedAudioStreamID: 11
        )
        let italian = try #require(model.audioTracks.first { $0.id == 12 })
        var requests: [Int?] = []
        model.plexTrackSelectionHandler = { audio, _ in requests.append(audio) }
        model.selectAudio(italian)
        for _ in 0..<3 { model.sync() }
        model.configureAutomaticTrackSelection(
            preferences: preferences, part: part,
            usesServerTrackSelection: true, selectedAudioStreamID: 11
        )
        model.sync()
        #expect(model.selectedAudioTrackID == 12)
        #expect(requests == [12])
        #expect(engine.audioSelections.isEmpty) // HLS changes go through Plex.
    }

    @Test func movieChoiceSurvivesAReplacementPlayerWithoutAShowPreference() throws {
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.activeAudioStreamID = 12
        playback.rememberShowTrackChoice(type: .audio, streamID: 12)
        #expect(playback.activeShowTrackScope == nil)
        let selection = try #require(playback.rememberedShowTrackSelection())
        #expect(selection.audioStreamID == 12)

        let part = try makePart()
        let engine = AudioSelectionEngine(tracks: part.streams.map(AudioTrack.init(stream:)))
        engine.isReadyForAutomaticAudioSelection = true
        let model = PlayerViewModel(engine: engine)
        defer { model.cleanup() }
        model.hasConfiguredAutomaticTrackSelection = true
        model.preferredAudioLanguage = "en"
        model.sourcePart = part
        model.explicitTrackSelection = selection
        model.sync()
        #expect(engine.selectedAudioTrackID == 12)
        playback.clearPlayerState()
        #expect(playback.manuallySelectedAudioStreamID == nil)
        #expect(playback.rememberedShowTrackSelection() == nil)
    }

    private func makePart() throws -> PlexMediaPart {
        try JSONDecoder().decode(PlexMediaPart.self, from: Data(#"""
        {"id":1,"key":"/fixture.mkv","Stream":[
          {"id":11,"streamType":2,"codec":"eac3","channels":6,"audioChannelLayout":"5.1(side)","languageCode":"eng","selected":true},
          {"id":12,"streamType":2,"codec":"eac3","channels":6,"audioChannelLayout":"5.1(side)","languageCode":"ita"}
        ]}
        """#.utf8))
    }
}

/// Never loads an asset or starts an audio output, on either simulator.
@MainActor
private final class AudioSelectionEngine: PlaybackEngine {
    var state = PlaybackState.playing
    let currentTime: TimeInterval = 0
    let duration: TimeInterval = 120
    let isBuffering = false
    let error: PlaybackError? = nil
    let videoEnhancementStatus = VideoEnhancementStatus.disabled
    var onPlaybackEnded: (@MainActor () -> Void)?
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack]
    let selectedSubtitleTrackID: Int? = nil
    var selectedAudioTrackID: Int?
    var audioSelections: [Int] = []
    var isReadyForAutomaticAudioSelection = false
    private let player = AVPlayer()
    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }

    init(tracks: [AudioTrack]) {
        availableAudioTracks = tracks
        selectedAudioTrackID = tracks.first?.id
        player.isMuted = true
    }
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
    func selectAudioTrack(_ track: AudioTrack) {
        selectedAudioTrackID = track.id
        audioSelections.append(track.id)
    }
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
