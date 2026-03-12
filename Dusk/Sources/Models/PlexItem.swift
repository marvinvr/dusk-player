import Foundation

/// Core metadata type representing a Plex library item.
/// Used for movies, shows, seasons, and episodes in lists, hubs, and search results.
/// Fields are optional because different item types populate different subsets.
struct PlexItem: Codable, Sendable, Identifiable {
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
        case thumb, art, banner
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
    }
}

extension PlexItem: Hashable {
    static func == (lhs: PlexItem, rhs: PlexItem) -> Bool {
        lhs.ratingKey == rhs.ratingKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ratingKey)
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
