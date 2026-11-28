import Foundation

/// Content Home never shows. Home renders a fixed arrangement, so this is the
/// only place that decides which Plex hubs and items exist as rows at all.
enum HomeHubFilter {
    /// Plex's own continue-watching/on-deck hubs are covered by the cinematic
    /// hero, and playlists are not a Dusk destination.
    static func shouldHide(hub: HomeRow) -> Bool {
        let fields = [hub.title, hub.key, hub.hubIdentifier]
            .compactMap { $0?.lowercased() }

        return fields.contains { value in
            value.contains("continue watching") ||
            value.contains("continuewatching") ||
            value.contains("on deck") ||
            value.contains("ondeck") ||
            value.contains("playlist") ||
            value.contains("playlists")
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
