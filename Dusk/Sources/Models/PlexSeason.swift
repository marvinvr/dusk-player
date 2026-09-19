import Foundation

/// A season within a TV show.
/// Returned from `GET /library/metadata/{showRatingKey}/children`.
struct PlexSeason: Codable, Sendable, Identifiable {
    /// Server-scoped identity; see `PlexItemID`.
    var id: PlexItemID { PlexItemID(serverID: serverID, ratingKey: ratingKey) }

    /// Stamped by `ServerPool.decoder(for:)`; never part of the Plex payload,
    /// so it is excluded from `CodingKeys` and dropped when re-encoded.
    let serverID: String?

    let ratingKey: String
    let key: String
    let title: String
    let index: Int

    // Parent show
    let parentRatingKey: String?
    let parentTitle: String?
    let parentThumb: String?

    // Images
    let thumb: String?
    let art: String?

    // Episode counts
    let leafCount: Int?
    let viewedLeafCount: Int?

    // Timestamps
    let addedAt: Int?
    let updatedAt: Int?

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, title, index
        case parentRatingKey, parentTitle, parentThumb
        case thumb, art
        case leafCount, viewedLeafCount
        case addedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = decoder.duskServerID
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        index = try container.decode(Int.self, forKey: .index)
        parentRatingKey = try container.decodeIfPresent(String.self, forKey: .parentRatingKey)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        parentThumb = try container.decodeIfPresent(String.self, forKey: .parentThumb)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        leafCount = try container.decodeIfPresent(Int.self, forKey: .leafCount)
        viewedLeafCount = try container.decodeIfPresent(Int.self, forKey: .viewedLeafCount)
        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
    }
}

extension PlexSeason {
    var isPartiallyWatched: Bool {
        guard let total = leafCount, let viewed = viewedLeafCount else { return false }
        return total > 0 && viewed > 0 && viewed < total
    }

    /// Whether all episodes in this season have been watched.
    var isFullyWatched: Bool {
        guard let total = leafCount, let viewed = viewedLeafCount else { return false }
        return total > 0 && viewed >= total
    }
}
