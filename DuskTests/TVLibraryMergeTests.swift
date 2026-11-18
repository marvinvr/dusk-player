import Foundation
import Testing
@testable import Dusk

/// The same show filed in two libraries of one server ("Kids TV" and "TV")
/// must appear once on Home.
@Suite("TV in multiple libraries")
@MainActor
struct TVLibraryMergeTests {
    private func episodeFields(
        _ key: String, section: Int = 1, guid: String? = "plex://episode/mmc-s2e21",
        lastViewedAt: Int? = nil, offset: Int = 0
    ) -> [String: Any] {
        var value: [String: Any] = [
            "ratingKey": key, "key": "/library/metadata/\(key)", "type": "episode",
            "title": "Goofy's Petting Zoo", "grandparentTitle": "Mickey Mouse Clubhouse",
            "parentIndex": 2, "index": 21, "librarySectionID": section,
            "librarySectionTitle": section == 1 ? "TV" : "Kids TV",
            "duration": 1_400_000, "viewOffset": offset,
        ]
        if let guid { value["guid"] = guid }
        if let lastViewedAt { value["lastViewedAt"] = lastViewedAt }
        return value
    }

    private func episode(
        _ key: String, section: Int = 1, guid: String? = "plex://episode/mmc-s2e21",
        lastViewedAt: Int? = nil, offset: Int = 0, server: String = "a"
    ) throws -> PlexItem {
        let value = episodeFields(key, section: section, guid: guid, lastViewedAt: lastViewedAt, offset: offset)
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = server
        return try decoder.decode(PlexItem.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test func singleServerContinueWatchingKeepsMostRecentlyWatchedCopy() throws {
        let tv = try episode("tv", lastViewedAt: 100, offset: 600_000)
        let kids = try episode("kids", section: 2, lastViewedAt: 200, offset: 300_000)
        let other = try episode("other", guid: "plex://episode/daniel-tiger-s4e13", lastViewedAt: 150)
        let merged = ContinueWatchingMerge.merge([[tv, other, kids]])
        #expect(merged.items.map(\.id) == [kids.id, other.id])
        #expect(merged.alternates[tv.contentKey] == [tv.id, kids.id])
    }

    @Test func sameLastViewedFallsBackToFurthestProgress() throws {
        let tv = try episode("tv", lastViewedAt: 100, offset: 600_000)
        let kids = try episode("kids", section: 2, lastViewedAt: 100, offset: 300_000)
        #expect(PlexItemMerge.interleave([[kids, tv]]).items.map(\.id) == [tv.id])
    }

    @Test func homeHubRowCollapsesSameServerCopies() throws {
        let tv = try episode("tv")
        let kids = try episode("kids", section: 2)
        let value: [String: Any] = [
            "title": "Continue Watching", "type": "mixed", "hubIdentifier": "home.continue",
            "key": "/hubs/home/continueWatching",
            "Metadata": [episodeFields("tv"), episodeFields("kids", section: 2)],
        ]
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "a"
        let hub = try decoder.decode(PlexHub.self, from: JSONSerialization.data(withJSONObject: value))
        let merged = HubMerge.merge([[hub]])
        #expect(merged.hubs.first?.items.map(\.id) == [tv.id])
        #expect(merged.alternates[tv.contentKey] == [tv.id, kids.id])
    }

    @Test func weakEpisodeIdentityNeverMergesWithinOneServer() throws {
        let tv = try episode("tv", guid: nil)
        let kids = try episode("kids", section: 2, guid: nil)
        #expect(PlexItemMerge.interleave([[tv, kids]]).items.count == 2)
        #expect(ContinueWatchingMerge.merge([[tv, kids]]).items.count == 2)
        #expect(ContinueWatchingMerge.merge([[tv, kids], []]).items.count == 2)
    }

    @Test func multiServerContinueWatchingCollapsesEveryCopy() throws {
        let tv = try episode("tv", lastViewedAt: 100)
        let kids = try episode("kids", section: 2, lastViewedAt: 300)
        let remote = try episode("remote", lastViewedAt: 200, server: "b")
        let merged = ContinueWatchingMerge.merge([[tv, kids], [remote]])
        #expect(merged.items.map(\.id) == [kids.id])
        #expect(merged.alternates[tv.contentKey] == [tv.id, kids.id, remote.id])
    }

    @Test func alternateIndexKeepsSameServerEpisodeCopies() throws {
        let tv = try episode("tv")
        let kids = try episode("kids", section: 2)
        let index = ContentAlternatesIndex()
        index.register([tv.id, kids.id], for: tv.contentKey)
        #expect(index.instances(of: kids.id) == [kids.id, tv.id])
    }
}
