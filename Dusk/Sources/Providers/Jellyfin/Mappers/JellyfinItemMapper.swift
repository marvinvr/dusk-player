import Foundation

/// Jellyfin `BaseItemDto` → the domain's item family: `MediaItem`,
/// `MediaDetails`, `Season`, `Episode`, `Library`, cast and crew, external ids
/// and ratings (docs/jellyfin/02-jellyfin-api-mapping.md §2 – §6, §12;
/// 04 §4.2, §6, §10).
///
/// Like `PlexItemMapper`, every function takes the `serverID` of the server
/// the payload came from (the Jellyfin `ServerId`) and stamps it on all it
/// builds. Ids (item, parent, grandparent, server) are normalised to 32
/// lower-case hex characters before they become domain ids (03 §10.3).
///
/// Conversions done once, here:
/// - ticks → milliseconds, ISO dates → epoch seconds;
/// - `PremiereDate` → `originallyAvailableAt` (`YYYY-MM-DD`), rounded to the
///   nearest UTC day, because episode and person dates are local midnight
///   stored as UTC (`2005-03-23T23:00:00Z` is 24 March, 02 §6);
/// - watched state from `UserData.Played`, not `PlayCount`: the server bumps
///   `PlayCount` on every playback start (02 §8), and the domain reads
///   `playCount > 0` as watched;
/// - `ProviderIds` → `Guid`-style uris (`tmdb://546554`), tmdb, imdb, tvdb;
/// - image tags → `jf:` artwork locators (`JellyfinArtworkLocator`), each on
///   the item that owns the image. `Thumb` (landscape with the title baked
///   in) is never used.
enum JellyfinItemMapper {
    // MARK: Items

    static func map(_ dto: JellyfinItemDTO, serverID: String?, libraryID: String? = nil) -> MediaItem {
        let kind = mediaKind(dto)
        let art = artwork(dto, kind: kind)
        let watch = watchState(dto)
        let counts = episodeCounts(dto, kind: kind)
        let people = credits(dto)
        let ids = externalIDs(dto)
        return MediaItem(
            serverID: normalizedServerID(serverID),
            itemID: JellyfinID.normalized(dto.id),
            key: itemPath(dto.id),
            type: kind,
            subtype: nil,
            libraryID: libraryID?.nilIfEmpty,
            title: dto.name ?? "",
            editionTitle: nil,
            summary: dto.overview?.nilIfEmpty,
            studio: dto.studios?.lazy.compactMap { $0.name?.nilIfEmpty }.first,
            contentRating: dto.officialRating?.nilIfEmpty,
            year: dto.productionYear,
            originallyAvailableAt: airDate(dto.premiereDate),
            thumb: art.poster,
            art: art.backdrop,
            banner: art.banner,
            clearLogo: art.logo,
            rating: criticRating(dto),
            audienceRating: dto.communityRating,
            duration: duration(dto),
            playCount: watch.playCount,
            resumeOffsetMs: watch.resumeOffsetMs,
            lastPlayedAt: watch.lastPlayedAt,
            addedAt: epochSeconds(dto.dateCreated),
            updatedAt: nil,
            index: dto.indexNumber,
            parentIndex: kind == .episode ? dto.parentIndexNumber : nil,
            parentID: parentID(dto, kind: kind),
            parentTitle: parentTitle(dto, kind: kind),
            parentThumb: art.parentPoster,
            grandparentID: kind == .episode ? dto.seriesID.map(JellyfinID.normalized) : nil,
            grandparentTitle: kind == .episode ? dto.seriesName?.nilIfEmpty : nil,
            grandparentThumb: art.grandparentPoster,
            grandparentArt: art.grandparentBackdrop,
            episodeCount: counts.episodes,
            watchedEpisodeCount: counts.watched,
            childCount: kind == .show ? dto.childCount : nil,
            smart: nil,
            genres: genres(dto),
            directors: people.directors,
            writers: people.writers,
            roles: people.roles,
            guid: nil,
            guids: ids
        )
    }

