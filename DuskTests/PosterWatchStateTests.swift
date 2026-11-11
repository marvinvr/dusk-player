import Foundation
import Testing
@testable import Dusk

/// What a poster card in a hub row or grid shows from the item's own Plex
/// watch state: the progress bar from `viewOffset`, the checkmark from
/// `viewCount` (or every episode watched for shows and seasons).
@Suite("Poster watch state")
struct PosterWatchStateTests {
    private func item(_ fields: [String: Any]) throws -> PlexItem {
        var json: [String: Any] = ["ratingKey": "1", "key": "/library/metadata/1", "title": "Item"]
        json.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "server"
        return try decoder.decode(PlexItem.self, from: data)
    }

    @Test("A partly watched clip gets a bar and no checkmark")
    func partlyWatchedClip() throws {
        let clip = try item(["type": "movie", "subtype": "clip", "duration": 600_000, "viewOffset": 150_000])
        #expect(clip.posterProgress == 0.25)
        #expect(!clip.posterIsWatched)
    }

    @Test("Watched movies, episodes and clips get the checkmark")
    func watchedLeaves() throws {
        for type in ["movie", "episode", "clip"] {
            let watched = try item(["type": type, "duration": 600_000, "viewCount": 1])
            #expect(watched.posterIsWatched, "\(type)")
            #expect(watched.posterProgress == nil, "\(type)")
        }
        #expect(!(try item(["type": "movie", "duration": 600_000])).posterIsWatched)
    }

    @Test("Shows and seasons only when every episode is watched")
    func showsAndSeasons() throws {
        #expect(try item(["type": "show", "leafCount": 6, "viewedLeafCount": 6]).posterIsWatched)
        #expect(!(try item(["type": "season", "leafCount": 6, "viewedLeafCount": 2])).posterIsWatched)
        #expect(!(try item(["type": "show", "leafCount": 0, "viewedLeafCount": 0])).posterIsWatched)
        #expect(!(try item(["type": "collection", "viewCount": 3])).posterIsWatched)
    }
}

/// Continue Watching hero and compact-row menus (`HomeItemContextMenu`).
@Suite("Continue Watching context menu")
@MainActor
struct ContinueWatchingMenuTests {
    private func item(_ fields: [String: Any]) throws -> PlexItem {
        var json: [String: Any] = ["ratingKey": "1", "key": "/library/metadata/1", "title": "Item"]
        json.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "server"
        return try decoder.decode(PlexItem.self, from: data)
    }

    private func menuTitles(for item: PlexItem) -> [String] {
        HomeItemContextMenu(
            item: item,
            detailsLabel: "Movie Details",
            onMarkWatched: {},
            onMarkUnwatched: {},
            onSelectRoute: { _ in },
            onRemoveFromContinueWatching: {}
        )
        .actions(playlistPresenter: nil)
        .map(\.title)
    }

    @Test("A rewatch in progress offers Mark Watched beside Mark Unwatched")
    func rewatchInProgress() throws {
        let movie = try item([
            "type": "movie",
            "duration": 8_520_000,
            "viewCount": 1,
            "viewOffset": 4_260_000,
        ])
        #expect(!movie.canMarkWatchedFromContextMenu)
        #expect(movie.canMarkWatchedFromContinueWatchingMenu)
        #expect(movie.canMarkUnwatchedFromContextMenu)

        let titles = menuTitles(for: movie)
        #expect(titles.first == "Mark Watched")
        #expect(titles.contains("Mark Unwatched"))
        #expect(titles.contains("Remove from Continue Watching"))

        let episode = try item([
            "type": "episode",
            "duration": 2_400_000,
            "viewCount": 2,
            "viewOffset": 600_000,
        ])
        #expect(menuTitles(for: episode).contains("Mark Watched"))
    }

    @Test("A first viewing and an unwatched next episode already offer Mark Watched")
    func firstViewingAndNextUp() throws {
        let inProgress = try item(["type": "movie", "duration": 6_000_000, "viewOffset": 1_000_000])
        #expect(inProgress.canMarkWatchedFromContextMenu)
        #expect(menuTitles(for: inProgress).contains("Mark Watched"))

        let nextUp = try item(["type": "episode", "duration": 2_400_000])
        #expect(nextUp.canMarkWatchedFromContinueWatchingMenu)
        #expect(menuTitles(for: nextUp).contains("Mark Watched"))
        #expect(!menuTitles(for: nextUp).contains("Mark Unwatched"))
    }

    @Test("A fully watched item with no progress stays off the poster rule")
    func fullyWatched() throws {
        let watched = try item(["type": "movie", "duration": 6_000_000, "viewCount": 1])
        #expect(!watched.canMarkWatchedFromContextMenu)
        #expect(!watched.canMarkWatchedFromContinueWatchingMenu)
        #expect(!menuTitles(for: watched).contains("Mark Watched"))
        #expect(menuTitles(for: watched).contains("Mark Unwatched"))
    }
}
