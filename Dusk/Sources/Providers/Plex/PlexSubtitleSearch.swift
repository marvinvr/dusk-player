import Foundation

/// Plex's `SubtitleSearchProviding`. Empty until a package moves the Plex calls here.
struct PlexSubtitleSearch: SubtitleSearchProviding {
    let client: PlexClient
}

extension PlexServerProvider {
    var subtitleSearch: (any SubtitleSearchProviding)? { PlexSubtitleSearch(client: client) }
}
