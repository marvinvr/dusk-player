import Foundation

/// The playlist-level actions both the Playlists grid (context menu) and the
/// playlist page offer: build a play queue, rename, delete. Every edit goes to
/// the playlist's own server first and only then into `PlexService.playlists`.
@MainActor
struct PlaylistActions {
    let plexService: PlexService

    /// The queue for a whole playlist: in order from `startIndex`, or
    /// shuffled once for the session.
    func queue(for playlist: PlexPlaylist, entries: [PlexPlaylistEntry], startIndex: Int = 0, shuffled: Bool = false) -> PlaybackQueue? {
        let items = entries.map { PlaybackQueueItem(item: $0.item) }
        if shuffled {
            return PlaybackQueue.shuffledPlaylist(id: playlist.id, title: playlist.title, items: items)
        }
        return PlaybackQueue.playlist(id: playlist.id, title: playlist.title, items: items, startIndex: startIndex)
    }

    /// Fetches the entries first (the grid has none loaded).
    func queue(for playlist: PlexPlaylist, shuffled: Bool) async throws -> (queue: PlaybackQueue?, entries: [PlexPlaylistEntry]) {
        let entries = try await plexService.getPlaylistEntries(ratingKey: playlist.ratingKey, serverID: playlist.serverID)
        let start = shuffled ? 0 : PlaylistActions.resumeIndex(in: entries) ?? 0
        return (queue(for: playlist, entries: entries, startIndex: start, shuffled: shuffled), entries)
    }

    func rename(_ playlist: PlexPlaylist, to title: String) async throws -> PlexPlaylist {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != playlist.title else { return playlist }
        let session = plexService.playlists.sessionGeneration
        try await plexService.renamePlaylist(playlist, to: trimmed)
        let renamed = playlist.renamed(trimmed)
        plexService.playlists.upsert(renamed, sessionGeneration: session)
        plexService.pinnedPlaylists.updateTitle(trimmed, for: playlist.id, profileID: plexService.activeProfileID)
        return renamed
    }

    func delete(_ playlist: PlexPlaylist) async throws {
        let session = plexService.playlists.sessionGeneration
        try await plexService.deletePlaylist(playlist)
        plexService.playlists.remove(playlist.id, sessionGeneration: session)
        plexService.setPlaylistPinned(false, id: playlist.id, title: playlist.title)
    }

    /// Where Play / Resume starts: the first item that is not fully watched
    /// (in progress or never watched). Nil when every item is watched.
    static func resumeIndex(in entries: [PlexPlaylistEntry]) -> Int? {
        entries.firstIndex { entry in
            entry.item.isPartiallyWatched || !entry.item.isWatched
        }
    }

    /// "Resume" once anything has been watched or is in progress; plain
    /// "Play" for an untouched (or fully watched) playlist.
    static func playButtonTitle(for entries: [PlexPlaylistEntry]) -> String {
        guard resumeIndex(in: entries) != nil else { return "Play" }
        let started = entries.contains { $0.item.isWatched || $0.item.isPartiallyWatched }
        return started ? "Resume" : "Play"
    }

    /// `12 items · 18 h 20 min`, then `7 watched` and `Smart` where they apply.
    static func metadataLine(for playlist: PlexPlaylist, entries: [PlexPlaylistEntry]?, serverName: String?) -> String? {
        var parts: [String] = []
        let count = entries?.count ?? playlist.leafCount
        if let count {
            parts.append(count == 1 ? "1 item" : "\(count) items")
        }
        if let duration = MediaTextFormatter.compactDuration(milliseconds: playlist.duration) {
            parts.append(duration)
        }
        if let entries, let watched = MediaTextFormatter.watchedCount(entries.filter { $0.item.isWatched }.count) {
            parts.append(watched)
        }
        if playlist.smart {
            parts.append("Smart")
        }
        if let serverName {
            parts.append(serverName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
