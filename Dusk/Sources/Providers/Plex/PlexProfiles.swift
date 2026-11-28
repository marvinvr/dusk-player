import Foundation

/// Plex's `ProfileProviding`. Empty until P0-16 moves the Plex calls here.
struct PlexProfiles: ProfileProviding {
    let client: PlexClient
}

extension PlexAccountProvider {
    var profiles: any ProfileProviding { PlexProfiles(client: client) }
}
