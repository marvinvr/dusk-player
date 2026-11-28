import Foundation
import Testing
@testable import Dusk

/// Pins how Home reads Plex's `/hubs` rows (which row is hidden, which library
/// it belongs to, which rows merge across servers) on payloads in the shape
/// PMS sends, so moving those string rules into the Plex mapper (P0-12,
/// docs/jellyfin/05-plan.md) cannot move a row.
///
/// Fixtures in `DuskTests/Fixtures/Plex`: `plex-hubs-home-a` / `-b` are
/// `GET /hubs` of two servers, `plex-hubs-section-1` is
/// `GET /hubs/sections/1`. They cover the identifier families the rules key
/// on: `home.*` account rows, `<type>.recentlyadded.<section>`, older servers
/// that put the section only in the key, curated and collection rows, a row
/// with no identifier, and a row with no section anywhere but its suffix.
@Suite("Plex /hubs fixtures")
struct PlexHubFixtureTests {
    private struct Expectation {
        let title: String
        let hidden: Bool
        let section: String?
        let homeKey: String
        let typeKey: String
    }

    @Test("Each Home row keeps its filter, section and merge key")
    func homeRowClassification() throws {
        let rows = try Self.rows("home-a", server: "a")
        let expected: [Expectation] = [
            .init(title: "Continue Watching", hidden: true, section: nil,
                  homeKey: "id:home.continue|mixed|global", typeKey: "id:home.continue|mixed"),
            .init(title: "On Deck", hidden: true, section: nil,
                  homeKey: "id:home.ondeck|mixed|global", typeKey: "id:home.ondeck|mixed"),
            .init(title: "Recently Added Movies", hidden: false, section: nil,
                  homeKey: "id:home.movies.recent|movie|global", typeKey: "id:home.movies.recent|movie"),
            .init(title: "Recently Added in Movies", hidden: false, section: "1",
                  homeKey: "id:movie.recentlyadded|movie|library:movies", typeKey: "id:movie.recentlyadded|movie"),
            .init(title: "Recently Added in TV Shows", hidden: false, section: "2",
                  homeKey: "id:tv.recentlyadded|season|library:tvshows", typeKey: "id:tv.recentlyadded|season"),
            .init(title: "Oh, the Horror!", hidden: false, section: "1",
                  homeKey: "id:movie.curated.1|movie|library:movies", typeKey: "id:movie.curated.1|movie"),
            .init(title: "Marvel", hidden: false, section: "1",
                  homeKey: "id:custom.collection.1.99487|movie|library:movies", typeKey: "id:custom.collection.1.99487|movie"),
            .init(title: "Recent Playlists", hidden: true, section: nil,
                  homeKey: "id:home.playlists|playlist|global", typeKey: "id:home.playlists|playlist"),
            .init(title: "Top Rated", hidden: false, section: "3",
                  homeKey: "id:movie.toprated|movie|section:a|3", typeKey: "id:movie.toprated|movie"),
            .init(title: "Featured", hidden: false, section: nil,
                  homeKey: "title:featured|movie|global", typeKey: "title:featured|movie"),
            .init(title: "Continue Watching", hidden: true, section: "1",
                  homeKey: "id:movie.inprogress|movie|library:movies", typeKey: "id:movie.inprogress|movie"),
        ]

        #expect(rows.map(\.title) == expected.map(\.title))
        for (row, expectation) in zip(rows, expected) {
            #expect(HomeHubFilter.shouldHide(hub: row) == expectation.hidden, "\(row.title) hidden")
            #expect(row.resolvedLibrarySectionID == expectation.section, "\(row.title) section")
            #expect(row.representativeLibraryID == expectation.section.map { "a|\($0)" }, "\(row.title) library")
            #expect(HubMerge.mergeKey(for: row, mode: .home) == expectation.homeKey, "\(row.title) home key")
            #expect(HubMerge.mergeKey(for: row, mode: .libraryType) == expectation.typeKey, "\(row.title) type key")
            #expect(row.sources.map(\.serverID) == ["a"])
            #expect(row.sources.first?.hubIdentifier == row.hubIdentifier)
        }
    }

