import Foundation
import Testing
@testable import Dusk

@Suite("Recently Added Movies ordering")
struct RecentlyAddedMoviesTests {
    private func hub(
        section: Int,
        server: String = "server",
        type: String = "movie",
        kind: String = "recentlyadded",
        items: [[String: Any]]
    ) throws -> PlexHub {
        let data = try JSONSerialization.data(withJSONObject: [
            "title": kind == "recentlyadded" ? "Recently Added Movies" : "Popular Movies",
            "type": type,
            "hubIdentifier": "\(type).\(kind).\(section)",
            "librarySectionID": section,
            "librarySectionTitle": "Movies",
            "key": "/library/sections/\(section)/all?sort=addedAt:desc",
            "Metadata": items,
        ])
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = server
        return try decoder.decode(PlexHub.self, from: data)
    }

    private func movie(_ key: String, addedAt: Int? = nil, guid: String? = nil) -> [String: Any] {
        var item: [String: Any] = [
            "ratingKey": key, "key": "/library/metadata/\(key)",
            "title": key, "type": "movie", "guid": guid ?? "plex://movie/\(key)",
            // Deliberately unrelated: ordering must use addedAt alone.
            "updatedAt": 999_999, "originallyAvailableAt": "2026-10-22",
        ]
        if let addedAt { item["addedAt"] = addedAt }
        return item
    }

    @Test func libraryAndHomeMergesUseOneTimeline() throws {
        let first = try hub(section: 1, items: [movie("new", addedAt: 500), movie("next", addedAt: 400)])
        let second = try hub(section: 2, items: [movie("old", addedAt: 100)])
        let third = try hub(section: 3, items: [movie("ancient", addedAt: 10)])

        // Same-server libraries, including the /hubs/promoted first-paint path.
        let libraries = HubMerge.merge([[first], [second], [third]], mode: .libraryType)
        #expect(libraries.hubs.first?.items.map(\.ratingKey) == ["new", "next", "old", "ancient"])

        let remote = try hub(section: 2, server: "remote", items: second.items.map {
            movie($0.ratingKey, addedAt: $0.addedAt)
        })
        let home = HubMerge.merge([[first], [remote]])
        #expect(home.hubs.first?.items.map(\.ratingKey) == ["new", "next", "old"])
    }

    @Test func repeatedTitlesSortBeforeApplyingRowLimit() throws {
        let first = try hub(section: 1, items: [movie("new", addedAt: 500), movie("next", addedAt: 400)])
        let second = try hub(section: 2, items: [movie("old", addedAt: 100), movie("ancient", addedAt: 10)])
        let folded = HubMerge.collapsingRepeatedTitles([first, second])
        #expect(folded.hubs.first?.items.map(\.ratingKey) == ["new", "next"])
        #expect(folded.hubs.first?.sources.count == 2)
    }

    @Test func expandedItemsUseNewestCopyAndKeepPlaybackAlternates() throws {
        let first = try hub(section: 1, items: [movie("old-copy", addedAt: 100, guid: "plex://movie/shared")])
        let second = try hub(section: 2, server: "remote", items: [
            movie("new-copy", addedAt: 500, guid: "plex://movie/shared"),
            movie("other", addedAt: 400),
        ])
        // Same merge used by inline expansion and Show All after fetching sources.
        let merged = PlexItemMerge.hubItems([first.items, second.items], for: first)
        #expect(merged.items.map(\.ratingKey) == ["new-copy", "other"])
        #expect(merged.alternates[first.items[0].contentKey] == [first.items[0].id, second.items[0].id])
    }

    @Test func equalAndMissingDatesKeepSourceOrder() throws {
        let first = try hub(section: 1, items: [movie("a", addedAt: 100), movie("b", addedAt: 100), movie("missing-a")])
        let second = try hub(section: 2, items: [movie("c", addedAt: 100), movie("missing-b")])
        let merged = PlexItemMerge.hubItems([first.items, second.items], for: first)
        #expect(merged.items.map(\.ratingKey) == ["a", "b", "c", "missing-a", "missing-b"])
    }

    @Test func singleSourceKeepsPlexOrderAndDistinctCopies() throws {
        let source = try hub(section: 1, items: [
            movie("a", addedAt: 100, guid: "plex://movie/shared"),
            movie("b", addedAt: 100, guid: "plex://movie/shared"),
        ])
        #expect(PlexItemMerge.hubItems([source.items], for: source).items == source.items)
    }

    @Test func otherHubsRetainInterleaving() throws {
        let first = try hub(section: 1, items: [movie("a", addedAt: 500), movie("b", addedAt: 400)])
        let second = try hub(section: 2, items: [movie("c", addedAt: 100)])
        let popular = try hub(section: 1, kind: "popular", items: [])
        let tv = try hub(section: 1, type: "show", items: [])
        for row in [popular, tv] {
            #expect(PlexItemMerge.hubItems([first.items, second.items], for: row).items.map(\.ratingKey) == ["a", "c", "b"])
        }
    }
}
