import Foundation
import Testing
@testable import Dusk

/// The Plex catalog's mapping of the neutral sorts and filters onto Plex's
/// query: the strings the library grid sent before the catalog facet
/// (P0-07) existed.
@MainActor
@Suite("Plex catalog query mapping")
struct PlexCatalogQueryTests {
    @Test("Every sort field keeps its Plex key, :desc when descending, random has none")
    func sortValues() {
        let keys: [LibrarySortField: String] = [
            .title: "titleSort",
            .releaseDate: "originallyAvailableAt",
            .year: "year",
            .addedAt: "addedAt",
            .lastEpisodeAdded: "episode.addedAt",
            .userRating: "userRating",
            .criticRating: "rating",
            .audienceRating: "audienceRating",
            .duration: "duration",
            .lastViewed: "lastViewedAt",
            .random: "random",
        ]
        #expect(Set(keys.keys) == Set(LibrarySortField.allCases))
        for (field, key) in keys {
            #expect(PlexCatalog.sortValue(LibrarySortOption(field, descending: false)) == key)
            let descending = field == .random ? key : "\(key):desc"
            #expect(PlexCatalog.sortValue(LibrarySortOption(field, descending: true)) == descending)
        }
        #expect(LibrarySortOption.titleDescending.plexValue == "titleSort:desc")
    }

    @Test("The sort menus are today's fixed lists")
    func sortFields() {
        let catalog = PlexCatalog(serverID: "s", transport: nil)
        for kind in [LibraryKind.movie, .show, .video, nil] {
            #expect(catalog.sortFields(for: kind) == LibrarySortField.fields(for: kind))
        }
    }

    @Test("Watch state: shows filter their episodes and have no in-progress filter")
    func watchStatus() {
        func filters(_ status: LibraryWatchStatus, _ kind: LibraryKind?) -> [String: String] {
            PlexCatalog.queryFilters(LibraryFilter(watchStatus: status), kind: kind)
        }
        #expect(filters(.all, .movie).isEmpty)
        #expect(filters(.unwatched, .movie) == ["unwatched": "1"])
        #expect(filters(.watched, .movie) == ["unwatched": "0"])
        #expect(filters(.inProgress, .movie) == ["inProgress": "1"])
        #expect(filters(.unwatched, .video) == ["unwatched": "1"])
        #expect(filters(.unwatched, .show) == ["unwatchedLeaves": "1"])
        #expect(filters(.watched, .show) == ["unwatchedLeaves": "0"])
        #expect(filters(.inProgress, .show).isEmpty)
    }

    @Test("Collection, genre, picked values, toggles and folding")
    func combinedFilters() {
        let filter = LibraryFilter(
            collectionID: "9",
            genre: "18",
            watchStatus: .unwatched,
            choices: ["decade": "1990", "contentRating": "Not Rated"],
            toggles: ["hdr"],
            foldsCollections: true
        )
        #expect(PlexCatalog.queryFilters(filter, kind: .movie) == [
            "collection": "9",
            "genre": "18",
            "unwatched": "1",
            "decade": "1990",
            "contentRating": "Not Rated",
            "hdr": "1",
            "includeCollections": "1",
        ])
        #expect(PlexCatalog.queryFilters(LibraryFilter(), kind: .movie).isEmpty)
    }

    @Test("A picked collection value wins over the channel collection")
    func pickedCollectionWins() {
        let filter = LibraryFilter(collectionID: "channel", choices: ["collection": "picked"])
        #expect(PlexCatalog.queryFilters(filter, kind: .movie)["collection"] == "picked")
    }

    @Test("Filter parameters go out in key order")
    func sortedQueryItems() {
        let items = PlexCatalog.sortedQueryItems(["unwatched": "1", "collection": "9", "genre": "18"])
        #expect(items.map(\.name) == ["collection", "genre", "unwatched"])
    }

    @Test("Offered fields: sheet order, boolean rows toggle, collection only when asked")
    func filterFields() {
        let rows = [
            PlexLibraryFilter(filter: "hdr", filterType: "boolean", key: "/library/sections/1/hdr", title: "HDR", type: "filter"),
            PlexLibraryFilter(filter: "collection", filterType: "string", key: "/library/sections/1/collection", title: "Collection", type: "filter"),
            PlexLibraryFilter(filter: "decade", filterType: "integer", key: "/library/sections/1/decade", title: "Decade", type: "filter"),
            PlexLibraryFilter(filter: "genre", filterType: "string", key: "/library/sections/1/genre", title: "Genre", type: "filter"),
        ]
        let fields = PlexCatalog.filterFields(from: rows, includesCollection: true)
        #expect(fields.map(\.parameter) == ["decade", "hdr", "collection"])
        #expect(fields[0].kind == .values(source: "/library/sections/1/decade"))
        #expect(fields[1].kind == .toggle)
        #expect(PlexCatalog.filterFields(from: rows, includesCollection: false).map(\.parameter) == ["decade", "hdr"])
    }

    @Test("Percent-encoded value keys are decoded once")
    func filterChoice() {
        let choice = PlexCatalog.filterChoice(PlexLibraryFilterValue(key: "Not%20Rated", title: "Not Rated", type: nil))
        #expect(choice.value == "Not Rated")
        #expect(choice.title == "Not Rated")
    }

    @Test("Collection mode pref values")
    func collectionModes() {
        #expect(PlexCatalog.collectionMode(prefValue: "0") == .disabled)
        #expect(PlexCatalog.collectionMode(prefValue: "1") == .hideItems)
        #expect(PlexCatalog.collectionMode(prefValue: "2") == .showItems)
        #expect(PlexCatalog.collectionMode(prefValue: "3") == nil)
    }
}
