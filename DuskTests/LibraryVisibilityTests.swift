import Foundation
import Testing
@testable import Dusk

/// The server-side per-library Visibility (`hidden` on `/library/sections`)
/// and how it scopes `HiddenLibraryFilter`.
@Suite("Server library visibility")
struct LibraryVisibilityTests {
    @Test("hidden decodes to visibility, leniently")
    func decoding() throws {
        #expect(try library("1").visibility == .included)
        #expect(try library("1", hidden: 0).visibility == .included)
        #expect(try library("1", hidden: 1).visibility == .excludedFromHome)
        #expect(try library("1", hidden: 2).visibility == .excludedFromHomeAndSearch)
        #expect(try library("1", hidden: "2").visibility == .excludedFromHomeAndSearch)
        #expect(try library("1", hidden: true).visibility == .excludedFromHome)
        #expect(try library("1", hidden: 7).visibility == .included)
        #expect(try library("1", hidden: "junk").visibility == .included)
    }

    @Test("Visibility survives an encode/decode round trip")
    func roundTrip() throws {
        let original = try library("3", hidden: 2)
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "a"
        let decoded = try decoder.decode(Library.self, from: JSONEncoder().encode(original))
        #expect(decoded.visibility == .excludedFromHomeAndSearch)
    }

    @Test("Scopes: exclude-from-home leaves Home, exclude-from-search also leaves search")
    func scopes() throws {
        let sections = [
            try library("1"),
            try library("2", hidden: 1),
            try library("3", hidden: 2),
        ]
        let account: Set<String> = ["a|9"]

        let everywhere = HiddenLibraryFilter(accountHiddenIDs: account, sections: sections, scope: .everywhere)
        let home = HiddenLibraryFilter(accountHiddenIDs: account, sections: sections, scope: .home)
        let search = HiddenLibraryFilter(accountHiddenIDs: account, sections: sections, scope: .search)

        // The library itself stays listed and browsable.
        #expect(everywhere.hiddenLibraryIDs == ["a|9"])
        #expect(home.hiddenLibraryIDs == ["a|9", "a|2", "a|3"])
        #expect(search.hiddenLibraryIDs == ["a|9", "a|3"])
    }

    @Test("Home filter drops excluded libraries' rows and their titles in global rows")
    func homeHubs() throws {
        let sections = [try library("1"), try library("2", hidden: 1)]
        let home = HiddenLibraryFilter(accountHiddenIDs: [], sections: sections, scope: .home)

        let libraryRow = try hub("Recently Added in Kids", section: "2", items: [item(section: 2)])
        let globalRow = try hub(
            "Continue Watching", identifier: "home.continue", key: "/hubs/home/continueWatching",
            items: [item(section: 1, title: "Kept"), item(section: 2, title: "Dropped")]
        )
        let onlyExcluded = try hub(
            "On Deck", identifier: "home.ondeck", key: "/hubs/home/onDeck",
            items: [item(section: 2)]
        )

        let filtered = home.filtering([libraryRow, globalRow, onlyExcluded])
        #expect(filtered.map(\.title) == ["Continue Watching"])
        #expect(filtered.first?.items.map(\.title) == ["Kept"])
    }

    @Test("Search filter keeps exclude-from-home titles, drops exclude-from-search ones")
    func searchItems() throws {
        let sections = [try library("2", hidden: 1), try library("3", hidden: 2)]
        let search = HiddenLibraryFilter(accountHiddenIDs: [], sections: sections, scope: .search)
        let items = try [item(section: 2, title: "Home only"), item(section: 3, title: "Search too")]
            .map(decodeItem)
        #expect(search.filtering(items).map(\.title) == ["Home only"])
    }

    @Test("Another server's same section key is not excluded")
    func perServer() throws {
        let sections = [try library("2", hidden: 2)]
        let home = HiddenLibraryFilter(accountHiddenIDs: [], sections: sections, scope: .home)
        #expect(home.hides(serverID: "a", librarySectionID: "2"))
        #expect(!home.hides(serverID: "b", librarySectionID: "2"))
    }

    // MARK: - Fixtures

    private func library(_ key: String, hidden: Any? = nil, server: String = "a") throws -> Library {
        var json: [String: Any] = ["key": key, "title": "Library \(key)", "type": "movie"]
        json["hidden"] = hidden
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = server
        return try decoder.decode(Library.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func item(section: Int, title: String = "Movie") -> [String: Any] {
        ["ratingKey": UUID().uuidString, "key": "/library/metadata/1", "type": "movie", "title": title, "librarySectionID": section]
    }

    private func decodeItem(_ json: [String: Any]) throws -> MediaItem {
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "a"
        return try decoder.decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func hub(
        _ title: String, section: String? = nil, identifier: String = "movie.recentlyadded",
        key: String = "/hubs/recentlyAdded", items: [[String: Any]]
    ) throws -> HomeRow {
        var json: [String: Any] = ["title": title, "key": key, "type": "movie", "hubIdentifier": identifier, "Metadata": items]
        json["librarySectionID"] = section
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "a"
        return try decoder.decode(HomeRow.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
