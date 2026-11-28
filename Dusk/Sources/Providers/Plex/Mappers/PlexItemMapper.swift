import Foundation

/// Plex DTO → domain for the item family: items, details, seasons, episodes,
/// libraries, hub rows, tags, roles and people.
///
/// The mapper is where a value learns which server it came from: every
/// function takes the `serverID` of the server the payload was fetched from
/// (nil = not stamped, e.g. a payload decoded outside the pool) and stamps it
/// on everything it builds, nested items included.
enum PlexItemMapper {
    static func map(_ dto: PlexItemDTO, serverID: String?) -> MediaItem {
        MediaItem(
            serverID: serverID?.nilIfEmpty,
            itemID: dto.ratingKey,
            key: dto.key,
            type: dto.type,
            subtype: dto.subtype,
            libraryID: dto.librarySectionID,
            title: dto.title,
            editionTitle: MediaItem.trimmedEditionTitle(dto.editionTitle),
            summary: dto.summary,
            studio: dto.studio,
            contentRating: dto.contentRating,
            year: dto.year,
            originallyAvailableAt: dto.originallyAvailableAt,
            thumb: dto.thumb,
            art: dto.art,
            banner: dto.banner,
            clearLogo: dto.clearLogo,
            rating: dto.rating,
            audienceRating: dto.audienceRating,
            duration: dto.duration,
            playCount: dto.viewCount,
            resumeOffsetMs: dto.viewOffset,
            lastPlayedAt: dto.lastViewedAt,
            addedAt: dto.addedAt,
            updatedAt: dto.updatedAt,
            index: dto.index,
            parentIndex: dto.parentIndex,
            parentID: dto.parentRatingKey,
            parentTitle: dto.parentTitle,
            parentThumb: dto.parentThumb,
            grandparentID: dto.grandparentRatingKey,
            grandparentTitle: dto.grandparentTitle,
            grandparentThumb: dto.grandparentThumb,
            grandparentArt: dto.grandparentArt,
            episodeCount: dto.leafCount,
            watchedEpisodeCount: dto.viewedLeafCount,
            childCount: dto.childCount,
            smart: dto.smart,
            genres: dto.genres?.map { Self.map($0) },
            directors: dto.directors?.map { Self.map($0) },
            writers: dto.writers?.map { Self.map($0) },
            roles: dto.roles?.map { Self.map($0) },
            guid: dto.guid,
            guids: dto.guids
        )
    }

    static func map(_ dto: PlexMediaDetailsDTO, serverID: String?) -> MediaDetails {
        MediaDetails(
            serverID: serverID?.nilIfEmpty,
            itemID: dto.ratingKey,
            key: dto.key,
            type: dto.type,
            subtype: dto.subtype,
            libraryID: dto.librarySectionID,
            librarySectionTitle: dto.librarySectionTitle,
            title: dto.title,
            editionTitle: MediaItem.trimmedEditionTitle(dto.editionTitle),
            summary: dto.summary,
            year: dto.year,
            duration: dto.duration,
            resumeOffsetMs: dto.viewOffset,
            playCount: dto.viewCount,
            thumb: dto.thumb,
            art: dto.art,
            clearLogo: dto.clearLogo,
            contentRating: dto.contentRating,
            primaryExtraKey: dto.primaryExtraKey,
            rating: dto.rating,
            audienceRating: dto.audienceRating,
            ratingImage: dto.ratingImage,
            audienceRatingImage: dto.audienceRatingImage,
            userRating: dto.userRating,
            ratings: dto.ratings,
            studio: dto.studio,
            originallyAvailableAt: dto.originallyAvailableAt,
            childCount: dto.childCount,
            episodeCount: dto.leafCount,
            watchedEpisodeCount: dto.viewedLeafCount,
            index: dto.index,
            parentIndex: dto.parentIndex,
            parentID: dto.parentRatingKey,
            parentThumb: dto.parentThumb,
            grandparentID: dto.grandparentRatingKey,
            grandparentTitle: dto.grandparentTitle,
            grandparentThumb: dto.grandparentThumb,
            genres: dto.genres?.map { Self.map($0) },
            directors: dto.directors?.map { Self.map($0) },
            writers: dto.writers?.map { Self.map($0) },
            roles: dto.roles?.map { Self.map($0) },
            collections: dto.collections?.map { Self.map($0) },
            guid: dto.guid,
            guids: dto.guids,
            markers: dto.markers.sorted { $0.startTimeOffset < $1.startTimeOffset },
            media: dto.media
        )
    }

