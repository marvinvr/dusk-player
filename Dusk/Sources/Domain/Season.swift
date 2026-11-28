import Foundation

/// A season within a TV show.
/// Returned from `GET /library/metadata/{showRatingKey}/children`.
struct Season: Codable, Sendable, Identifiable {
    /// Server-scoped identity; see `MediaItemID`.
    var id: MediaItemID { MediaItemID(serverID: serverID, itemID: itemID) }

    /// Stamped by `ServerPool.decoder(for:)`; never part of the Plex payload,
    /// so it is excluded from `CodingKeys` and dropped when re-encoded.
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

    enum CodingKeys: String, CodingKey {
        case itemID = "ratingKey", key, title, index
        case parentID = "parentRatingKey", parentTitle, parentThumb
        case thumb, art
        case episodeCount = "leafCount", watchedEpisodeCount = "viewedLeafCount"
        case addedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = decoder.duskServerID
        itemID = try container.decode(String.self, forKey: .itemID)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        index = try container.decode(Int.self, forKey: .index)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        parentThumb = try container.decodeIfPresent(String.self, forKey: .parentThumb)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        episodeCount = try container.decodeIfPresent(Int.self, forKey: .episodeCount)
        watchedEpisodeCount = try container.decodeIfPresent(Int.self, forKey: .watchedEpisodeCount)
        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
    }
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
