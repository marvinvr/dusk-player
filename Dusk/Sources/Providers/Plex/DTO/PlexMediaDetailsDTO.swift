import Foundation

/// `GET /library/metadata/{ratingKey}`: an item with its media hierarchy,
/// markers, ratings and tags. `PlexItemMapper` builds `MediaDetails` from it.
///
/// The `CodingKeys` are Plex's keys and must not change: downloads keep the raw
/// payload in the offline metadata cache and decode it through this DTO.
///
/// `Media`, `Marker` and `Rating` still decode through the domain types' own
/// conformances (the version/marker/rating family is split separately).
struct PlexMediaDetailsDTO: Decodable, Sendable {
    let ratingKey: String
    let key: String
    let type: MediaKind
    let subtype: String?
    let librarySectionID: String?
    let librarySectionTitle: String?
    let title: String
    let editionTitle: String?
    let summary: String?
    let year: Int?
    let duration: Int?
    let viewOffset: Int?
    let viewCount: Int?
    let thumb: String?
    let art: String?
    /// The explicit `clearLogo`, or the `Image` array's clearLogo entry.
    let clearLogo: String?
    let contentRating: String?
    let primaryExtraKey: String?

    let rating: Double?
    let audienceRating: Double?
    let ratingImage: String?
    let audienceRatingImage: String?
    let userRating: Double?
    let ratings: [Rating]

    let studio: String?
    let originallyAvailableAt: String?

    let childCount: Int?
    let leafCount: Int?
    let viewedLeafCount: Int?

    let index: Int?
    let parentIndex: Int?
    let parentRatingKey: String?
    let parentThumb: String?
    let grandparentRatingKey: String?
    let grandparentTitle: String?
    let grandparentThumb: String?

    let genres: [PlexTagDTO]?
    let directors: [PlexTagDTO]?
    let writers: [PlexTagDTO]?
    let roles: [PlexRoleDTO]?
    let collections: [PlexTagDTO]?
    let guid: String?
    let guids: [PlexGuid]
    /// In payload order; the mapper sorts them by start.
    let markers: [Marker]
    let media: [MediaVersion]

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, subtype, librarySectionID, librarySectionTitle, title, editionTitle, summary, year, guid
        case duration, viewOffset, viewCount, thumb, art, clearLogo, contentRating, primaryExtraKey
        case rating, audienceRating, ratingImage, audienceRatingImage, userRating, studio, originallyAvailableAt
        case childCount, leafCount, viewedLeafCount
        case index, parentIndex, parentRatingKey, parentThumb, grandparentRatingKey, grandparentTitle, grandparentThumb
        case genres = "Genre"
        case directors = "Director"
        case writers = "Writer"
        case roles = "Role"
        case collections = "Collection"
        case guids = "Guid"
        case markers = "Marker"
        case media = "Media"
        case images = "Image"
        case ratings = "Rating"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        key = try container.decode(String.self, forKey: .key)
        type = try container.decode(MediaKind.self, forKey: .type)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        // Plex serializes librarySectionID as a number; tolerate strings too.
        if let numericSectionID = try? container.decodeIfPresent(Int.self, forKey: .librarySectionID) {
            librarySectionID = String(numericSectionID)
        } else {
            librarySectionID = (try? container.decodeIfPresent(String.self, forKey: .librarySectionID)) ?? nil
        }
        librarySectionTitle = try container.decodeIfPresent(String.self, forKey: .librarySectionTitle)
        title = try container.decode(String.self, forKey: .title)
        editionTitle = try container.decodeIfPresent(String.self, forKey: .editionTitle)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        viewOffset = try container.decodeIfPresent(Int.self, forKey: .viewOffset)
        viewCount = try container.decodeIfPresent(Int.self, forKey: .viewCount)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        clearLogo = try container.decodePlexImageURLIfPresent(type: "clearLogo", explicitKey: .clearLogo, arrayKey: .images)
        contentRating = try container.decodeIfPresent(String.self, forKey: .contentRating)
        primaryExtraKey = try? container.decodeIfPresent(String.self, forKey: .primaryExtraKey)
        rating = try container.decodeIfPresent(Double.self, forKey: .rating)
        audienceRating = try container.decodeIfPresent(Double.self, forKey: .audienceRating)
        ratingImage = try? container.decodeIfPresent(String.self, forKey: .ratingImage)
        audienceRatingImage = try? container.decodeIfPresent(String.self, forKey: .audienceRatingImage)
        userRating = try? container.decodeIfPresent(Double.self, forKey: .userRating)
        ratings = (try? container.decodeIfPresent([Rating].self, forKey: .ratings)) ?? []
        studio = try container.decodeIfPresent(String.self, forKey: .studio)
        originallyAvailableAt = try container.decodeIfPresent(String.self, forKey: .originallyAvailableAt)
        childCount = try container.decodeIfPresent(Int.self, forKey: .childCount)
        leafCount = try container.decodeIfPresent(Int.self, forKey: .leafCount)
        viewedLeafCount = try container.decodeIfPresent(Int.self, forKey: .viewedLeafCount)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        parentIndex = try container.decodeIfPresent(Int.self, forKey: .parentIndex)
        parentRatingKey = try container.decodeIfPresent(String.self, forKey: .parentRatingKey)
        parentThumb = try container.decodeIfPresent(String.self, forKey: .parentThumb)
        grandparentRatingKey = try container.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        grandparentThumb = try container.decodeIfPresent(String.self, forKey: .grandparentThumb)
        genres = try container.decodeIfPresent([PlexTagDTO].self, forKey: .genres)
        directors = try container.decodeIfPresent([PlexTagDTO].self, forKey: .directors)
        writers = try container.decodeIfPresent([PlexTagDTO].self, forKey: .writers)
        roles = try container.decodeIfPresent([PlexRoleDTO].self, forKey: .roles)
        collections = try container.decodeIfPresent([PlexTagDTO].self, forKey: .collections)
        guid = try container.decodeIfPresent(String.self, forKey: .guid)
        guids = try container.decodeIfPresent([PlexGuid].self, forKey: .guids) ?? []
        markers = try container.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        media = try container.decodeIfPresent([MediaVersion].self, forKey: .media) ?? []
    }
}
