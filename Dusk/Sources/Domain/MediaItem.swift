import Foundation

/// Core metadata type representing a Plex library item.
/// Used for movies, shows, seasons, and episodes in lists, hubs, and search results.
/// Fields are optional because different item types populate different subsets.
struct MediaItem: Sendable, Identifiable {
    /// Server-scoped identity. Rating keys collide across servers, so nothing
    /// may key, compare, or route on `itemID` alone.
    var id: MediaItemID { MediaItemID(serverID: serverID, itemID: itemID) }

    /// Machine identifier of the server this item came from. Stamped by the
    /// provider's mapper (`PlexItemMapper`); nil when unstamped.
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
    let playCount: Int?
    let resumeOffsetMs: Int?
    let lastPlayedAt: Int?

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
    let episodeCount: Int?
    let watchedEpisodeCount: Int?
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
        lhs.resumeOffsetMs == rhs.resumeOffsetMs &&
        lhs.playCount == rhs.playCount &&
        lhs.duration == rhs.duration
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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
        guard let offset = resumeOffsetMs, offset > 0 else { return false }
        return true
    }

    /// Whether the item has been fully watched. Shows and seasons count as
    /// watched only when every episode is (`playCount` on a container is a
    /// play count and turns positive after one episode, see #88).
    var isWatched: Bool {
        switch type {
        case .show, .season:
            guard let episodeCount, episodeCount > 0, let watchedEpisodeCount else { return false }
            return watchedEpisodeCount >= episodeCount
        default:
            guard let count = playCount else { return false }
            return count > 0
        }
    }

    /// The item's artwork, each ref on the item's own server.
    var artwork: ArtworkSet {
        ArtworkSet(
            poster: ArtworkRef(serverID: serverID, path: thumb),
            backdrop: ArtworkRef(serverID: serverID, path: art),
            logo: ArtworkRef(serverID: serverID, path: clearLogo),
            banner: ArtworkRef(serverID: serverID, path: banner),
            parentPoster: ArtworkRef(serverID: serverID, path: parentThumb),
            grandparentPoster: ArtworkRef(serverID: serverID, path: grandparentThumb),
            grandparentBackdrop: ArtworkRef(serverID: serverID, path: grandparentArt)
        )
    }

    /// See `ArtworkSet.preferredPoster(for:)`.
    var preferredPoster: ArtworkRef? { artwork.preferredPoster(for: type) }

    /// See `ArtworkSet.fallbackPoster(for:)`.
    var fallbackPoster: ArtworkRef? { artwork.fallbackPoster(for: type) }

    /// See `ArtworkSet.preferredLandscape(for:)`.
    var preferredLandscape: ArtworkRef? { artwork.preferredLandscape(for: type) }
}

// MARK: - Nested tag types

/// A simple key-value tag used for genres, directors, writers, etc.
struct Tag: Sendable, Hashable {
    let tag: String
    /// The tag's id. For a `Collection` tag it is the collection's `index`,
    /// which is how an item's collections are matched to collection items.
    var id: Int? = nil

    init(tag: String, id: Int? = nil) {
        self.tag = tag
        self.id = id
    }
}

/// One entry of Plex's `Guid` array (`tmdb://603`). Read through `ExternalIDs`.
struct PlexGuid: Codable, Sendable, Hashable {
    let id: String
}

extension MediaItem {
    var externalIDs: ExternalIDs { ExternalIDs(uris: guids.map(\.id)) }
}

extension MediaDetails {
    var externalIDs: ExternalIDs { ExternalIDs(uris: guids.map(\.id)) }
}

extension WatchlistEntry {
    var externalIDs: ExternalIDs { ExternalIDs(uris: guids.map(\.id)) }
}

/// A cast/crew member with role information.
struct Person: Sendable {
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

/// A person page's subject (`/library/people/{id}`).
struct PlexPerson: Sendable, Identifiable {
    var id: String { personID ?? tag }

    let personID: String?
    let filter: String?
    let tag: String
    let tagKey: String?
    let thumb: String?
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
