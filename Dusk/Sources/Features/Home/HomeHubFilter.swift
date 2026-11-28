import Foundation

/// Content Home never shows. Home renders a fixed arrangement, so this is the
/// only place that decides which rows and items exist on Home at all.
enum HomeHubFilter {
    /// The server's own Continue Watching and next-up rows are covered by the
    /// cinematic hero, and playlists are not a Dusk destination. The mapper
    /// decides which rows those are (`HomeRow.kind`).
    static func shouldHide(hub: HomeRow) -> Bool {
        switch hub.kind {
        case .continueWatching, .nextUp, .playlists:
            return true
        case .recentlyAdded, .other:
            return false
        }
    }

    static func shouldHide(item: MediaItem) -> Bool {
        switch item.type {
        case .artist, .album, .track, .unknown:
            return true
        default:
            return item.key.lowercased().contains("/playlists/")
        }
    }
}
