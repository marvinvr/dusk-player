import Foundation

/// Plex's `SeerrAuthProviding`. Empty until P0-18 moves the Plex calls here.
struct PlexSeerrAuth: SeerrAuthProviding {
    let client: PlexClient
}

extension PlexAccountProvider {
    var seerrAuth: any SeerrAuthProviding { PlexSeerrAuth(client: client) }
}
