import Foundation
import Testing
@testable import Dusk

/// Issue #17: an HDHomeRun lineup listed every channel with "No program
/// information". Guide airings and lineup channels must meet on whichever key
/// both sides carry.
@Suite("Live TV guide matching")
struct PlexLiveTVGuideMatchingTests {
    private let provider = PlexLiveTVProvider(
        identifier: "tv.plex.providers.epg.cloud:2",
        providerIdentifier: "tv.plex.providers.epg.cloud",
        title: "Live TV",
        dvrID: 2,
        gridKey: "/tv.plex.providers.epg.cloud:2/grid"
    )

    private func channels(_ json: String) throws -> [PlexLiveChannel] {
        try JSONDecoder().decode([PlexLiveChannel].self, from: Data(json.utf8))
    }

    private func programs(_ json: String) throws -> [PlexLiveProgram] {
        try JSONDecoder().decode([PlexLiveProgram].self, from: Data(json.utf8))
    }

    private func titles(_ lineup: PlexLiveTVLineup) -> [[String]] {
        lineup.guides.map { $0.programs.map(\.title) }
    }

    @Test func matchesOnGridKey() throws {
        let channels = try channels("""
        [{ "id": "c1", "gridKey": "g1", "vcn": "3.1" },
         { "id": "c2", "gridKey": "g2", "vcn": "3.2" }]
        """)
        let programs = try programs("""
        [{ "ratingKey": "1", "title": "A", "Media": [{ "beginsAt": 100, "endsAt": 200, "gridKey": "g2" }] },
         { "ratingKey": "2", "title": "B", "Media": [{ "beginsAt": 100, "endsAt": 200, "gridKey": "g1" }] }]
        """)

        let lineup = PlexLiveTVLineup(provider: provider, channels: channels, programs: programs)

        #expect(titles(lineup) == [["B"], ["A"]])
    }

    /// The old matcher keyed a program only by its airing `gridKey` and lost
    /// it when that key differed from the channel's while the identifier agreed.
    @Test func fallsBackToChannelIdentifierWhenGridKeyDiffers() throws {
        let channels = try channels("""
        [{ "id": "c1", "gridKey": "g1" }]
        """)
        let programs = try programs("""
        [{ "ratingKey": "1", "title": "A",
           "Media": [{ "beginsAt": 100, "endsAt": 200, "gridKey": "other", "channelIdentifier": "c1" }] }]
        """)

        let lineup = PlexLiveTVLineup(provider: provider, channels: channels, programs: programs)

        #expect(titles(lineup) == [["A"]])
    }

    @Test func matchesChannelIdentifierAgainstLineupIdentifierAndKey() throws {
        let channels = try channels("""
        [{ "id": "c1", "identifier": "021", "title": "One" },
         { "id": "c2", "key": "WGBH-2", "title": "Two" }]
        """)
        let programs = try programs("""
        [{ "ratingKey": "1", "title": "A", "Media": [{ "beginsAt": 100, "endsAt": 200, "channelIdentifier": "WGBH-2" }] },
         { "ratingKey": "2", "title": "B", "Media": [{ "beginsAt": 100, "endsAt": 200, "channelIdentifier": "021" }] }]
        """)

        let lineup = PlexLiveTVLineup(provider: provider, channels: channels, programs: programs)

        #expect(titles(lineup) == [["B"], ["A"]])
        #expect(lineup.guides.map(\.channel.tuneIdentifier) == ["c1", "c2"])
    }

    @Test func matchesOnChannelNumberWhenNoIdentifierAgrees() throws {
        let channels = try channels("""
        [{ "id": "c1", "gridKey": "g1", "vcn": "3.1" },
         { "id": "c2", "gridKey": "g2", "channelVcn": "3.2" }]
        """)
        let programs = try programs("""
        [{ "ratingKey": "1", "title": "A",
           "Media": [{ "beginsAt": 100, "endsAt": 200, "channelIdentifier": "unknown", "channelVcn": "3-2" }] }]
        """)

        let lineup = PlexLiveTVLineup(provider: provider, channels: channels, programs: programs)

        #expect(titles(lineup) == [[], ["A"]])
    }

    /// Subchannels of one station often share a network title; a key that
    /// names several channels must not file the program under the first one.
    @Test func ambiguousDescriptiveKeysAreSkipped() throws {
        let channels = try channels("""
        [{ "id": "c1", "title": "Public Broadcasting Service", "callSign": "WGBH" },
         { "id": "c2", "title": "World", "callSign": "WGBHDT2" },
         { "id": "c3", "title": "Public Broadcasting Service", "callSign": "WGBX" }]
        """)
        let programs = try programs("""
        [{ "ratingKey": "1", "title": "Ambiguous",
           "Media": [{ "beginsAt": 100, "endsAt": 200, "channelTitle": "Public Broadcasting Service" }] },
         { "ratingKey": "2", "title": "By call sign",
           "Media": [{ "beginsAt": 100, "endsAt": 200, "channelTitle": "Public Broadcasting Service", "channelCallSign": "wgbx" }] },
         { "ratingKey": "3", "title": "By title",
           "Media": [{ "beginsAt": 100, "endsAt": 200, "channelTitle": "World" }] }]
        """)

        let lineup = PlexLiveTVLineup(provider: provider, channels: channels, programs: programs)

        #expect(titles(lineup) == [[], ["By title"], ["By call sign"]])
    }

    /// A program simulcast on two subchannels arrives as one grid item with
    /// two airings; both channels list it, each with its own times.
    @Test func everyAiringLandsOnItsChannel() throws {
        let channels = try channels("""
        [{ "id": "c1", "gridKey": "g1" },
         { "id": "c2", "gridKey": "g2" }]
        """)
        let programs = try programs("""
        [{ "ratingKey": "1", "title": "News", "Media": [
            { "beginsAt": 100, "endsAt": 200, "gridKey": "g1" },
            { "beginsAt": 300, "endsAt": 400, "gridKey": "g2" },
            { "beginsAt": 500, "endsAt": 600, "gridKey": "g1" }
        ] }]
        """)

        let lineup = PlexLiveTVLineup(provider: provider, channels: channels, programs: programs)

        #expect(lineup.guides[0].programs.map { $0.beginsAt?.timeIntervalSince1970 } == [100, 500])
        #expect(lineup.guides[1].programs.map { $0.beginsAt?.timeIntervalSince1970 } == [300])
        #expect(lineup.channel(for: lineup.guides[1].programs[0])?.id == "c2")
    }

    @Test func unmatchedChannelsKeepAnEmptyGuide() throws {
        let channels = try channels("""
        [{ "id": "c1", "gridKey": "g1" }]
        """)
        let programs = try programs("""
        [{ "ratingKey": "1", "title": "Elsewhere", "Media": [{ "beginsAt": 100, "endsAt": 200, "gridKey": "g9" }] },
         { "ratingKey": "2", "title": "Twice", "Media": [{ "beginsAt": 100, "endsAt": 200, "gridKey": "g1" }] },
         { "ratingKey": "2", "title": "Twice", "Media": [{ "beginsAt": 100, "endsAt": 200, "gridKey": "g1" }] }]
        """)

        let lineup = PlexLiveTVLineup(provider: provider, channels: channels, programs: programs)

        #expect(lineup.guides.map(\.channel.id) == ["c1"])
        #expect(titles(lineup) == [["Twice"]])
    }
}
