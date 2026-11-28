import Foundation
import Testing
@testable import Dusk

@Suite("Home hub library order")
struct HomeHubArrangementTests {
    private let order = ["a|2", "a|1", "b|1"]

    @Test("Unscoped Recently Added Movies follows TV-first Library Order")
    func itemSectionFallback() throws {
        let movies = try hub("movies", items: [item(section: 1)])
        let tv = try hub("tv", section: 2)
        let global = try hub("continue", identifier: "home.continue", items: [item(section: 1)])
        let result = HomeHubArrangement.arrange(hubs: [movies, global, tv], libraryOrder: order)
        #expect(result.map(\.title) == ["continue", "tv", "movies"])
        #expect(result.last == movies) // The row and paging sources are preserved.
    }

    @Test("Section metadata, paging paths and identifier suffixes resolve library rows")
    func sectionSources() throws {
        let tv = try hub("tv", section: "2")
        for movies in [
            try hub("movies", section: 1),
            try hub("movies", identifier: "movie.recentlyadded.1"),
            try hub("movies", key: "/library/sections/1/recentlyAdded"),
            try hub("movies", key: "/hubs/sections/1/recentlyAdded"),
            try hub("movies", key: "/hubs/recentlyAdded?librarySectionID=1"),
            try hub("movies", key: "/hubs/recentlyAdded?sectionID=1")
        ] {
            #expect(HomeHubArrangement.arrange(hubs: [movies, tv], libraryOrder: order).map(\.title) == ["tv", "movies"])
        }
    }

    @Test("Missing item metadata can use a unique library, never an ambiguous one")
    func uniqueTypeFallback() throws {
        let movies = try hub("movies")
        let tv = try hub("tv", section: 2)
        let library = try library("1", type: "movie")
        #expect(HomeHubArrangement.arrange(hubs: [movies, tv], libraryOrder: order, libraries: [library]).map(\.title) == ["tv", "movies"])
        let second = try self.library("3", type: "movie")
        #expect(HomeHubArrangement.arrange(hubs: [movies, tv], libraryOrder: order, libraries: [library, second]).map(\.title) == ["movies", "tv"])
    }

    @Test("Mixed global hubs and rows spanning sections stay global")
    func ambiguousAndGlobalRows() throws {
        let mixed = try hub("mixed", type: "mixed", items: [item(section: 1)])
        let global = try hub("global", identifier: "home.recentlyplayed", key: "/hubs/home/recentlyPlayed", items: [item(section: 1)])
        let spanning = try hub("spanning", items: [item(section: 1), item(section: 2)])
        let unknown = try hub("unknown", section: 99)
        let tv = try hub("tv", section: 2)
        #expect(HomeHubArrangement.arrange(hubs: [unknown, global, mixed, spanning, tv], libraryOrder: order).map(\.title) == ["global", "mixed", "spanning", "tv", "unknown"])
    }

    @Test("Section keys cannot alias between servers; order within a block is stable")
    func serverIdentityAndStableBlocks() throws {
        let b = try hub("b", section: 1, server: "b")
        let a1 = try hub("a1", section: 1)
        let a2 = try hub("a2", section: 1)
        let tv = try hub("tv", section: 2)
        let hubs = [b, a1, tv, a2]
        #expect(HomeHubArrangement.arrange(hubs: hubs, libraryOrder: order).map(\.title) == ["tv", "a1", "a2", "b"])
        #expect(HomeHubArrangement.arrange(hubs: hubs, libraryOrder: []) == hubs)
    }

    @Test("Merged rows use the representative server's item sections")
    func mergedRepresentative() throws {
        let a = try hub("movies", items: [item(section: "1")])
        let b = try hub("movies", items: [item(section: 7)], server: "b")
        let merged = a.merged(items: a.items + b.items, sources: a.sources + b.sources)
        let tv = try hub("tv", section: 2)
        #expect(merged.serverID == nil)
        #expect(HomeHubArrangement.arrange(hubs: [merged, tv], libraryOrder: order).map(\.title) == ["tv", "movies"])
    }

    @Test("Per-library rows with one title fold into the first copy")
    func repeatedTitlesCollapse() throws {
        let horror = { (section: Int, server: String, titles: [String]) in
            try self.hub("Oh, the Horror!", section: section, identifier: "movie.curated.\(section)",
                         items: titles.map { self.item(section: section, title: $0) }, server: server)
        }
        let recent = try hub("Recently Added in Movies", section: 1)
        let hubs = [
            recent,
            try horror(1, "a", ["Alien", "Scream"]),
            try horror(3, "a", ["Halloween", "Alien", "It"]),
            try horror(1, "b", ["The Thing"]),
        ]
        let collapsed = HubMerge.collapsingRepeatedTitles(hubs).hubs
        #expect(collapsed.map(\.title) == ["Recently Added in Movies", "Oh, the Horror!"])
        #expect(collapsed[0] == recent)
        #expect(collapsed[1].sources.count == 3)
        #expect(collapsed[1].items.map(\.title) == ["Alien", "Halloween", "The Thing"])
        #expect(collapsed[1].representativeLibraryID == "a|1")
        #expect(HubMerge.collapsingRepeatedTitles([recent]).hubs == [recent])
    }

    private func item(section: Any, title: String = "Movie") -> [String: Any] {
        ["ratingKey": UUID().uuidString, "key": "/library/metadata/1", "type": "movie", "title": title, "librarySectionID": section]
    }

    private func hub(
        _ title: String, section: Any? = nil, identifier: String = "movie.recentlyadded",
        key: String = "/hubs/recentlyAdded", type: String = "movie",
        items: [[String: Any]] = [], server: String = "a"
    ) throws -> HomeRow {
        var json: [String: Any] = ["title": title, "key": key, "type": type, "hubIdentifier": identifier, "Metadata": items]
        json["librarySectionID"] = section
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = server
        return try decoder.decode(HomeRow.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func library(_ key: String, type: String) throws -> Library {
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "a"
        return try decoder.decode(Library.self, from: JSONSerialization.data(withJSONObject: ["key": key, "title": key, "type": type]))
    }
}