    // MARK: Details

    /// `GET /Items/{id}?userId=`. Markers come from `MediaSegments`
    /// (`JellyfinMediaMapper.markers`), a separate call, so `markers` is
    /// empty unless they are passed in.
    static func mapDetails(
        _ dto: JellyfinItemDTO,
        serverID: String?,
        libraryID: String? = nil,
        libraryTitle: String? = nil,
        markers: [Marker] = []
    ) -> MediaDetails {
        let item = map(dto, serverID: serverID, libraryID: libraryID)
        return MediaDetails(
            serverID: item.serverID,
            itemID: item.itemID,
            key: item.key,
            type: item.type,
            subtype: item.subtype,
            libraryID: item.libraryID,
            librarySectionTitle: libraryTitle?.nilIfEmpty,
            title: item.title,
            editionTitle: nil,
            summary: item.summary,
            year: item.year,
            duration: item.duration,
            resumeOffsetMs: item.resumeOffsetMs,
            playCount: item.playCount,
            thumb: item.thumb,
            art: item.art,
            clearLogo: item.clearLogo,
            contentRating: item.contentRating,
            primaryExtraKey: nil,
            rating: item.rating,
            audienceRating: item.audienceRating,
            ratingImage: nil,
            audienceRatingImage: nil,
            userRating: nil,
            ratings: ratings(dto),
            studio: item.studio,
            originallyAvailableAt: item.originallyAvailableAt,
            childCount: item.childCount,
            episodeCount: item.episodeCount,
            watchedEpisodeCount: item.watchedEpisodeCount,
            index: item.index,
            parentIndex: item.parentIndex,
            parentID: item.parentID,
            parentThumb: item.parentThumb,
            grandparentID: item.grandparentID,
            grandparentTitle: item.grandparentTitle,
            grandparentThumb: item.grandparentThumb,
            genres: item.genres,
            directors: item.directors,
            writers: item.writers,
            roles: item.roles,
            collections: nil,
            guid: nil,
            guids: item.guids,
            markers: markers,
            media: JellyfinMediaMapper.map(dto.mediaSources ?? [], itemID: dto.id)
        )
    }

    // MARK: Seasons and episodes

    static func mapSeason(_ dto: JellyfinItemDTO, serverID: String?) -> Season {
        let item = map(dto, serverID: serverID)
        return Season(
            serverID: item.serverID,
            itemID: item.itemID,
            key: item.key,
            title: item.title,
            index: dto.indexNumber ?? 0,
            parentID: item.parentID,
            parentTitle: item.parentTitle,
            parentThumb: item.parentThumb,
            thumb: item.thumb,
            art: item.art,
            episodeCount: item.episodeCount,
            watchedEpisodeCount: item.watchedEpisodeCount,
            addedAt: item.addedAt,
            updatedAt: nil
        )
    }

    static func mapEpisode(_ dto: JellyfinItemDTO, serverID: String?) -> Episode {
        let item = map(dto, serverID: serverID)
        return Episode(
            serverID: item.serverID,
            itemID: item.itemID,
            key: item.key,
            title: item.title,
            index: item.index,
            parentIndex: item.parentIndex,
            parentID: item.parentID,
            parentTitle: item.parentTitle,
            grandparentID: item.grandparentID,
            grandparentTitle: item.grandparentTitle,
            grandparentThumb: item.grandparentThumb,
            summary: item.summary,
            contentRating: item.contentRating,
            originallyAvailableAt: item.originallyAvailableAt,
            year: item.year,
            thumb: item.thumb,
            art: item.art,
            duration: item.duration,
            playCount: item.playCount,
            resumeOffsetMs: item.resumeOffsetMs,
            lastPlayedAt: item.lastPlayedAt,
            addedAt: item.addedAt,
            updatedAt: nil
        )
    }

