import Foundation

/// Jellyfin `BaseItemDto` → collections, playlists and watchlist entries
/// (docs/jellyfin/02-jellyfin-api-mapping.md §5, §8; 04 §9, §17, §21 row 2).
extension JellyfinItemMapper {
    // MARK: Collections

    /// A BoxSet as a collection item. Jellyfin draws no artwork for a BoxSet
    /// nobody gave one (Plex draws a mosaic), so it borrows its first
    /// title's poster. The count and the noun come from the titles the user
    /// can see (`memberKinds`): all films is "movie", all shows is "show".
    static func collection(
        _ dto: JellyfinItemDTO,
        serverID: String?,
        memberKinds: [MediaKind],
        fallbackPoster: String?
    ) -> MediaItem {
        let item = map(dto, serverID: serverID)
        let kinds = Set(memberKinds)
        let subtype: String? = switch kinds {
        case [.movie]: "movie"
        case [.show]: "show"
        default: nil
        }
        return replacing(item, subtype: subtype, thumb: item.thumb ?? fallbackPoster, childCount: memberKinds.count)
    }

    // MARK: Playlists

    /// `ChildCount` is the number of entries, `RunTimeTicks` their total, and
    /// the server draws the mosaic as the playlist's `Primary` image. Jellyfin
    /// has no smart playlists.
    /// `entriesDuration` (the entries' runtimes summed) replaces
    /// `RunTimeTicks` when given; 0 is an empty playlist.
    static func playlist(_ dto: JellyfinItemDTO, serverID: String?, entriesDuration: Int? = nil) -> Playlist {
        Playlist(
            serverID: normalizedServerID(serverID),
            itemID: JellyfinID.normalized(dto.id),
            title: dto.name ?? "",
            summary: dto.overview?.nilIfEmpty,
            smart: false,
            playlistType: dto.mediaType.map { $0 == .video ? "video" : $0.rawValue.lowercased() } ?? "video",
            composite: JellyfinArtworkLocator.path(itemID: dto.id, type: .primary, tag: dto.imageTag(.primary)),
            thumb: nil,
            duration: entriesDuration.map { $0 > 0 ? $0 : nil } ?? duration(dto),
            episodeCount: dto.childCount,
            addedAt: epochSeconds(dto.dateCreated)
        )
    }

    /// Entries in playlist order. Jellyfin keys an entry by its item, so the
    /// repeats of one item share a handle and are numbered.
    static func playlistEntries(_ dtos: [JellyfinItemDTO], serverID: String?) -> [PlaylistEntry] {
        var seen: [String: Int] = [:]
        return dtos.map { dto in
            let handle = dto.playlistItemID?.nilIfEmpty
            let key = handle ?? JellyfinID.normalized(dto.id)
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            return PlaylistEntry(playlistItemID: handle, item: map(dto, serverID: serverID), occurrence: occurrence)
        }
    }

    // MARK: Watchlist

    /// The Watchlist on Jellyfin is the user's favourite films and shows
    /// (04 §21 row 2). An entry is the server's own title: `serverItem`
    /// is set, so nothing is looked up, and the key names the server and the
    /// item. No artwork of its own (`thumb` is for plex.tv's absolute links;
    /// the card draws the server item's).
    static func watchlistEntry(for item: MediaItem) -> WatchlistEntry? {
        guard item.type == .movie || item.type == .show, let serverID = item.serverID else { return nil }
        return WatchlistEntry(
            itemID: item.itemID,
            guid: watchlistKey(serverID: serverID, itemID: item.itemID),
            type: item.type,
            title: item.title,
            year: item.year,
            summary: item.summary,
            contentRating: item.contentRating,
            duration: item.duration,
            childCount: item.childCount,
            guids: item.guids,
            serverItem: item
        )
    }

    static func watchlistEntry(for details: MediaDetails) -> WatchlistEntry? {
        guard details.type == .movie || details.type == .show, let serverID = details.serverID else { return nil }
        return WatchlistEntry(
            itemID: details.itemID,
            guid: watchlistKey(serverID: serverID, itemID: details.itemID),
            type: details.type,
            title: details.title,
            year: details.year,
            summary: details.summary,
            contentRating: details.contentRating,
            duration: details.duration,
            childCount: details.childCount,
            guids: details.guids
        )
    }

    /// `jellyfin://<server>/<item>`: unique across servers, and never a
    /// `ContentKey` input (it is the entry's key, not the item's guid).
    static func watchlistKey(serverID: String, itemID: String) -> String {
        "jellyfin://\(JellyfinID.normalized(serverID))/\(JellyfinID.normalized(itemID))"
    }

    /// The server and item of a `watchlistKey`.
    static func watchlistTarget(_ key: String) -> (serverID: String, itemID: String)? {
        let prefix = "jellyfin://"
        guard key.hasPrefix(prefix) else { return nil }
        let parts = key.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    // MARK: Helpers

    /// `item` with a few fields replaced; `MediaItem` is immutable.
    static func replacing(_ item: MediaItem, subtype: String?, thumb: String?, childCount: Int?) -> MediaItem {
        MediaItem(
            serverID: item.serverID,
            itemID: item.itemID,
            key: item.key,
            type: item.type,
            subtype: subtype,
            libraryID: item.libraryID,
            title: item.title,
            editionTitle: item.editionTitle,
            summary: item.summary,
            studio: item.studio,
            contentRating: item.contentRating,
            year: item.year,
            originallyAvailableAt: item.originallyAvailableAt,
            thumb: thumb,
            art: item.art,
            banner: item.banner,
            clearLogo: item.clearLogo,
            rating: item.rating,
            audienceRating: item.audienceRating,
            duration: item.duration,
            playCount: item.playCount,
            resumeOffsetMs: item.resumeOffsetMs,
            lastPlayedAt: item.lastPlayedAt,
            addedAt: item.addedAt,
            updatedAt: item.updatedAt,
            index: item.index,
            parentIndex: item.parentIndex,
            parentID: item.parentID,
            parentTitle: item.parentTitle,
            parentThumb: item.parentThumb,
            grandparentID: item.grandparentID,
            grandparentTitle: item.grandparentTitle,
            grandparentThumb: item.grandparentThumb,
            grandparentArt: item.grandparentArt,
            episodeCount: item.episodeCount,
            watchedEpisodeCount: item.watchedEpisodeCount,
            childCount: childCount,
            smart: item.smart,
            genres: item.genres,
            directors: item.directors,
            writers: item.writers,
            roles: item.roles,
            guid: item.guid,
            guids: item.guids
        )
    }
}
