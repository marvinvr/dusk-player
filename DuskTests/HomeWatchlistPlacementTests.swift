import Foundation
import Testing
@testable import Dusk

@Suite("Home Watchlist row placement")
struct HomeWatchlistPlacementTests {
    @Test("Default: after the last Recently Added hub, or after the hubs when there are none")
    func defaultPlacement() throws {
        // Each library block leads with Recently Added; other hubs of that
        // library follow it. The row sits after the last of those.
        let hubs = try [
            hub("Recently Added Movies", identifier: "movie.recentlyadded.1"),
            hub("Recently Released", identifier: "movie.recentlyreleased.1"),
            hub("Recently Added TV", identifier: "tv.recentlyadded.2"),
            hub("On Deck", identifier: "tv.ondeck.2"),
        ]
        #expect(HomeWatchlistPlacement.index(in: hubs, plexHomeHubs: nil) == 3)
        #expect(HomeWatchlistPlacement.index(in: [], plexHomeHubs: nil) == 0)

        // plex-demo's /hubs: Recently Added rows keyed only by their paging URL.
        let pms = try [
            hub("Recently Added Movies", identifier: "home.movies.recent", key: "/hubs/home/recentlyAdded?type=1"),
            hub("Recently Added TV", identifier: "home.television.recent", key: "/hubs/home/recentlyAdded?type=2"),
            hub("Recently Added Photos", identifier: "home.photos.recent", key: "/hubs/home/recentlyAdded?type=13"),
        ]
        #expect(HomeWatchlistPlacement.index(in: pms, plexHomeHubs: nil) == 3)

        let noRecent = try [hub("Top Rated", identifier: "movie.toprated.1"), hub("Genres", identifier: "movie.genre.1")]
        #expect(HomeWatchlistPlacement.index(in: noRecent, plexHomeHubs: nil) == noRecent.count)

        // Below the old fourth-row cap, and not past the hubs that follow it.
        let late = try (0..<6).map { try hub("Row \($0)", identifier: "movie.curated.\($0)") }
            + [
                hub("Recently Added", identifier: "movie.recentlyadded.9"),
                hub("Top Rated", identifier: "movie.toprated.9"),
            ]
        #expect(HomeWatchlistPlacement.index(in: late, plexHomeHubs: nil) == 7)
    }

    @Test("Plex's customized layout places the row after its nearest shown predecessor")
    func plexLayout() throws {
        let hubs = try [
            hub("Recently Added Movies", identifier: "movie.recentlyadded.1"),
            hub("Recently Added TV", identifier: "tv.recentlyadded.2"),
            hub("Top Rated", identifier: "movie.toprated.1"),
        ]
        let layout = [
            PlexHomeHubSetting(hubIdentifier: "home.continue"),
            PlexHomeHubSetting(hubIdentifier: "tv.recentlyadded.2", machineIdentifier: "a"),
            PlexHomeHubSetting(hubIdentifier: "home.unknown.cloud"),
            PlexHomeHubSetting(hubIdentifier: "home.watchlist"),
            PlexHomeHubSetting(hubIdentifier: "movie.recentlyadded.1", machineIdentifier: "a"),
        ]
        #expect(HomeWatchlistPlacement.index(in: hubs, plexHomeHubs: layout) == 2)

        // Another server's row with the same identifier is not the anchor.
        let otherServer = [
            PlexHomeHubSetting(hubIdentifier: "tv.recentlyadded.2", machineIdentifier: "b"),
            PlexHomeHubSetting(hubIdentifier: "home.watchlist"),
        ]
        #expect(HomeWatchlistPlacement.index(in: hubs, plexHomeHubs: otherServer) == 0)

        let first = [PlexHomeHubSetting(hubIdentifier: "home.watchlist"), layout[1]]
        #expect(HomeWatchlistPlacement.index(in: hubs, plexHomeHubs: first) == 0)
    }

    @Test("Hidden in Plex is hidden here; absent from Plex's layout falls back to the default")
    func hiddenAndAbsent() throws {
        let hubs = try [
            hub("Recently Added Movies", identifier: "movie.recentlyadded.1"),
            hub("Top Rated", identifier: "movie.toprated.1"),
            hub("Recently Added TV", identifier: "tv.recentlyadded.2"),
        ]
        let hidden = [PlexHomeHubSetting(hubIdentifier: "home.watchlist", isHidden: true)]
        #expect(HomeWatchlistPlacement.index(in: hubs, plexHomeHubs: hidden) == nil)
        let absent = [PlexHomeHubSetting(hubIdentifier: "movie.toprated.1", machineIdentifier: "a")]
        #expect(HomeWatchlistPlacement.index(in: hubs, plexHomeHubs: absent) == 3)
    }

    @Test("Plex Web home hub entries decode from the experience blob")
    func hubSettingDecoding() throws {
        let raw = try #require(DuskJSONValue.decode(jsonString: """
        {"hubIdentifier":"movie.recentlyadded.1","isHidden":true,"server":{"machineIdentifier":"abc"}}
        """))
        let setting = try #require(PlexHomeHubSetting(raw: raw))
        #expect(setting == PlexHomeHubSetting(hubIdentifier: "movie.recentlyadded.1", machineIdentifier: "abc", isHidden: true))
        #expect(PlexHomeHubSetting(raw: .object([:])) == nil)
    }

    @Test("Only plex:// movies and shows can be watchlisted")
    func discoverRatingKey() {
        #expect(WatchlistEntry.discoverRatingKey(guid: "plex://movie/5d77688123d5a3001f4ed3df", type: .movie) == "5d77688123d5a3001f4ed3df")
        #expect(WatchlistEntry.discoverRatingKey(guid: "plex://show/abc", type: .show) == "abc")
        #expect(WatchlistEntry.discoverRatingKey(guid: "plex://episode/abc", type: .episode) == nil)
        #expect(WatchlistEntry.discoverRatingKey(guid: "local://12", type: .movie) == nil)
        #expect(WatchlistEntry.discoverRatingKey(guid: "com.plexapp.agents.imdb://tt1?lang=en", type: .movie) == nil)
        #expect(WatchlistEntry.discoverRatingKey(guid: "plex://show/abc", type: .movie) == nil)
    }

    private func hub(_ title: String, identifier: String, key: String = "/hubs/x", server: String = "a") throws -> HomeRow {
        let json: [String: Any] = ["title": title, "key": key, "type": "movie", "hubIdentifier": identifier, "Metadata": []]
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = server
        return try decoder.decode(HomeRow.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
