import Foundation
import Testing
@testable import Dusk

/// Collection page sorting: the device-side order used when a server ignores
/// `sort=`, the check that decides that, and the per-collection memory.
@Suite("Collection sort")
struct CollectionSortTests {
    private func movie(
        _ key: String,
        title: String,
        date: String? = nil,
        year: Int? = nil,
        addedAt: Int? = nil,
        rating: Double? = nil
    ) throws -> PlexItem {
        var value: [String: Any] = [
            "ratingKey": key, "key": "/library/metadata/\(key)", "type": "movie", "title": title,
        ]
        if let date { value["originallyAvailableAt"] = date }
        if let year { value["year"] = year }
        if let addedAt { value["addedAt"] = addedAt }
        if let rating { value["rating"] = rating }
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "a"
        return try decoder.decode(PlexItem.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test("Release date sorts newest first; titles without a date go last")
    func releaseDateNewestFirst() throws {
        let items = [
            try movie("1", title: "Snow White", date: "1937-12-21"),
            try movie("2", title: "Unknown"),
            try movie("3", title: "Frozen", date: "2013-11-27"),
            try movie("4", title: "Encanto", year: 2021),
        ]
        let sorted = CollectionSort.sorted(items, by: LibrarySortOption(.releaseDate, descending: true))
        #expect(sorted.map(\.ratingKey) == ["4", "3", "1", "2"])

        let oldest = CollectionSort.sorted(items, by: LibrarySortOption(.releaseDate, descending: false))
        #expect(oldest.map(\.ratingKey) == ["1", "3", "4", "2"])
    }

    @Test("Titles sort without a leading article, ignoring case and accents")
    func titleIgnoresArticles() throws {
        let items = [
            try movie("1", title: "The Incredibles"),
            try movie("2", title: "Cars"),
            try movie("3", title: "Élémental"),
            try movie("4", title: "A Bug's Life"),
        ]
        let sorted = CollectionSort.sorted(items, by: .titleAscending)
        #expect(sorted.map(\.ratingKey) == ["4", "2", "3", "1"])
    }

    @Test("Equal values keep the collection's order")
    func tiesKeepCollectionOrder() throws {
        let items = [
            try movie("1", title: "B", rating: 7),
            try movie("2", title: "A", rating: 7),
            try movie("3", title: "C", rating: 9),
        ]
        let sorted = CollectionSort.sorted(items, by: LibrarySortOption(.criticRating))
        #expect(sorted.map(\.ratingKey) == ["3", "1", "2"])
    }

    @Test("A page in the requested order counts as sorted by the server")
    func detectsServerOrder() throws {
        let newestFirst = try (0..<10).map { try movie("\($0)", title: "M\($0)", year: 2020 - $0) }
        #expect(CollectionSort.follows(newestFirst, sort: LibrarySortOption(.releaseDate, descending: true)))
        // The same page is out of order for Oldest First: the server ignored it.
        #expect(!CollectionSort.follows(newestFirst, sort: LibrarySortOption(.releaseDate, descending: false)))
    }

    @Test("A single inversion among many titles is tolerated")
    func toleratesCollationDifferences() throws {
        var titles = (0..<20).map { String(format: "Title %02d", $0) }
        titles.swapAt(4, 5)
        let items = try titles.enumerated().map { try movie("\($0.offset)", title: $0.element) }
        #expect(CollectionSort.follows(items, sort: .titleAscending))
    }

    @Test("Remembered per collection; Collection Order clears it")
    func persistsPerCollection() throws {
        let suiteName = "CollectionSortTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CollectionSortStore(defaults: defaults)
        let disney = PlexItemID(serverID: "a", ratingKey: "100")
        #expect(store.sort(for: disney) == nil)

        let newest = LibrarySortOption(.releaseDate, descending: true)
        store.setSort(newest, for: disney)
        #expect(CollectionSortStore(defaults: defaults).sort(for: disney) == newest)
        // The same rating key on another server is another collection.
        #expect(store.sort(for: PlexItemID(serverID: "b", ratingKey: "100")) == nil)

        store.setSort(nil, for: disney)
        #expect(store.sort(for: disney) == nil)
        #expect(defaults.object(forKey: CollectionSortStore.key(for: disney)) == nil)
    }

    @Test("Clip collections only offer date and title sorts")
    func clipFields() {
        #expect(CollectionSort.fields(forSubtype: "clip") == [.releaseDate, .addedAt, .title])
        #expect(CollectionSort.fields(forSubtype: "movie").contains(.criticRating))
    }
}
