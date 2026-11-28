import Foundation

// Plex's list/hub/search item (`Metadata` / `Directory` rows) and the tag,
// role and person shapes nested in it. Wire shapes only: the domain types
// (`MediaItem`, `Tag`, `Person`, `PersonDetails`) are built by `PlexItemMapper`,
// which also stamps the server.
//
// The `CodingKeys` are Plex's keys and must not change: the offline metadata
// cache stores raw server payloads and decodes them through these DTOs.

struct PlexItemDTO: Decodable, Sendable {
    let ratingKey: String
    let key: String
    let type: MediaKind
    let subtype: String?
    let librarySectionID: String?
    let title: String
    let editionTitle: String?

    let summary: String?
    let studio: String?
    let contentRating: String?
    let year: Int?
    let originallyAvailableAt: String?

    let thumb: String?
    let art: String?
    let banner: String?
    /// The explicit `clearLogo`, or the `Image` array's clearLogo entry.
    let clearLogo: String?

    let rating: Double?
    let audienceRating: Double?

    let duration: Int?
    let viewCount: Int?
    let viewOffset: Int?
    let lastViewedAt: Int?

    let addedAt: Int?
    let updatedAt: Int?

    let index: Int?
    let parentIndex: Int?
    let parentRatingKey: String?
    let parentTitle: String?
    let parentThumb: String?
    let grandparentRatingKey: String?
    let grandparentTitle: String?
    let grandparentThumb: String?
    let grandparentArt: String?

    let leafCount: Int?
    let viewedLeafCount: Int?
    let childCount: Int?
    /// Sent as `"1"`/`"0"`, a number or a bool depending on the endpoint.
    let smart: Bool?

    let genres: [PlexTagDTO]?
    let directors: [PlexTagDTO]?
    let writers: [PlexTagDTO]?
    let roles: [PlexRoleDTO]?
    let guid: String?
    let guids: [ItemGuid]

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, subtype, librarySectionID, title, editionTitle, guid
        case summary, studio, contentRating, year, originallyAvailableAt
        case thumb, art, banner, clearLogo
        case rating, audienceRating
        case duration, viewCount, viewOffset, lastViewedAt
        case addedAt, updatedAt
        case index, parentIndex
        case parentRatingKey, parentTitle, parentThumb
        case grandparentRatingKey, grandparentTitle, grandparentThumb, grandparentArt
        case leafCount, viewedLeafCount, childCount, smart
        case genres = "Genre"
        case directors = "Director"
        case writers = "Writer"
        case roles = "Role"
        case guids = "Guid"
        case images = "Image"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        key = try container.decode(String.self, forKey: .key)
        type = try container.decode(MediaKind.self, forKey: .type)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        if let sectionID = try? container.decode(Int.self, forKey: .librarySectionID) {
            librarySectionID = String(sectionID)
        } else {
            librarySectionID = try container.decodeIfPresent(String.self, forKey: .librarySectionID)
        }
        title = try container.decode(String.self, forKey: .title)
        editionTitle = try container.decodeIfPresent(String.self, forKey: .editionTitle)

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
        smart = container.decodeLenientBoolIfPresent(forKey: .smart)

        genres = try container.decodeIfPresent([PlexTagDTO].self, forKey: .genres)
        directors = try container.decodeIfPresent([PlexTagDTO].self, forKey: .directors)
        writers = try container.decodeIfPresent([PlexTagDTO].self, forKey: .writers)
        roles = try container.decodeIfPresent([PlexRoleDTO].self, forKey: .roles)
        guid = try container.decodeIfPresent(String.self, forKey: .guid)
        guids = try container.decodeIfPresent([ItemGuid].self, forKey: .guids) ?? []
    }
}

/// One entry of Plex's `Image` array (`{"type": "clearLogo", "url": …}`).
struct PlexImageResourceDTO: Decodable, Sendable {
    let type: String
    let url: String?
}

extension KeyedDecodingContainer {
    /// The explicit image key when present, else the matching `Image` entry.
    func decodePlexImageURLIfPresent(type: String, explicitKey: Key, arrayKey: Key) throws -> String? {
        if let explicitValue = try decodeIfPresent(String.self, forKey: explicitKey) {
            return explicitValue
        }

        let images = try decodeIfPresent([PlexImageResourceDTO].self, forKey: arrayKey) ?? []
        return images.first(where: { $0.type.caseInsensitiveCompare(type) == .orderedSame })?.url
    }
}

private extension KeyedDecodingContainer where Key == PlexItemDTO.CodingKeys {
    func decodeLenientBoolIfPresent(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value == "1" || value == "true" }
        return nil
    }
}

/// A `Genre` / `Director` / `Writer` / `Collection` / `Place` tag.
struct PlexTagDTO: Decodable, Sendable {
    let tag: String
    /// For a `Collection` tag it is the collection's `index`.
    let id: Int?

    private enum CodingKeys: String, CodingKey {
        case tag, id
    }

    /// The id is a bonus: a server that sends it in another shape must not
    /// fail the whole item.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        id = (try? container.decodeIfPresent(Int.self, forKey: .id))
            ?? (try? container.decodeIfPresent(String.self, forKey: .id)).flatMap { $0.flatMap(Int.init) }
    }
}

/// A `Role` (cast/crew) entry on an item.
struct PlexRoleDTO: Decodable, Sendable {
    let id: Int?
    let filter: String?
    let tag: String
    let tagKey: String?
    let role: String?
    let thumb: String?
}

/// A `/library/people/{id}` `Directory` row.
struct PlexPersonDTO: Decodable, Sendable {
    let id: Int?
    let filter: String?
    let tag: String
    let tagKey: String?
    let thumb: String?

    private enum CodingKeys: String, CodingKey {
        case id, filter, tag, tagKey, thumb
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        filter = try container.decodeIfPresent(String.self, forKey: .filter)
        tag = try container.decode(String.self, forKey: .tag)
        tagKey = try container.decodeIfPresent(String.self, forKey: .tagKey)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
    }
}