    // MARK: Libraries

    /// A user view (`GET /UserViews`) as a library tab, or nil for views that
    /// are not libraries in Dusk's sense (collections, playlists, Live TV,
    /// music, books). Home videos become a movie section with the `clip`
    /// subtype, which is how `Library.libraryType` already recognises a
    /// Videos library; a `homevideos` view that holds mostly photos
    /// (`homeVideosHoldPhotos`, counted by the catalog) is a photo library.
    static func mapLibrary(_ dto: JellyfinItemDTO, serverID: String?, homeVideosHoldPhotos: Bool = false) -> Library? {
        let type: String
        var subtype: String?
        switch dto.collectionType {
        case let value? where value.matches(.movies): type = "movie"
        case let value? where value.matches(.tvShows): type = "show"
        case let value? where value.matches(.homeVideos) && homeVideosHoldPhotos: type = "photo"
        case let value? where value.matches(.homeVideos), let value? where value.matches(.musicVideos):
            type = "movie"
            subtype = "clip"
        case let value? where value.matches(.photos): type = "photo"
        default: return nil
        }
        let id = JellyfinID.normalized(dto.id)
        return Library(
            serverID: normalizedServerID(serverID),
            key: id,
            title: dto.name ?? "",
            type: type,
            subtype: subtype,
            agent: nil,
            scanner: nil,
            language: nil,
            uuid: id,
            updatedAt: nil,
            createdAt: epochSeconds(dto.dateCreated),
            scannedAt: nil,
            thumb: JellyfinArtworkLocator.path(itemID: dto.id, type: .primary, tag: dto.imageTag(.primary)),
            art: JellyfinArtworkLocator.path(itemID: dto.id, type: .backdrop, tag: dto.backdropImageTags?.first),
            composite: nil,
            visibility: .included
        )
    }

    // MARK: People

    /// A person page's subject (`GET /Items/{personId}`).
    static func mapPerson(_ dto: JellyfinItemDTO) -> PersonDetails {
        PersonDetails(
            personID: JellyfinID.normalized(dto.id),
            filter: nil,
            tag: dto.name ?? "",
            tagKey: nil,
            thumb: JellyfinArtworkLocator.path(itemID: dto.id, type: .primary, tag: dto.imageTag(.primary))
        )
    }

    /// A cast member. `Person.id` is an `Int` (a Plex tag id) and cannot hold
    /// a Jellyfin GUID, so it stays nil and the person id rides in `filter`
    /// (`personIds=<id>`), which `Person.personID` reads the way it reads
    /// Plex's `actor=<id>`; `tagKey` keeps it too.
    static func mapRole(_ dto: JellyfinPersonDTO) -> Person {
        Person(
            id: nil,
            filter: "personIds=\(JellyfinID.normalized(dto.id))",
            tag: dto.name ?? "",
            tagKey: JellyfinID.normalized(dto.id),
            role: dto.role?.nilIfEmpty,
            thumb: JellyfinArtworkLocator.path(itemID: dto.id, type: .primary, tag: dto.primaryImageTag)
        )
    }

    // MARK: Field helpers

    static func mediaKind(_ dto: JellyfinItemDTO) -> MediaKind {
        guard let type = dto.type else { return .unknown }
        let table: [(JellyfinItemKind, MediaKind)] = [
            (.movie, .movie), (.series, .show), (.season, .season), (.episode, .episode),
            (.video, .clip), (.trailer, .clip), (.boxSet, .collection), (.person, .person),
        ]
        return table.first { type.matches($0.0) }?.1 ?? .unknown
    }

    static func itemPath(_ id: String) -> String {
        "/Items/\(JellyfinID.normalized(id))"
    }

    static func normalizedServerID(_ serverID: String?) -> String? {
        serverID?.nilIfEmpty.map(JellyfinID.normalized)
    }

