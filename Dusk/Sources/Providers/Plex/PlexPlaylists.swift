import Foundation

/// Plex's `PlaylistProviding`. Empty until P0-13 moves the Plex calls here.
struct PlexPlaylists: PlaylistProviding {
    let client: PlexClient
}

extension PlexServerProvider {
    var playlists: any PlaylistProviding { PlexPlaylists(client: client) }
}
