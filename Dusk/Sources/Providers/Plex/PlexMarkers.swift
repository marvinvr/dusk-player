import Foundation

/// Plex's `MarkerProviding`. Empty until P0-11 moves the Plex calls here.
struct PlexMarkers: MarkerProviding {
    let client: PlexClient
}

extension PlexServerProvider {
    var markers: any MarkerProviding { PlexMarkers(client: client) }
}
