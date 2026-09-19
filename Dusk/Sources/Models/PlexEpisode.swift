import Foundation

/// An episode within a TV season.
/// Returned from `GET /library/metadata/{seasonRatingKey}/children`.
struct PlexEpisode: Codable, Sendable, Identifiable {
    /// Server-scoped identity; see `PlexItemID`.
    var id: PlexItemID { PlexItemID(serverID: serverID, ratingKey: ratingKey) }

    /// Stamped by `ServerPool.decoder(for:)`; never part of the Plex payload,
    /// so it is excluded from `CodingKeys` and dropped when re-encoded.
    let serverID: String?

    let ratingKey: String
    let key: String
    let title: String

    // Episode/season numbering
    let index: Int?
    let parentIndex: Int?

    // Parent season
    let parentRatingKey: String?
    let parentTitle: String?

    // Grandparent show
    let grandparentRatingKey: String?
    let grandparentTitle: String?
    let grandparentThumb: String?

    // Content
    let summary: String?
    let contentRating: String?
    let originallyAvailableAt: String?
    let year: Int?

    // Images
    let thumb: String?
    let art: String?

    // Playback / watch state
    let duration: Int?
    let viewCount: Int?
    let viewOffset: Int?
    let lastViewedAt: Int?

    // Timestamps
    let addedAt: Int?
    let updatedAt: Int?

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, title
        case index, parentIndex
        case parentRatingKey, parentTitle
        case grandparentRatingKey, grandparentTitle, grandparentThumb
        case summary, contentRating, originallyAvailableAt, year
        case thumb, art
        case duration, viewCount, viewOffset, lastViewedAt
        case addedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = decoder.duskServerID
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        parentIndex = try container.decodeIfPresent(Int.self, forKey: .parentIndex)
        parentRatingKey = try container.decodeIfPresent(String.self, forKey: .parentRatingKey)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        grandparentRatingKey = try container.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        grandparentThumb = try container.decodeIfPresent(String.self, forKey: .grandparentThumb)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        contentRating = try container.decodeIfPresent(String.self, forKey: .contentRating)
        originallyAvailableAt = try container.decodeIfPresent(String.self, forKey: .originallyAvailableAt)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        viewCount = try container.decodeIfPresent(Int.self, forKey: .viewCount)
        viewOffset = try container.decodeIfPresent(Int.self, forKey: .viewOffset)
        lastViewedAt = try container.decodeIfPresent(Int.self, forKey: .lastViewedAt)
        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
    }
}

extension PlexEpisode {
    var isWatched: Bool {
        guard let count = viewCount else { return false }
        return count > 0
    }

    var isPartiallyWatched: Bool {
        guard let offset = viewOffset, offset > 0 else { return false }
        return true
    }

    /// Human-readable episode label like "Episode 5".
    var episodeLabel: String? {
        guard let e = index else { return nil }
        return "Episode \(e)"
    }
}