    @Test("The mapper classifies each row the way Home's string rules did")
    func mapperClassification() throws {
        let rows = try Self.rows("home-a", server: "a")
        #expect(rows.map(\.kind) == [
            .continueWatching, .nextUp, .recentlyAdded, .recentlyAdded, .recentlyAdded,
            .other, .other, .playlists, .other, .other, .continueWatching,
        ])
        #expect(rows.map(\.canHide) == [false, false, false, true, true, true, true, false, true, false, true])
        #expect(rows.map(\.libraryScope) == [
            .global, .global, .unresolved(recentlyAddedKind: .movie), .section("1"), .section("2"),
            .section("1"), .section("1"), .global, .section("3"), .global, .section("1"),
        ])

        let section = try Self.rows("section-1", server: "a")
        #expect(section.map(\.kind) == [.continueWatching, .recentlyAdded, .other, .other, .other])
        #expect(section.map(\.canHide) == [true, true, true, true, false])
    }

    @Test("Visible rows follow the library order, unscoped rows by their items")
    func homeArrangement() throws {
        let rows = try Self.rows("home-a", server: "a").filter { !HomeHubFilter.shouldHide(hub: $0) }
        let arranged = HomeHubArrangement.arrange(hubs: rows, libraryOrder: ["a|2", "a|1", "a|3"])
        #expect(arranged.map(\.title) == [
            "Featured",
            "Recently Added in TV Shows",
            "Recently Added Movies",
            "Recently Added in Movies",
            "Oh, the Horror!",
            "Marvel",
            "Top Rated",
        ])
    }

    @Test("Two servers merge the same library's rows, then fold repeated titles")
    func twoServerHome() throws {
        let a = try Self.rows("home-a", server: "a").filter { !HomeHubFilter.shouldHide(hub: $0) }
        let b = try Self.rows("home-b", server: "b").filter { !HomeHubFilter.shouldHide(hub: $0) }
        #expect(b.map(\.title) == ["Recently Added in Movies", "Recently Added in Films", "Oh, the Horror!"])

        let merged = HubMerge.merge([a, b]).hubs
        #expect(merged.map(\.title) == [
            "Recently Added Movies",
            "Recently Added in Movies",
            "Recently Added in TV Shows",
            "Oh, the Horror!",
            "Marvel",
            "Top Rated",
            "Featured",
            "Recently Added in Films",
            "Oh, the Horror!",
        ])
        let movies = try #require(merged.first { $0.title == "Recently Added in Movies" })
        #expect(movies.id == "id:movie.recentlyadded|movie|library:movies")
        #expect(movies.serverID == nil)
        #expect(movies.sources.map(\.serverID) == ["a", "b"])
        #expect(movies.sources.map(\.hubIdentifier) == ["movie.recentlyadded.1", "movie.recentlyadded.4"])
        #expect(movies.items.map(\.title) == ["Elephants Dream", "Dune: Part Two", "Paddington 2"])

        let collapsed = HubMerge.collapsingRepeatedTitles(merged).hubs
        #expect(collapsed.count == 8)
        let horror = try #require(collapsed.first { $0.title == "Oh, the Horror!" })
        #expect(horror.id == "title:ohthehorror")
        #expect(horror.sources.map(\.serverID) == ["a", "b"])
        #expect(horror.representativeLibraryID == "a|1")

        let arranged = HomeHubArrangement.arrange(
            hubs: collapsed,
            libraryOrder: ["b|4", "a|2", "a|1", "b|5", "a|3"]
        )
        #expect(arranged.map(\.title) == [
            "Featured",
            "Recently Added in TV Shows",
            "Recently Added Movies",
            "Recently Added in Movies",
            "Oh, the Horror!",
            "Marvel",
            "Recently Added in Films",
            "Top Rated",
        ])
    }

    @Test("A library's rows merge across libraries by kind")
    func libraryTypeMerge() throws {
        let a = try Self.rows("section-1", server: "a")
        let b = try Self.rows("section-1", server: "b")
        #expect(a.map { HubMerge.mergeKey(for: $0, mode: .libraryType) } == [
            "id:movie.inprogress|movie",
            "id:movie.recentlyadded|movie",
            "id:movie.recentlyreleased|movie",
            "id:movie.toprated|movie",
            "title:thrillers|movie",
        ])
        #expect(a.map(\.resolvedLibrarySectionID) == ["1", "1", "1", "1", "1"])
        #expect(a.map { HomeHubFilter.shouldHide(hub: $0) } == [true, false, false, false, false])

        let merged = HubMerge.merge([a, b], mode: .libraryType).hubs
        #expect(merged.map(\.title) == ["Continue Watching", "Recently Added", "Recently Released", "Top Rated", "Thrillers"])
        #expect(merged.allSatisfy { $0.sources.map(\.serverID) == ["a", "b"] })
    }

    // MARK: - Fixtures

    private final class BundleToken {}

    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Plex", isDirectory: true)

    /// `MediaContainer.Hub` of `plex-hubs-<name>.json`, mapped onto `server`
    /// the way `MediaService+Hubs` maps a live response.
    private static func rows(_ name: String, server: String) throws -> [HomeRow] {
        let file = "plex-hubs-\(name)"
        let url = Bundle(for: BundleToken.self).url(forResource: file, withExtension: "json")
            ?? directory.appendingPathComponent("\(file).json")
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = server
        let response = try decoder.decode(PlexHubResponseDTO.self, from: Data(contentsOf: url))
        return (response.MediaContainer.Hub ?? []).map { PlexItemMapper.map($0, serverID: server) }
    }
}
