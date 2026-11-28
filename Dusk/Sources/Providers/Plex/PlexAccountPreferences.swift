import Foundation

/// Plex's `AccountPreferencesProviding`. Empty until P0-17 moves the Plex calls here.
struct PlexAccountPreferences: AccountPreferencesProviding {
    let client: PlexClient
}

extension PlexAccountProvider {
    var preferences: any AccountPreferencesProviding { PlexAccountPreferences(client: client) }
}
