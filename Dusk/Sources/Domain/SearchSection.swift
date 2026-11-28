import Foundation

/// A group of search results for a single media type.
/// The Plex search API (`GET /hubs/search`) returns results grouped by type
/// as Hub objects. This type provides a search-oriented wrapper.
struct SearchSection: Sendable, Identifiable {
    var id: String { type ?? title }

    let title: String
    let type: String?
    let items: [MediaItem]
}

extension SearchSection {
    /// Create search result groups from a hub response.
    ///
    /// Plex groups clips under the movie hub (clips report `type == "movie"`),
    /// which would force the 2:3 poster layout — and a cropped 2:3 transcode —
    /// onto 16:9 videos. Mixed hubs are split into the original poster group
    /// plus a "Videos" group; all-clip hubs are retitled to "Videos".
    static func results(from hub: HomeRow) -> [SearchSection] {
        let clips = hub.items.filter(\.isClip)
        guard !clips.isEmpty else {
            return [SearchSection(title: hub.title, type: hub.type, items: hub.items)]
        }

        let posterItems = hub.items.filter { !$0.isClip }
        var results: [SearchSection] = []
        if !posterItems.isEmpty {
            results.append(SearchSection(title: hub.title, type: hub.type, items: posterItems))
        }
        results.append(SearchSection(title: "Videos", type: "clip", items: clips))
        return results
    }
}
