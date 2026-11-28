import Foundation

/// Core metadata type representing a Plex library item.
/// Used for movies, shows, seasons, and episodes in lists, hubs, and search results.
/// Fields are optional because different item types populate different subsets.
struct MediaItem: Decodable, Sendable, Identifiable {
    /// Server-scoped identity. Rating keys collide across servers, so nothing
    /// may key, compare, or route on `itemID` alone.
    var id: MediaItemID { MediaItemID(serverID: serverID, itemID: itemID) }

    /// Machine identifier of the server this item was decoded from. Stamped by
    /// `ServerPool.decoder(for:)` through `decoder.duskServerID`.
    let serverID: String?

    let itemID: String
    let key: String
    let type: MediaKind
    let subtype: String?
    let libraryID: String?
    let title: String
    /// Plex edition name ("Director's Cut") when the server holds several
    /// editions of one movie or show. Each edition is its own item with the
    /// same guid, so this is also part of its `ContentKey`.
    let editionTitle: String?

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
    let parentID: String?
    let parentTitle: String?
    let parentThumb: String?
    let grandparentID: String?
    let grandparentTitle: String?
    let grandparentThumb: String?
    let grandparentArt: String?

    // Counts (for shows/seasons)
    let leafCount: Int?
    let viewedLeafCount: Int?
    let childCount: Int?

    /// Collections only: whether Plex fills it from a saved filter instead of
    /// a hand-picked list. Sent as `"1"`/`"0"`.
    let smart: Bool?

    // Metadata tags
    let genres: [Tag]?
    let directors: [Tag]?
    let writers: [Tag]?
    let roles: [Person]?
    /// Plex's scalar guid. Modern servers send a `plex://` global metadata id
    /// here, which is the strongest cross-server content identity we get.
    let guid: String?
    let guids: [PlexGuid]

    enum CodingKeys: String, CodingKey {
        case itemID = "ratingKey", key, type, subtype, libraryID = "librarySectionID", title, editionTitle, guid
        case summary, studio, contentRating, year, originallyAvailableAt
        case thumb, art, banner, clearLogo
        case rating, audienceRating
        case duration, viewCount, viewOffset, lastViewedAt
        case addedAt, updatedAt
        case index, parentIndex
        case parentID = "parentRatingKey", parentTitle, parentThumb
        case grandparentID = "grandparentRatingKey", grandparentTitle, grandparentThumb, grandparentArt
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

        serverID = decoder.duskServerID
        itemID = try container.decode(String.self, forKey: .itemID)
        key = try container.decode(String.self, forKey: .key)
        type = try container.decode(MediaKind.self, forKey: .type)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        if let sectionID = try? container.decode(Int.self, forKey: .libraryID) {
            libraryID = String(sectionID)
        } else {
            libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
        }
        title = try container.decode(String.self, forKey: .title)
        editionTitle = Self.trimmedEditionTitle(try container.decodeIfPresent(String.self, forKey: .editionTitle))

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
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        parentThumb = try container.decodeIfPresent(String.self, forKey: .parentThumb)
        grandparentID = try container.decodeIfPresent(String.self, forKey: .grandparentID)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        grandparentThumb = try container.decodeIfPresent(String.self, forKey: .grandparentThumb)
        grandparentArt = try container.decodeIfPresent(String.self, forKey: .grandparentArt)

        leafCount = try container.decodeIfPresent(Int.self, forKey: .leafCount)
        viewedLeafCount = try container.decodeIfPresent(Int.self, forKey: .viewedLeafCount)
        childCount = try container.decodeIfPresent(Int.self, forKey: .childCount)
        smart = container.decodeLenientBoolIfPresent(forKey: .smart)

        genres = try container.decodeIfPresent([Tag].self, forKey: .genres)
        directors = try container.decodeIfPresent([Tag].self, forKey: .directors)
        writers = try container.decodeIfPresent([Tag].self, forKey: .writers)
        roles = try container.decodeIfPresent([Person].self, forKey: .roles)
        guid = try container.decodeIfPresent(String.self, forKey: .guid)
        guids = try container.decodeIfPresent([PlexGuid].self, forKey: .guids) ?? []
    }
}

