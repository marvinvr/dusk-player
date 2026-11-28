import Foundation

/// Plex's `HomeProviding`. Empty until P0-12 moves the Plex calls here.
struct PlexHomeRows: HomeProviding {
    let client: PlexClient
}

extension PlexServerProvider {
    var home: any HomeProviding { PlexHomeRows(client: client) }
}
