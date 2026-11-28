import Foundation

/// Plex's `ImageProviding`. Empty until P0-08 moves the Plex calls here.
struct PlexImages: ImageProviding {
    let client: PlexClient
}

extension PlexServerProvider {
    var images: any ImageProviding { PlexImages(client: client) }
}
