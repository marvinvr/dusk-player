import Foundation

/// Plex's `LiveTVProviding`. Empty until P0-14 moves the Plex calls here.
struct PlexLiveTV: LiveTVProviding {
    let client: PlexClient
}

extension PlexServerProvider {
    var liveTV: (any LiveTVProviding)? { PlexLiveTV(client: client) }
}