    static func duration(_ dto: JellyfinItemDTO) -> Int? {
        guard let ticks = dto.runTimeTicks, ticks.rawValue > 0 else { return nil }
        return ticks.milliseconds
    }

    struct WatchState: Equatable {
        var playCount: Int?
        var resumeOffsetMs: Int?
        var lastPlayedAt: Int?
    }

    /// Plex shape: `viewCount` only when watched, `viewOffset` only when there
    /// is a resume point.
    static func watchState(_ dto: JellyfinItemDTO) -> WatchState {
        guard let data = dto.userData else { return WatchState() }
        let position = data.playbackPositionTicks.map(\.milliseconds) ?? 0
        return WatchState(
            playCount: data.played == true ? max(data.playCount ?? 1, 1) : nil,
            resumeOffsetMs: position > 0 ? position : nil,
            lastPlayedAt: epochSeconds(data.lastPlayedDate)
        )
    }

    /// Shows: `RecursiveItemCount` episodes. Seasons: the same, or
    /// `ChildCount`. Watched = total − `UserData.UnplayedItemCount` (02 §6).
    static func episodeCounts(_ dto: JellyfinItemDTO, kind: MediaKind) -> (episodes: Int?, watched: Int?) {
        guard kind == .show || kind == .season else { return (nil, nil) }
        let total = dto.recursiveItemCount ?? (kind == .season ? dto.childCount : nil)
        guard let total else { return (nil, nil) }
        guard let unplayed = dto.userData?.unplayedItemCount else { return (total, nil) }
        return (total, max(0, total - unplayed))
    }

    static func parentID(_ dto: JellyfinItemDTO, kind: MediaKind) -> String? {
        switch kind {
        case .episode: dto.seasonID.map(JellyfinID.normalized)
        case .season: (dto.seriesID ?? dto.parentID).map(JellyfinID.normalized)
        default: nil
        }
    }

    static func parentTitle(_ dto: JellyfinItemDTO, kind: MediaKind) -> String? {
        switch kind {
        case .episode: dto.seasonName?.nilIfEmpty
        case .season: dto.seriesName?.nilIfEmpty
        default: nil
        }
    }

    static func genres(_ dto: JellyfinItemDTO) -> [Tag]? {
        let names = dto.genreItems?.compactMap { $0.name?.nilIfEmpty } ?? dto.genres ?? []
        return names.isEmpty ? nil : names.map { Tag(tag: $0) }
    }

    /// `People[]` split on `Type`, as Plex's `Role` / `Director` / `Writer`.
    static func credits(_ dto: JellyfinItemDTO) -> (roles: [Person]?, directors: [Tag]?, writers: [Tag]?) {
        guard let people = dto.people, !people.isEmpty else { return (nil, nil, nil) }
        let roles = people.filter { $0.type?.matches(.actor) == true || $0.type?.matches(.guestStar) == true }
        let directors = people.filter { $0.type?.matches(.director) == true }
        let writers = people.filter { $0.type?.matches(.writer) == true }
        func tags(_ list: [JellyfinPersonDTO]) -> [Tag]? {
            let names = list.compactMap { $0.name?.nilIfEmpty }
            return names.isEmpty ? nil : names.map { Tag(tag: $0) }
        }
        return (roles.isEmpty ? nil : roles.map(mapRole), tags(directors), tags(writers))
    }

    // MARK: External ids

    /// The namespaces Dusk matches on, in the order `ContentKey` prefers them.
    /// Other `ProviderIds` (`TmdbCollection`, `TvRage`, …) are not ids of the
    /// item itself and Plex never sends them, so they are left out.
    static let externalNamespaces = ["tmdb", "imdb", "tvdb"]

    static func externalIDs(_ dto: JellyfinItemDTO) -> [ItemGuid] {
        externalNamespaces.compactMap { namespace in
            dto.providerID(namespace)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                .map { ItemGuid(id: "\(namespace)://\($0)") }
        }
    }