extension MediaItem {
    /// Plex sends `editionTitle` only when an edition is set, but a hand-edited
    /// blank one should still read as "no edition" everywhere.
    static func trimmedEditionTitle(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

extension MediaItem: Hashable {
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.viewOffset == rhs.viewOffset &&
        lhs.viewCount == rhs.viewCount &&
        lhs.duration == rhs.duration
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct PlexImageResource: Decodable, Sendable {
    let type: String
    let url: String?
}

private extension KeyedDecodingContainer where Key == MediaItem.CodingKeys {
    func decodePlexImageURLIfPresent(type: String, explicitKey: Key, arrayKey: Key) throws -> String? {
        if let explicitValue = try decodeIfPresent(String.self, forKey: explicitKey) {
            return explicitValue
        }

        let images = try decodeIfPresent([PlexImageResource].self, forKey: arrayKey) ?? []
        return images.first(where: { $0.type.caseInsensitiveCompare(type) == .orderedSame })?.url
    }

    func decodeLenientBoolIfPresent(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value == "1" || value == "true" }
        return nil
    }
}

// MARK: - Convenience

extension MediaItem {
    /// Whether the item is a video clip (e.g. from an "Other Videos" library).
    /// Plex marks clips with `subtype == "clip"` even when `type` is `movie`.
    /// A collection of clips is still a collection.
    var isClip: Bool {
        type == .clip || (subtype == "clip" && type != .collection)
    }

    var isSmartCollection: Bool {
        type == .collection && smart == true
    }

    /// Whether the item has been partially watched.
    var isPartiallyWatched: Bool {
        guard let offset = viewOffset, offset > 0 else { return false }
        return true
    }

    /// Whether the item has been fully watched. Shows and seasons count as
    /// watched only when every episode is (`viewCount` on a container is a
    /// play count and turns positive after one episode, see #88).
    var isWatched: Bool {
        switch type {
        case .show, .season:
            guard let leafCount, leafCount > 0, let viewedLeafCount else { return false }
            return viewedLeafCount >= leafCount
        default:
            guard let count = viewCount else { return false }
            return count > 0
        }
    }

    /// Best available primary image path for compact cards and rows.
    /// Usually portrait-style; for clips the default branch is intentionally
    /// thumb-first because a clip's `thumb` is its 16:9 frame grab. An episode
    /// shows its season's poster, so the art changes per season; a season
    /// without its own poster either sends no `parentThumb` or the show's,
    /// and both land on the show poster.
    var preferredPosterPath: String? {
        switch type {
        case .episode:
            return parentThumb?.nilIfEmpty ?? grandparentThumb?.nilIfEmpty
                ?? thumb ?? grandparentArt ?? art ?? banner
        case .season:
            return thumb ?? parentThumb ?? art ?? banner
        default:
            return thumb ?? parentThumb ?? grandparentThumb ?? art ?? grandparentArt ?? banner
        }
    }

    /// What a poster card shows when `preferredPosterPath` does not load. A
    /// season's own poster can be missing on the server while Plex still sends
    /// its path, so a new season of an old show in Recently Added would be a
    /// blank card; the show's poster stands in for it. The same goes for an
    /// episode showing its season's poster.
    var fallbackPosterPath: String? {
        let showPoster: String?
        switch type {
        case .season:
            showPoster = parentThumb?.nilIfEmpty
        case .episode:
            showPoster = grandparentThumb?.nilIfEmpty
        default:
            return nil
        }
        guard let showPoster, showPoster != preferredPosterPath else { return nil }
        return showPoster
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
struct Tag: Codable, Sendable, Hashable {
    let tag: String
    /// The tag's id. For a `Collection` tag it is the collection's `index`,
    /// which is how an item's collections are matched to collection items.
    var id: Int? = nil

    init(tag: String, id: Int? = nil) {
        self.tag = tag
        self.id = id
    }

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

struct PlexGuid: Codable, Sendable, Hashable {
    let id: String

    func value(for provider: String) -> String? {
        let prefix = "\(provider)://"
        guard id.lowercased().hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count)).nilIfEmpty
    }
}

/// A cast/crew member with role information.
struct Person: Codable, Sendable {
    let id: Int?
    let filter: String?
    let tag: String
    let tagKey: String?
    let role: String?
    let thumb: String?
}

extension Person {
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

extension MediaItem {
    var personID: String? {
        guard type == .person else { return nil }

        if let keyPersonID = key.split(separator: "/").last, !keyPersonID.isEmpty {
            return String(keyPersonID)
        }

        return itemID.isEmpty ? nil : itemID
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
    init(role: Person) {
        self.init(
            personID: role.personID,
            name: role.tag,
            thumb: role.thumb,
            roleName: role.role
        )
    }

    init?(item: MediaItem) {
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
