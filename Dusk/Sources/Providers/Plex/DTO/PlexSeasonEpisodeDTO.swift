import Foundation

// `/library/metadata/{ratingKey}/children` (seasons of a show, episodes of a
// season) and `/allLeaves` rows. `PlexItemMapper` builds `Season` / `Episode`.
//
// The `CodingKeys` are Plex's keys and must not change: downloads keep the raw
// children payloads in the offline metadata cache and decode them through
// these DTOs.

struct PlexEpisodeDTO: Decodable, Sendable {
    let ratingKey: String
    let key: String
    let title: String

    let index: Int?
    let parentIndex: Int?

    let parentRatingKey: String?
    let parentTitle: String?

    let grandparentRatingKey: String?
    let grandparentTitle: String?
    let grandparentThumb: String?

    let summary: String?
    let contentRating: String?
    let originallyAvailableAt: String?
    let year: Int?

    let thumb: String?
    let art: String?

    let duration: Int?
    let viewCount: Int?
    let viewOffset: Int?
    let lastViewedAt: Int?

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

struct PlexSeasonDTO: Decodable, Sendable {
    let ratingKey: String
    let key: String
    let title: String
    let index: Int

    let parentRatingKey: String?
    let parentTitle: String?
    let parentThumb: String?

    let thumb: String?
    let art: String?

    let leafCount: Int?
    let viewedLeafCount: Int?

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
