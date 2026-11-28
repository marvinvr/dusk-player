import Foundation

/// Plex's `PlaybackProviding`. Empty until P0-09 moves the Plex calls here.
struct PlexPlayback: PlaybackProviding {
    let client: PlexClient
}

extension PlexServerProvider {
    var playback: any PlaybackProviding { PlexPlayback(client: client) }
}
