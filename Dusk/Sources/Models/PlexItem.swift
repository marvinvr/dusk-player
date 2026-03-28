import Foundation

/// Core metadata type representing a Plex library item.
/// Used for movies, shows, seasons, and episodes in lists, hubs, and search results.
/// Fields are optional because different item types populate different subsets.
struct PlexItem: Decodable, Sendable, Identifiable {
    var id: String { ratingKey }

    let ratingKey: String
    let key: String
    let type: PlexMediaType
    let title: String

    let summary: String?
    let studio: String?
    let contentRating: String?
    let year: Int?
    let originallyAvailableAt: String?

    // Images (relative to server base URL)
    let thumb: String?
    let art: String?
    let banner: String?
    let clearLogo: String?

    // Ratings
    let rating: Double?
    let audienceRating: Double?

    // Playback / watch state
    let duration: Int?
    let viewCount: Int?
    let viewOffset: Int?
    let lastViewedAt: Int?

    // Timestamps
    let addedAt: Int?
    let updatedAt: Int?

    // Hierarchy (for seasons/episodes)
    let index: Int?
    let parentIndex: Int?
    let parentRatingKey: String?
    let parentTitle: String?
    let parentThumb: String?
    let grandparentRatingKey: String?
    let grandparentTitle: String?
    let grandparentThumb: String?
    let grandparentArt: String?

    // Counts (for shows/seasons)
    let leafCount: Int?
    let viewedLeafCount: Int?
    let childCount: Int?

    // Metadata tags
    let genres: [PlexTag]?
    let directors: [PlexTag]?
    let writers: [PlexTag]?
    let roles: [PlexRole]?

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title
        case summary, studio, contentRating, year, originallyAvailableAt
        case thumb, art, banner, clearLogo
        case rating, audienceRating
        case duration, viewCount, viewOffset, lastViewedAt
        case addedAt, updatedAt
        case index, parentIndex
        case parentRatingKey, parentTitle, parentThumb
        case grandparentRatingKey, grandparentTitle, grandparentThumb, grandparentArt
        case leafCount, viewedLeafCount, childCount
        case genres = "Genre"
        case directors = "Director"
        case writers = "Writer"
        case roles = "Role"
        case images = "Image"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        key = try container.decode(String.self, forKey: .key)
        type = try container.decode(PlexMediaType.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)

        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        studio = try container.decodeIfPresent(String.self, forKey: .studio)
        contentRating = try container.decodeIfPresent(String.self, forKey: .contentRating)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        originallyAvailableAt = try container.decodeIfPresent(String.self, forKey: .originallyAvailableAt)

        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        banner = try container.decodeIfPresent(String.self, forKey: .banner)
        clearLogo = try container.decodePlexImageURLIfPresent(type: "clearLogo", explicitKey: .clearLogo, arrayKey: .images)

        rating = try container.decodeIfPresent(Double.self, forKey: .rating)
        audienceRating = try container.decodeIfPresent(Double.self, forKey: .audienceRating)

        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        viewCount = try container.decodeIfPresent(Int.self, forKey: .viewCount)
        viewOffset = try container.decodeIfPresent(Int.self, forKey: .viewOffset)
        lastViewedAt = try container.decodeIfPresent(Int.self, forKey: .lastViewedAt)

        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)

        index = try container.decodeIfPresent(Int.self, forKey: .index)
        parentIndex = try container.decodeIfPresent(Int.self, forKey: .parentIndex)
        parentRatingKey = try container.decodeIfPresent(String.self, forKey: .parentRatingKey)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        parentThumb = try container.decodeIfPresent(String.self, forKey: .parentThumb)
        grandparentRatingKey = try container.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        grandparentThumb = try container.decodeIfPresent(String.self, forKey: .grandparentThumb)
        grandparentArt = try container.decodeIfPresent(String.self, forKey: .grandparentArt)

        leafCount = try container.decodeIfPresent(Int.self, forKey: .leafCount)
        viewedLeafCount = try container.decodeIfPresent(Int.self, forKey: .viewedLeafCount)
        childCount = try container.decodeIfPresent(Int.self, forKey: .childCount)

        genres = try container.decodeIfPresent([PlexTag].self, forKey: .genres)
        directors = try container.decodeIfPresent([PlexTag].self, forKey: .directors)
        writers = try container.decodeIfPresent([PlexTag].self, forKey: .writers)
        roles = try container.decodeIfPresent([PlexRole].self, forKey: .roles)
    }
}

extension PlexItem: Hashable {
    static func == (lhs: PlexItem, rhs: PlexItem) -> Bool {
        lhs.ratingKey == rhs.ratingKey &&
        lhs.viewOffset == rhs.viewOffset &&
        lhs.viewCount == rhs.viewCount &&
        lhs.duration == rhs.duration
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ratingKey)
    }
}

