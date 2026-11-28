import Foundation

/// Plex's `UserDataProviding`. Empty until P0-10 moves the Plex calls here.
struct PlexUserData: UserDataProviding {
    let client: PlexClient
}

extension PlexServerProvider {
    var userData: any UserDataProviding { PlexUserData(client: client) }
}
