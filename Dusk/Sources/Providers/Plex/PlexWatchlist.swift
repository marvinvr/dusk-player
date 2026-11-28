import Foundation

/// Plex's `WatchlistProviding`. Empty until P0-17 moves the Plex calls here.
struct PlexWatchlist: WatchlistProviding {
    let client: PlexClient
}

extension PlexAccountProvider {
    var watchlist: (any WatchlistProviding)? { PlexWatchlist(client: client) }
}
