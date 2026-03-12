import Foundation

/// A group of search results for a single media type.
/// The Plex search API (`GET /hubs/search`) returns results grouped by type
/// as Hub objects. This type provides a search-oriented wrapper.
struct PlexSearchResult: Sendable, Identifiable {
    var id: String { type ?? title }

    let title: String
    let type: String?
    let items: [PlexItem]
}

extension PlexSearchResult {
    /// Create search results from a hub response.
    init(hub: PlexHub) {
        self.title = hub.title
        self.type = hub.type
        self.items = hub.items
    }
}