struct PlexImageResource: Decodable, Sendable {
    let type: String
    let url: String?
}

private extension KeyedDecodingContainer where Key == PlexItem.CodingKeys {
    func decodePlexImageURLIfPresent(type: String, explicitKey: Key, arrayKey: Key) throws -> String? {
        if let explicitValue = try decodeIfPresent(String.self, forKey: explicitKey) {
            return explicitValue
        }

        let images = try decodeIfPresent([PlexImageResource].self, forKey: arrayKey) ?? []
        return images.first(where: { $0.type.caseInsensitiveCompare(type) == .orderedSame })?.url
    }
}

// MARK: - Convenience

extension PlexItem {
    /// Whether the item has been partially watched.
    var isPartiallyWatched: Bool {
        guard let offset = viewOffset, offset > 0 else { return false }
        return true
    }

    /// Whether the item has been fully watched.
    var isWatched: Bool {
        guard let count = viewCount else { return false }
        return count > 0
    }

    /// Best available portrait-style image path for compact cards and rows.
    var preferredPosterPath: String? {
        switch type {
        case .episode:
            return grandparentThumb ?? parentThumb ?? thumb ?? grandparentArt ?? art ?? banner
        case .season:
            return thumb ?? parentThumb ?? art ?? banner
        default:
            return thumb ?? parentThumb ?? grandparentThumb ?? art ?? grandparentArt ?? banner
        }
    }

    /// Best available landscape-style image path for feature rows.
    var preferredLandscapePath: String? {
        switch type {
        case .episode:
            return thumb ?? art ?? grandparentArt ?? banner ?? grandparentThumb ?? parentThumb
        case .season:
            return art ?? banner ?? thumb ?? parentThumb
        default:
            return banner ?? art ?? thumb ?? parentThumb ?? grandparentArt ?? grandparentThumb
        }
    }
}

// MARK: - Nested tag types

/// A simple key-value tag used for genres, directors, writers, etc.
struct PlexTag: Codable, Sendable, Hashable {
    let tag: String
}

/// A cast/crew member with role information.
struct PlexRole: Codable, Sendable {
    let id: Int?
    let filter: String?
    let tag: String
    let tagKey: String?
    let role: String?
    let thumb: String?
}

extension PlexRole {
    var personID: String? {
        if let id {
            return String(id)
        }

        guard let filter,
              let value = filter.split(separator: "=").last,
              !value.isEmpty else {
            return nil
        }

        return String(value)
    }
}

extension PlexItem {
    var personID: String? {
        guard type == .person else { return nil }

        if let keyPersonID = key.split(separator: "/").last, !keyPersonID.isEmpty {
            return String(keyPersonID)
        }

        return ratingKey.isEmpty ? nil : ratingKey
    }
}

struct PlexPerson: Decodable, Sendable, Identifiable {
    var id: String { personID ?? tag }

    let personID: String?
    let filter: String?
    let tag: String
    let tagKey: String?
    let thumb: String?

    enum CodingKeys: String, CodingKey {
        case rawID = "id"
        case filter, tag, tagKey, thumb
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decodeIfPresent(Int.self, forKey: .rawID)
        self.filter = try container.decodeIfPresent(String.self, forKey: .filter)
        self.personID = rawID.map(String.init) ?? Self.extractPersonID(from: filter)
        self.tag = try container.decode(String.self, forKey: .tag)
        self.tagKey = try container.decodeIfPresent(String.self, forKey: .tagKey)
        self.thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
    }

    private static func extractPersonID(from filter: String?) -> String? {
        guard let filter,
              let value = filter.split(separator: "=").last,
              !value.isEmpty else {
            return nil
        }

        return String(value)
    }
}

struct PlexPersonReference: Sendable, Hashable, Identifiable {
    let personID: String?
    let name: String
    let thumb: String?
    let roleName: String?

    var id: String { personID ?? name }

    init(personID: String?, name: String, thumb: String?, roleName: String? = nil) {
        self.personID = personID
        self.name = name
        self.thumb = thumb
        self.roleName = roleName
    }
}

extension PlexPersonReference {
    init(role: PlexRole) {
        self.init(
            personID: role.personID,
            name: role.tag,
            thumb: role.thumb,
            roleName: role.role
        )
    }

    init?(item: PlexItem) {
        guard item.type == .person else { return nil }

        self.init(
            personID: item.personID,
            name: item.title,
            thumb: item.thumb,
            roleName: nil
        )
    }

    init(person: PlexPerson, roleName: String? = nil) {
        self.init(
            personID: person.personID,
            name: person.tag,
            thumb: person.thumb,
            roleName: roleName
        )
    }
}
