import Foundation
import Testing
@testable import Dusk

/// Plex item-family DTOs decode Plex's wire shapes leniently, and
/// `PlexItemMapper` turns them into the domain values the app used to decode
/// directly, stamping the server on everything it builds.
@Suite("Plex item DTOs and mapper")
struct PlexItemMapperTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("An item maps Plex's field names, lenient section id, smart flag, logo and tags")
    func item() throws {
        let dto = try decode(PlexItemDTO.self, """
        { "ratingKey": "7", "key": "/library/metadata/7", "type": "collection", "title": "Heists",
          "librarySectionID": 3, "smart": "1", "viewCount": 2, "viewOffset": 1200,
          "lastViewedAt": 1700000000, "leafCount": 10, "viewedLeafCount": 4,
          "parentRatingKey": "6", "grandparentRatingKey": "5",
          "Image": [{ "type": "coverPoster", "url": "/p" }, { "type": "clearLogo", "url": "/logo" }],
          "Genre": [{ "tag": "Crime", "id": "12" }, { "tag": "Drama", "id": "x" }],
          "Role": [{ "tag": "Ana", "role": "Lead", "filter": "actor=99" }],
          "Guid": [{ "id": "tmdb://603" }] }
        """)
        let item = PlexItemMapper.map(dto, serverID: "srv")

        #expect(item.id == MediaItemID(serverID: "srv", itemID: "7"))
        #expect(item.libraryID == "3")
        #expect(item.isSmartCollection)
        #expect(item.playCount == 2)
        #expect(item.resumeOffsetMs == 1200)
        #expect(item.lastPlayedAt == 1700000000)
        #expect(item.episodeCount == 10)
        #expect(item.watchedEpisodeCount == 4)
        #expect(item.parentID == "6")
        #expect(item.grandparentID == "5")
        #expect(item.clearLogo == "/logo")
        #expect(item.genres == [Tag(tag: "Crime", id: 12), Tag(tag: "Drama", id: nil)])
        #expect(item.roles?.first?.personID == "99")
        #expect(item.roles?.first?.role == "Lead")
        #expect(item.externalIDs.tmdb == "603")
    }

    @Test("An explicit clearLogo wins over the Image array; an empty server id is unstamped")
    func explicitLogoAndEmptyServer() throws {
        let dto = try decode(PlexItemDTO.self, """
        { "ratingKey": "1", "key": "/k", "type": "movie", "title": "A", "librarySectionID": "4",
          "clearLogo": "/explicit", "Image": [{ "type": "clearLogo", "url": "/array" }] }
        """)
        let item = PlexItemMapper.map(dto, serverID: "")
        #expect(item.clearLogo == "/explicit")
        #expect(item.libraryID == "4")
        #expect(item.serverID == nil)
    }

    @Test("A hub drops rows that are not items and stamps the server on its items and source")
    func hub() throws {
        let dto = try decode(PlexHubDTO.self, """
        { "title": "Movies", "key": "/hubs/x", "type": "movie", "hubIdentifier": "movie.recentlyadded.2",
          "size": 2, "more": true, "librarySectionID": 2,
          "Metadata": [{ "ratingKey": "1", "key": "/k/1", "type": "movie", "title": "A" }],
          "Directory": [{ "title": "Suggestion", "nested": [1, "x", null, { "a": true }] },
                        { "ratingKey": "2", "key": "/k/2", "type": "show", "title": "B" }] }
        """)
        #expect(dto.items.map(\.ratingKey) == ["1", "2"])

        let row = PlexItemMapper.map(dto, serverID: "srv")
        #expect(row.more == true)
        #expect(row.libraryID == "2")
        #expect(row.serverID == "srv")
        #expect(row.mergeIdentity == nil)
        #expect(row.items.allSatisfy { $0.serverID == "srv" })
        #expect(row.sources == [HomeRowSource(serverID: "srv", key: "/hubs/x", size: 2, more: true, hubIdentifier: "movie.recentlyadded.2")])

        #expect(PlexItemMapper.map(dto, serverID: nil).sources.isEmpty)
    }

    @Test("Details sort markers by start and trim a blank edition")
    func details() throws {
        let dto = try decode(PlexMediaDetailsDTO.self, """
        { "ratingKey": "9", "key": "/library/metadata/9", "type": "episode", "title": "Pilot",
          "editionTitle": "  ", "librarySectionID": 1, "viewOffset": 30, "leafCount": 1,
          "parentRatingKey": "8", "grandparentRatingKey": "7",
          "Collection": [{ "tag": "Channel", "id": 4 }],
          "Marker": [{ "id": 2, "type": "credits", "startTimeOffset": 900, "endTimeOffset": 1000 },
                     { "id": 1, "type": "intro", "startTimeOffset": 10, "endTimeOffset": 60 }] }
        """)
        #expect(dto.markers.map(\.id) == ["2", "1"])

        let details = PlexItemMapper.map(dto, serverID: "srv")
        #expect(details.id == MediaItemID(serverID: "srv", itemID: "9"))
        #expect(details.editionTitle == nil)
        #expect(details.markers.map(\.id) == ["1", "2"])
        #expect(details.libraryID == "1")
        #expect(details.resumeOffsetMs == 30)
        #expect(details.episodeCount == 1)
        #expect(details.parentID == "8")
        #expect(details.grandparentID == "7")
        #expect(details.collections == [Tag(tag: "Channel", id: 4)])
        #expect(details.media.isEmpty)
    }

    @Test("Seasons and episodes map their Plex field names")
    func seasonsAndEpisodes() throws {
        let season = PlexItemMapper.map(try decode(PlexSeasonDTO.self, """
        { "ratingKey": "20", "key": "/k/20", "title": "Season 2", "index": 2,
          "parentRatingKey": "10", "leafCount": 8, "viewedLeafCount": 3 }
        """), serverID: "srv")
        #expect(season.id == MediaItemID(serverID: "srv", itemID: "20"))
        #expect(season.parentID == "10")
        #expect(season.unwatchedEpisodeCount == 5)

        let episode = PlexItemMapper.map(try decode(PlexEpisodeDTO.self, """
        { "ratingKey": "21", "key": "/k/21", "title": "E1", "index": 1, "parentIndex": 2,
          "parentRatingKey": "20", "grandparentRatingKey": "10", "viewCount": 1, "viewOffset": 5 }
        """), serverID: "srv")
        #expect(episode.id == MediaItemID(serverID: "srv", itemID: "21"))
        #expect(episode.parentID == "20")
        #expect(episode.grandparentID == "10")
        #expect(episode.isWatched)
        #expect(episode.resumeOffsetMs == 5)

        // A season without an index is not a season.
        #expect(throws: DecodingError.self) {
            try decode(PlexSeasonDTO.self, #"{ "ratingKey": "1", "key": "/k", "title": "Specials" }"#)
        }
    }

    @Test("A person's id falls back to the filter value")
    func person() throws {
        let withID = PlexItemMapper.map(try decode(PlexPersonDTO.self, #"{ "id": 42, "tag": "Ana" }"#))
        #expect(withID.personID == "42")

        let fromFilter = PlexItemMapper.map(try decode(PlexPersonDTO.self, #"{ "tag": "Ben", "filter": "actor=77" }"#))
        #expect(fromFilter.personID == "77")
        #expect(fromFilter.id == "77")

        let bare = PlexItemMapper.map(try decode(PlexPersonDTO.self, #"{ "tag": "Cy" }"#))
        #expect(bare.personID == nil)
        #expect(bare.id == "Cy")
    }

    @Test("Decoding a domain type directly still stamps the decoder's server")
    func forwarders() throws {
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "srv"
        let json = Data(#"{ "title": "Row", "Metadata": [{ "ratingKey": "1", "key": "/k", "type": "movie", "title": "A" }] }"#.utf8)

        let row = try decoder.decode(HomeRow.self, from: json)
        let mapped = PlexItemMapper.map(try JSONDecoder().decode(PlexHubDTO.self, from: json), serverID: "srv")
        #expect(row == mapped)
        #expect(row.items.first?.serverID == "srv")
        #expect(row.sources == mapped.sources)

        let unscoped = try JSONDecoder().decode(MediaItem.self, from: Data(#"{ "ratingKey": "1", "key": "/k", "type": "movie", "title": "A" }"#.utf8))
        #expect(unscoped.serverID == nil)
    }
}
