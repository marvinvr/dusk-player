import Foundation
import Testing
@testable import Dusk

@Suite("Per-show audio and subtitle choices")
@MainActor
struct ShowTrackPreferenceTests {
    @Test func matchesLanguageAcrossEpisodeIDsAndSeasons() throws {
        let first = try episode(streams: #"""
            {"id":11,"streamType":2,"languageCode":"eng","codec":"aac","channels":2},
            {"id":12,"streamType":3,"languageCode":"eng","codec":"srt"}
            """#)
        let next = try episode(season: 2, streams: #"""
            {"id":11,"streamType":2,"languageCode":"deu","codec":"aac","channels":2},
            {"id":81,"streamType":2,"languageTag":"en-US","codec":"ac3","channels":6},
            {"id":12,"streamType":3,"languageCode":"ger","codec":"srt"},
            {"id":82,"streamType":3,"languageTag":"en-GB","codec":"webvtt"}
            """#)
        let remembered = try preferences(from: first)
        #expect(remembered.audioStream(in: next.media[0].parts[0])?.id == 81)
        #expect(remembered.subtitleStreamID(in: next.media[0].parts[0], fallback: nil) == 82)
        #expect(scope(first) == scope(next))
    }

    @Test(arguments: ["normal", "forced", "sdh", "forced-sdh"])
    func subtitlePurposeIsRequired(kind: String) throws {
        let details = try episode(streams: #"""
            {"id":1,"streamType":3,"languageCode":"eng","codec":"srt"},
            {"id":2,"streamType":3,"languageCode":"eng","codec":"srt","forced":true},
            {"id":3,"streamType":3,"languageCode":"eng","codec":"srt","hearingImpaired":true},
            {"id":4,"streamType":3,"languageCode":"eng","codec":"srt","forced":true,"hearingImpaired":true}
            """#)
        let part = details.media[0].parts[0]
        let index = ["normal": 0, "forced": 1, "sdh": 2, "forced-sdh": 3][kind]!
        let descriptor = try #require(ShowTrackDescriptor(stream: part.streams[index]))
        #expect(descriptor.match(in: part.streams, type: .subtitle)?.id == index + 1)
        #expect(descriptor.match(in: part.streams.filter { $0.id != index + 1 }, type: .subtitle) == nil)
    }

    @Test func titleFlagsMatchExplicitFlags() throws {
        let source = try episode(streams: #"""
            {"id":1,"streamType":3,"languageCode":"eng","displayTitle":"English (Forced SDH)"}
            """#)
        let target = try episode(streams: #"""
            {"id":2,"streamType":3,"languageCode":"en","forced":true,"hearingImpaired":true},
            {"id":3,"streamType":3,"languageCode":"en","forced":true}
            """#)
        let descriptor = try #require(ShowTrackDescriptor(stream: source.media[0].parts[0].streams[0]))
        #expect(descriptor.match(in: target.media[0].parts[0].streams, type: .subtitle)?.id == 2)
    }

    @Test func codecAndChannelsBreakTiesWithoutBecomingRequirements() throws {
        let details = try episode(streams: #"""
            {"id":1,"streamType":2,"languageCode":"eng","codec":"aac","channels":2},
            {"id":2,"streamType":2,"languageCode":"eng","codec":"ac3","channels":2},
            {"id":3,"streamType":2,"languageCode":"eng","codec":"ac3","channels":6},
            {"id":4,"streamType":2,"languageCode":"deu","codec":"ac3","channels":6}
            """#)
        let streams = details.media[0].parts[0].streams
        let descriptor = try #require(ShowTrackDescriptor(stream: streams[2]))
        #expect(descriptor.match(in: streams, type: .audio)?.id == 3)
        #expect(descriptor.match(in: Array(streams.prefix(2)), type: .audio)?.id == 2)
        #expect(descriptor.match(in: Array(streams.prefix(1)), type: .audio)?.id == 1)
        #expect(descriptor.match(in: [streams[3]], type: .audio) == nil)
    }

    @Test func normalAudioDoesNotBecomeCommentaryOrDescription() throws {
        let details = try episode(streams: #"""
            {"id":1,"streamType":2,"languageCode":"eng","displayTitle":"English"},
            {"id":2,"streamType":2,"languageCode":"eng","displayTitle":"Director commentary"},
            {"id":3,"streamType":2,"languageCode":"eng","displayTitle":"Audio description"}
            """#)
        let streams = details.media[0].parts[0].streams
        for stream in streams {
            let descriptor = try #require(ShowTrackDescriptor(stream: stream))
            #expect(descriptor.match(in: streams, type: .audio)?.id == stream.id)
            #expect(descriptor.match(in: streams.filter { $0.id != stream.id }, type: .audio) == nil)
        }
    }

    @Test func missingMatchesUseDefaultsWithoutErasingThePreference() throws {
        let first = try episode(streams: #"""
            {"id":11,"streamType":2,"languageCode":"eng"},
            {"id":12,"streamType":3,"languageCode":"eng","forced":true}
            """#)
        let missing = try episode(streams: #"""
            {"id":21,"streamType":2,"languageCode":"deu"},
            {"id":22,"streamType":3,"languageCode":"eng"}
            """#)
        let remembered = try preferences(from: first)
        let part = missing.media[0].parts[0]
        #expect(remembered.audioStream(in: part) == nil)
        #expect(remembered.subtitleStreamID(in: part, fallback: 22) == 22)
        #expect(!remembered.hasMatch(in: part))
        #expect(remembered.subtitleStreamID(in: first.media[0].parts[0], fallback: 22) == 12)
    }

    @Test func offSurvivesRelaunchAndOverridesSelectedForcedAndGlobalDefaults() throws {
        try withStore { store, defaults in
            let details = try episode(streams: #"""
                {"id":12,"streamType":3,"languageCode":"eng","forced":true,"selected":true,"default":true}
                """#)
            let identity = try #require(scope(details))
            store.save(ShowTrackPreferences(subtitles: .off), for: identity)
            let reopened = ShowTrackPreferenceStore(defaults: defaults)
            let remembered = try #require(reopened.preferences(for: identity))
            #expect(remembered.hasMatch(in: details.media[0].parts[0]))
            #expect(remembered.subtitleStreamID(in: details.media[0].parts[0], fallback: 12) == nil)
            let resolved = Optional(remembered).map {
                $0.subtitleStreamID(in: details.media[0].parts[0], fallback: 12)
            } ?? 12
            #expect(resolved == nil) // Preserve the distinction between missing and Off.
        }
    }

    @Test func persistenceIsScopedToProfileServerAndShow() throws {
        try withStore { store, defaults in
            let details = try episode()
            let identity = try #require(scope(details))
            store.save(ShowTrackPreferences(subtitles: .off), for: identity)
            let reopened = ShowTrackPreferenceStore(defaults: defaults)
            #expect(reopened.preferences(for: identity)?.subtitles == .off)
            #expect(reopened.preferences(for: try #require(scope(details, profile: "other"))) == nil)
            #expect(reopened.preferences(for: try #require(scope(details, server: "other"))) == nil)
            #expect(reopened.preferences(for: try #require(scope(episode(show: "other")))) == nil)
            #expect(scope(details, profile: nil) == nil)
            #expect(scope(details, server: nil) == nil)
            #expect(scope(try episode(type: "movie")) == nil)
            #expect(scope(try episode(show: nil)) == nil)
        }
    }

    @Test func explicitChoicesPersistIndependentlyAcrossRelaunch() throws {
        try withStore { store, defaults in
            let details = try episode(streams: #"""
                {"id":11,"streamType":2,"languageCode":"eng","codec":"aac","channels":2},
                {"id":12,"streamType":3,"languageCode":"eng","codec":"srt","hearingImpaired":true}
                """#)
            let service = PlexService()
            service.activeHomeUser = nil
            service.currentUser = nil
            service.primaryProfileID = "profile"
            service.primaryAccountToken = "test"
            service.activeAccountToken = "test"
            service.homeSelectionRequested = false
            let playback = PlaybackCoordinator(plexService: service)
            playback.showTrackPreferenceStore = store
            playback.activeShowTrackScope = scope(details)
            playback.activeItemDetails = details
            playback.activePlaybackUsesLocalDownload = true // No network side effects.
            let media = details.media[0]
            playback.debugInfo = PlaybackDebugInfo(
                title: details.title, engine: .vlcKit, decision: .localDownload,
                media: media, part: media.parts[0], attemptID: UUID(),
                resolverReason: "Fixture", sanitizedPlaybackURL: "/fixture.mp4"
            )
            playback.rememberShowTrackChoice(type: .audio, streamID: 11)
            playback.rememberShowTrackChoice(type: .subtitle, streamID: 12)
            let identity = try #require(scope(details))
            let reopened = ShowTrackPreferenceStore(defaults: defaults)
            let saved = try #require(reopened.preferences(for: identity))
            #expect(saved.audioStream(in: media.parts[0])?.id == 11)
            #expect(saved.subtitleStreamID(in: media.parts[0], fallback: nil) == 12)
            playback.rememberShowTrackChoice(type: .subtitle, streamID: nil)
            let off = try #require(reopened.preferences(for: identity))
            #expect(off.subtitles == .off)
            #expect(off.audio == saved.audio)
        }
    }

    // MARK: - Server selection (issue #21)

    @Test func serverSelectedAudioBreaksTiesWithinTheLanguage() throws {
        let part = try episode(streams: #"""
            {"id":1,"streamType":2,"languageCode":"eng","codec":"eac3","channels":6},
            {"id":2,"streamType":2,"languageCode":"eng","codec":"ac3","channels":6,"selected":true},
            {"id":3,"streamType":2,"languageCode":"deu","codec":"eac3","channels":6}
            """#).media[0].parts[0]
        #expect(PlayerViewModel.preferredAudioStreamPosition(inPart: part, preferredLanguage: nil) == 1)
        #expect(PlayerViewModel.preferredAudioStreamPosition(inPart: part, preferredLanguage: "en") == 1)
        // The preferred language still decides the language.
        #expect(PlayerViewModel.preferredAudioStreamPosition(inPart: part, preferredLanguage: "de") == 2)
    }

    /// Plex audio `languageCode` is often ISO 639-2, including bibliographic
    /// forms (`gre`, `slo`). Preferences store the `CommonLanguage` ISO 639-1
    /// code. Matching goes through `PlayerViewModel.normalizedLanguageCode`.
    @Test(arguments: [
        (CommonLanguage.hungarian, "hun"),
        (CommonLanguage.greek, "gre"),
        (CommonLanguage.greek, "ell"),
        (CommonLanguage.ukrainian, "ukr"),
        (CommonLanguage.croatian, "hrv"),
        (CommonLanguage.bulgarian, "bul"),
        (CommonLanguage.slovak, "slo"),
        (CommonLanguage.slovak, "slk"),
        (CommonLanguage.serbian, "srp"),
        (CommonLanguage.slovenian, "slv"),
    ])
    func plexISO6392AudioCodesMatchCommonLanguages(_ language: CommonLanguage, plexCode: String) throws {
        let part = try episode(streams: """
            {"id":1,"streamType":2,"languageCode":"eng","codec":"aac","channels":2},
            {"id":2,"streamType":2,"languageCode":"\(plexCode)","codec":"aac","channels":2}
            """).media[0].parts[0]
        #expect(PlayerViewModel.preferredAudioStreamPosition(
            inPart: part, preferredLanguage: language.code
        ) == 1)
        #expect(PlayerViewModel.normalizedLanguageCode(plexCode) == language.code)
    }

    @Test func serverSelectedAudioIsSkippedWhenItCannotBeDecoded() throws {
        let part = try episode(streams: #"""
            {"id":1,"streamType":2,"languageCode":"eng","codec":"truehd","channels":8,"selected":true},
            {"id":2,"streamType":2,"languageCode":"eng","codec":"ac3","channels":6}
            """#).media[0].parts[0]
        #expect(PlayerViewModel.preferredAudioStreamPosition(
            inPart: part, preferredLanguage: nil, decodesTrueHD: false
        ) == 1)
    }

    @Test func automaticRemuxWriteRestoresOnlyWhatItChanged() throws {
        let part = try episode(streams: #"""
            {"id":1,"streamType":2,"languageCode":"jpn","codec":"aac","selected":true},
            {"id":2,"streamType":2,"languageCode":"eng","codec":"aac"},
            {"id":3,"streamType":3,"languageCode":"eng","codec":"pgs","selected":true},
            {"id":4,"streamType":3,"languageCode":"eng","codec":"srt","forced":true}
            """#).media[0].parts[0]
        let unchanged = ServerStreamSelectionRestore(
            part: part, writtenAudioStreamID: 1, writtenSubtitleStreamID: 3, serverID: "server"
        )
        #expect(unchanged.isEmpty)
        // A remux that drops the bitmap subtitle cleared it on the server.
        let dropped = ServerStreamSelectionRestore(
            part: part, writtenAudioStreamID: 2, writtenSubtitleStreamID: nil, serverID: "server"
        )
        #expect(dropped.audioStreamID == 1)
        #expect(dropped.subtitleStreamID == 3)
        // Nothing selected before means writing "none" back.
        let none = try episode(streams: #"""
            {"id":1,"streamType":2,"languageCode":"eng","codec":"aac"},
            {"id":4,"streamType":3,"languageCode":"eng","codec":"srt","forced":true}
            """#).media[0].parts[0]
        let forced = ServerStreamSelectionRestore(
            part: none, writtenAudioStreamID: 1, writtenSubtitleStreamID: 4, serverID: "server"
        )
        #expect(forced.audioStreamID == nil)
        #expect(forced.subtitleStreamID == 0)
    }

    @Test func manualPickKeepsItsHalfOnTheServer() throws {
        try withStore { store, _ in
            let details = try episode(streams: #"""
                {"id":11,"streamType":2,"languageCode":"eng","codec":"aac","channels":2},
                {"id":12,"streamType":3,"languageCode":"eng","codec":"srt","selected":true}
                """#)
            let playback = PlaybackCoordinator(plexService: PlexService())
            playback.showTrackPreferenceStore = store
            playback.activePlaybackUsesLocalDownload = true // No network side effects.
            playback.automaticServerSelectionRestore = ServerStreamSelectionRestore(
                part: details.media[0].parts[0], writtenAudioStreamID: nil,
                writtenSubtitleStreamID: nil, serverID: "server"
            )
            playback.automaticServerSelectionRestore?.audioStreamID = 11
            #expect(playback.automaticServerSelectionRestore?.subtitleStreamID == 12)
            playback.rememberShowTrackChoice(type: .subtitle, streamID: nil)
            #expect(playback.automaticServerSelectionRestore?.subtitleStreamID == nil)
            #expect(playback.automaticServerSelectionRestore?.audioStreamID == 11)
            playback.rememberShowTrackChoice(type: .audio, streamID: 11)
            #expect(playback.automaticServerSelectionRestore?.isEmpty == true)
        }
    }

    @Test func unspecifiedAndUnknownLanguagesDoNotGuess() throws {
        let details = try episode(streams: #"""
            {"id":1,"streamType":2},
            {"id":2,"streamType":2,"languageCode":"und"},
            {"id":3,"streamType":3,"languageCode":"unk"}
            """#)
        for stream in details.media[0].parts[0].streams {
            #expect(ShowTrackDescriptor(stream: stream) == nil)
        }
    }

    @Test func rememberedEmbeddedSubtitlesFeedTheExistingSDRRoutingRule() throws {
        let details = try episode(streams: #"""
            {"id":1,"streamType":1,"codec":"h264","bitDepth":8,"width":1280,"height":720,"colorTrc":"bt709"},
            {"id":2,"streamType":2,"codec":"aac","languageCode":"eng","channels":2},
            {"id":3,"streamType":3,"codec":"mov_text","languageCode":"eng"}
            """#)
        let media = details.media[0]
        let part = media.parts[0]
        let descriptor = try #require(ShowTrackDescriptor(stream: part.streams[2]))
        let remembered = ShowTrackPreferences(subtitles: .track(descriptor))
        let decision = StreamResolver.evaluateForDirectPlayback(
            media: media, part: part, enhancementMode: .enabled,
            selectedSubtitleStreamID: remembered.subtitleStreamID(in: part, fallback: nil)
        )
        #if os(tvOS)
        #expect(decision.engine == .vlcKit)
        #expect(decision.usesEnhancedSubtitleRenderer)
        #else
        #expect(decision.engine == .avPlayer)
        #endif
    }

    @Test(arguments: [
        #""DOVIPresent":true,"DOVIProfile":5,"DOVIBLCompatID":0"#,
        #""DOVIPresent":true,"DOVIProfile":8,"DOVIBLCompatID":1"#,
        #""colorTrc":"smpte2084""#,
        #""colorTrc":"arib-std-b67""#,
    ])
    func rememberedSubtitlesCannotEnableEnhancedVLCRoutingForHDR(videoFields: String) throws {
        let details = try episode(streams: """
            {"id":1,"streamType":1,"codec":"hevc","width":1280,"height":720,\(videoFields)},
            {"id":2,"streamType":2,"codec":"aac","languageCode":"eng"},
            {"id":3,"streamType":3,"codec":"mov_text","languageCode":"eng"},
            {"id":4,"streamType":3,"codec":"pgs","languageCode":"eng"}
            """)
        let media = details.media[0]
        let part = media.parts[0]
        #expect(ShowTrackPreferences.remuxSubtitleStreamID(4, in: part) == nil)
        #expect(ShowTrackPreferences.remuxSubtitleStreamID(3, in: part) == 3)
        let descriptor = try #require(ShowTrackDescriptor(stream: part.streams[2]))
        let remembered = ShowTrackPreferences(subtitles: .track(descriptor))
        let decision = StreamResolver.evaluateForDirectPlayback(
            media: media, part: part, enhancementMode: .enabled,
            selectedSubtitleStreamID: remembered.subtitleStreamID(in: part, fallback: nil)
        )
        #expect(!decision.usesEnhancedSubtitleRenderer)
    }

    private func episode(
        type: String = "episode", show: String? = "show-1", season: Int = 1, streams: String = ""
    ) throws -> PlexMediaDetails {
        let showField = show.map { ",\"grandparentRatingKey\":\"\($0)\"" } ?? ""
        return try JSONDecoder().decode(PlexMediaDetails.self, from: Data("""
            {"ratingKey":"episode-\(season)","key":"/library/metadata/episode","type":"\(type)",
             "title":"Episode","parentIndex":\(season)\(showField),
             "Media":[{"id":1,"container":"mp4","Part":[{"id":2,"key":"/clip.mp4","Stream":[\(streams)]}]}]}
            """.utf8))
    }

    private func preferences(from details: PlexMediaDetails) throws -> ShowTrackPreferences {
        let streams = details.media[0].parts[0].streams
        let audio = try #require(streams.first { $0.streamType == .audio })
        let subtitle = try #require(streams.first { $0.streamType == .subtitle })
        let audioDescriptor: ShowTrackDescriptor = try #require(ShowTrackDescriptor(stream: audio))
        let subtitleDescriptor: ShowTrackDescriptor = try #require(ShowTrackDescriptor(stream: subtitle))
        return ShowTrackPreferences(audio: audioDescriptor, subtitles: .track(subtitleDescriptor))
    }

    private func scope(
        _ details: PlexMediaDetails, profile: String? = "profile", server: String? = "server"
    ) -> ShowTrackPreferenceStore.Scope? {
        ShowTrackPreferenceStore.Scope(profileID: profile, serverID: server, details: details)
    }

    private func withStore(_ body: (ShowTrackPreferenceStore, UserDefaults) throws -> Void) throws {
        let suite = "ShowTrackPreferenceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(ShowTrackPreferenceStore(defaults: defaults), defaults)
    }
}