    // MARK: Ratings

    /// `CriticRating` is 0–100; the domain's `rating` is 0–10.
    static func criticRating(_ dto: JellyfinItemDTO) -> Double? {
        dto.criticRating.map { $0 / 10 }
    }

    /// Both scores on the domain's 0–10 scale. Jellyfin names no source, so
    /// `image` is nil (no logo, no assumed TMDB/Rotten Tomatoes mark, 02 §6).
    static func ratings(_ dto: JellyfinItemDTO) -> [Rating] {
        [
            criticRating(dto).map { Rating(image: nil, value: $0, type: "critic") },
            dto.communityRating.map { Rating(image: nil, value: $0, type: "audience") },
        ].compactMap { $0 }
    }

    // MARK: Dates

    static func epochSeconds(_ date: JellyfinDate?) -> Int? {
        guard let value = date?.date?.timeIntervalSince1970 else { return nil }
        return Int(value.rounded(.down))
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `YYYY-MM-DD` of the nearest UTC midnight.
    static func airDate(_ date: JellyfinDate?) -> String? {
        guard let date = date?.date else { return nil }
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 86_400).rounded() * 86_400)
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: rounded)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: Artwork

    struct Artwork: Equatable {
        var poster: String?
        var backdrop: String?
        var banner: String?
        var logo: String?
        var parentPoster: String?
        var grandparentPoster: String?
        var grandparentBackdrop: String?
    }

    /// Every slot from the tags the item carries, each locator naming the
    /// item that owns the image:
    ///
    /// | slot | own | episode | season |
    /// | --- | --- | --- | --- |
    /// | poster | `ImageTags.Primary` | still | season poster |
    /// | backdrop | `BackdropImageTags[0]` | else show backdrop | else show backdrop |
    /// | logo | `ImageTags.Logo` | else show logo | else show logo |
    /// | parentPoster | — | season poster | show poster |
    /// | grandparentPoster | — | show poster | — |
    /// | grandparentBackdrop | — | show backdrop | — |
    static func artwork(_ dto: JellyfinItemDTO, kind: MediaKind) -> Artwork {
        let ownBackdrop = JellyfinArtworkLocator.path(itemID: dto.id, type: .backdrop, tag: dto.backdropImageTags?.first)
        let parentBackdrop = JellyfinArtworkLocator.path(
            itemID: dto.parentBackdropItemID, type: .backdrop, tag: dto.parentBackdropImageTags?.first
        )
        let ownLogo = JellyfinArtworkLocator.path(itemID: dto.id, type: .logo, tag: dto.imageTag(.logo))
        let parentLogo = JellyfinArtworkLocator.path(itemID: dto.parentLogoItemID, type: .logo, tag: dto.parentLogoImageTag)
        let showPoster = JellyfinArtworkLocator.path(itemID: dto.seriesID, type: .primary, tag: dto.seriesPrimaryImageTag)

        var art = Artwork(
            poster: JellyfinArtworkLocator.path(itemID: dto.id, type: .primary, tag: dto.imageTag(.primary)),
            backdrop: ownBackdrop,
            banner: JellyfinArtworkLocator.path(itemID: dto.id, type: .banner, tag: dto.imageTag(.banner)),
            logo: ownLogo
        )
        switch kind {
        case .episode:
            art.backdrop = ownBackdrop ?? parentBackdrop
            art.logo = ownLogo ?? parentLogo
            art.parentPoster = JellyfinArtworkLocator.path(
                itemID: dto.parentPrimaryImageItemID, type: .primary, tag: dto.parentPrimaryImageTag
            ) ?? showPoster
            art.grandparentPoster = showPoster
            art.grandparentBackdrop = parentBackdrop
        case .season:
            art.backdrop = ownBackdrop ?? parentBackdrop
            art.logo = ownLogo ?? parentLogo
            art.parentPoster = showPoster
        default:
            break
        }
        return art
    }
}
