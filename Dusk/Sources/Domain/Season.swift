import Foundation

/// A season within a TV show.
/// Returned from `GET /library/metadata/{showRatingKey}/children`.
struct Season: Sendable, Identifiable {
    /// Server-scoped identity; see `MediaItemID`.
    var id: MediaItemID { MediaItemID(serverID: serverID, itemID: itemID) }

    /// Stamped by the provider's mapper (`PlexItemMapper`); never part of the
    /// server payload.
    let serverID: String?

    let itemID: String
    let key: String
    let title: String
    let index: Int

    // Parent show
    let parentID: String?
    let parentTitle: String?
    let parentThumb: String?

    // Images
    let thumb: String?
    let art: String?

    // Episode counts
    let episodeCount: Int?
    let watchedEpisodeCount: Int?

    // Timestamps
    let addedAt: Int?
    let updatedAt: Int?
}

extension Season {
    var isPartiallyWatched: Bool {
        guard let total = episodeCount, let viewed = watchedEpisodeCount else { return false }
        return total > 0 && viewed > 0 && viewed < total
    }

    /// Episodes still to watch in a partially watched season; nil for a season
    /// that is unwatched or fully watched (those get no badge / a checkmark).
    var unwatchedEpisodeCount: Int? {
        guard isPartiallyWatched, let total = episodeCount, let viewed = watchedEpisodeCount else { return nil }
        return total - viewed
    }

    /// Whether all episodes in this season have been watched.
    var isFullyWatched: Bool {
        guard let total = episodeCount, let viewed = watchedEpisodeCount else { return false }
        return total > 0 && viewed >= total
    }
}
