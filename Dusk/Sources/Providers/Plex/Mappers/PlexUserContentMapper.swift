import Foundation

/// Plex DTOs → domain values for playlists, extras, photos, the Watchlist,
/// managed Home rows, subtitle search and playback history.
///
/// `serverID` is the server the payload came from. It is stamped here, not by
/// the decoder; callers pass the id `decodeJSON(_:from:serverID:)` was given
/// (the resolved target server), and an empty id counts as none, as the
/// decoder stamp did.
enum PlexUserContentMapper {
    // MARK: Playlists

    static func playlist(_ dto: PlexPlaylistDTO, serverID: String?) -> Playlist {
        Playlist(
            serverID: serverID?.nilIfEmpty,
            itemID: dto.itemID,
            title: dto.title,
            summary: dto.summary,
            smart: dto.smart,
            playlistType: dto.playlistType,
            composite: dto.composite,
            thumb: dto.thumb,
            duration: dto.duration,
            episodeCount: dto.episodeCount,
            playCount: dto.playCount,
            lastPlayedAt: dto.lastPlayedAt,
            addedAt: dto.addedAt,
            updatedAt: dto.updatedAt
        )
    }

    static func playlistEntry(_ dto: PlexPlaylistEntryDTO, serverID: String?) -> PlaylistEntry {
        PlaylistEntry(playlistItemID: dto.playlistItemID, item: PlexItemMapper.map(dto.item, serverID: serverID))
    }

    // MARK: Extras

    /// Pairs decoded items with their extra fields by rating key, in Plex's
    /// order. Only clips are extras; anything else in the payload is dropped.
    static func extras(items: [MediaItem], fields: [PlexExtraFieldsDTO]) -> [Extra] {
        let fieldsByKey = Dictionary(fields.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        return items.compactMap { item in
            guard item.isClip else { return nil }
            let field = fieldsByKey[item.itemID]
            return Extra(
                item: item,
                kind: ExtraKind(extraType: field?.extraType, subtype: field?.subtype ?? item.subtype)
            )
        }
    }

    // MARK: Photos

    static func photoItem(_ dto: PlexPhotoItemDTO, serverID: String?) -> PhotoItem {
        let kind: PhotoItem.Kind?
        switch dto.type {
        case "photo":
            // An album and a photo are both `photo`; only an album's key
            // ends in `/children`.
            kind = dto.key.hasSuffix("/children") ? .album : .photo
        case "clip":
            kind = .clip
        default:
            kind = nil
        }
        return PhotoItem(
            serverID: serverID?.nilIfEmpty,
            itemID: dto.itemID,
            key: dto.key,
            kind: kind,
            title: dto.title,
            thumb: dto.thumb,
            composite: dto.composite,
            originallyAvailableAt: dto.originallyAvailableAt,
            addedAt: dto.addedAt,
            year: dto.year,
            duration: dto.duration,
            width: dto.width,
            height: dto.height,
            partKey: dto.partKey,
            make: dto.make,
            model: dto.model,
            places: dto.places
        )
    }

    // MARK: Watchlist

    static func watchlistEntry(_ dto: PlexWatchlistEntryDTO) -> WatchlistEntry {
        WatchlistEntry(
            itemID: dto.itemID,
            guid: dto.guid,
            type: dto.type,
            title: dto.title,
            year: dto.year,
            thumb: dto.thumb,
            art: dto.art,
            summary: dto.summary,
            contentRating: dto.contentRating,
            duration: dto.duration,
            childCount: dto.childCount,
            guids: dto.guids.map { ItemGuid(id: $0) }
        )
    }

    static func watchlistAvailability(_ dto: PlexWatchlistAvailabilityDTO) -> WatchlistAvailability {
        WatchlistAvailability(title: dto.title, offerType: dto.offerType)
    }

    // MARK: Subtitle search

    /// A real non-zero id is the identity; otherwise the provider `key` is.
    static func subtitleSearchResult(_ dto: PlexSubtitleSearchResultDTO) -> SubtitleSearchResult {
        SubtitleSearchResult(
            id: dto.rawID.flatMap { $0 != 0 ? String($0) : nil },
            key: dto.key,
            codec: dto.codec,
            title: dto.title,
            providerTitle: dto.providerTitle,
            sourceTitle: dto.sourceTitle,
            score: dto.score,
            languageCode: dto.languageCode,
            language: dto.language,
            isHearingImpaired: dto.isHearingImpaired,
            isForced: dto.isForced,
            format: dto.format
        )
    }

    // MARK: Playback history

    static func playbackHistoryEntry(_ dto: PlexPlaybackHistoryEntryDTO, serverID: String?) -> PlaybackHistoryEntry {
        PlaybackHistoryEntry(
            serverID: serverID?.nilIfEmpty,
            historyKey: dto.historyKey,
            itemID: dto.itemID,
            libraryID: dto.libraryID,
            parentID: dto.parentID,
            grandparentID: dto.grandparentID,
            type: dto.type,
            title: dto.title,
            parentTitle: dto.parentTitle,
            grandparentTitle: dto.grandparentTitle,
            viewedAt: dto.viewedAt,
            accountID: dto.accountID
        )
    }
}
