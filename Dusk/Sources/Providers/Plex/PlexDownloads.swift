import Foundation

/// Plex's `DownloadProviding`. Empty until P0-15 moves the Plex calls here.
struct PlexDownloads: DownloadProviding {
    let client: PlexClient
}

extension PlexServerProvider {
    var downloads: any DownloadProviding { PlexDownloads(client: client) }
}