    static func map(_ dto: PlexEpisodeDTO, serverID: String?) -> Episode {
        Episode(
            serverID: serverID?.nilIfEmpty,
            itemID: dto.ratingKey,
            key: dto.key,
            title: dto.title,
            index: dto.index,
            parentIndex: dto.parentIndex,
            parentID: dto.parentRatingKey,
            parentTitle: dto.parentTitle,
            grandparentID: dto.grandparentRatingKey,
            grandparentTitle: dto.grandparentTitle,
            grandparentThumb: dto.grandparentThumb,
            summary: dto.summary,
            contentRating: dto.contentRating,
            originallyAvailableAt: dto.originallyAvailableAt,
            year: dto.year,
            thumb: dto.thumb,
            art: dto.art,
            duration: dto.duration,
            playCount: dto.viewCount,
            resumeOffsetMs: dto.viewOffset,
            lastPlayedAt: dto.lastViewedAt,
            addedAt: dto.addedAt,
            updatedAt: dto.updatedAt
        )
    }

    static func map(_ dto: PlexSeasonDTO, serverID: String?) -> Season {
        Season(
            serverID: serverID?.nilIfEmpty,
            itemID: dto.ratingKey,
            key: dto.key,
            title: dto.title,
            index: dto.index,
            parentID: dto.parentRatingKey,
            parentTitle: dto.parentTitle,
            parentThumb: dto.parentThumb,
            thumb: dto.thumb,
            art: dto.art,
            episodeCount: dto.leafCount,
            watchedEpisodeCount: dto.viewedLeafCount,
            addedAt: dto.addedAt,
            updatedAt: dto.updatedAt
        )
    }

    static func map(_ dto: PlexLibraryDTO, serverID: String?) -> Library {
        Library(
            serverID: serverID?.nilIfEmpty,
            key: dto.key,
            title: dto.title,
            type: dto.type,
            subtype: dto.subtype,
            agent: dto.agent,
            scanner: dto.scanner,
            language: dto.language,
            uuid: dto.uuid,
            updatedAt: dto.updatedAt,
            createdAt: dto.createdAt,
            scannedAt: dto.scannedAt,
            thumb: dto.thumb,
            art: dto.art,
            composite: dto.composite,
            visibility: dto.hidden
        )
    }

    static func map(_ dto: PlexTagDTO) -> Tag {
        Tag(tag: dto.tag, id: dto.id)
    }

    static func map(_ dto: PlexRoleDTO) -> Person {
        Person(
            id: dto.id,
            filter: dto.filter,
            tag: dto.tag,
            tagKey: dto.tagKey,
            role: dto.role,
            thumb: dto.thumb
        )
    }

    /// The person id is the numeric `id`, or the value of `filter`
    /// (`actor=12345`) when a server leaves the id out.
    static func map(_ dto: PlexPersonDTO) -> PlexPerson {
        PlexPerson(
            personID: dto.id.map(String.init) ?? personID(fromFilter: dto.filter),
            filter: dto.filter,
            tag: dto.tag,
            tagKey: dto.tagKey,
            thumb: dto.thumb
        )
    }

    private static func personID(fromFilter filter: String?) -> String? {
        guard let filter,
              let value = filter.split(separator: "=").last,
              !value.isEmpty else {
            return nil
        }

        return String(value)
    }
}
