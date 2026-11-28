import Foundation

/// The playlist-level actions both the Playlists grid (context menu) and the
/// playlist page offer: build a play queue, rename, delete. Every edit goes to
/// the playlist's own server first and only then into `MediaService.playlists`.
@MainActor
struct PlaylistActions {
    let media: MediaService

    /// The queue for a whole playlist: in order from `startIndex`, or
    /// shuffled once for the session.
    func queue(for playlist: Playlist, entries: [PlaylistEntry], startIndex: Int = 0, shuffled: Bool = false) -> PlaybackQueue? {
        let items = entries.map { PlaybackQueueItem(item: $0.item) }
        if shuffled {
            return PlaybackQueue.shuffledPlaylist(id: playlist.id, title: playlist.title, items: items)
        }
        return PlaybackQueue.playlist(id: playlist.id, title: playlist.title, items: items, startIndex: startIndex)
    }

    /// Fetches the entries first (the grid has none loaded).
    func queue(for playlist: Playlist, shuffled: Bool) async throws -> (queue: PlaybackQueue?, entries: [PlaylistEntry]) {
        let entries = try await media.getPlaylistEntries(itemID: playlist.itemID, serverID: playlist.serverID)
        let start = shuffled ? 0 : PlaylistActions.resumeIndex(in: entries) ?? 0
        return (queue(for: playlist, entries: entries, startIndex: start, shuffled: shuffled), entries)
    }

    func rename(_ playlist: Playlist, to title: String) async throws -> Playlist {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != playlist.title else { return playlist }
        let session = media.playlists.sessionGeneration
        try await media.renamePlaylist(playlist, to: trimmed)
        let renamed = playlist.renamed(trimmed)
        media.playlists.upsert(renamed, sessionGeneration: session)
        media.pinnedPlaylists.updateTitle(trimmed, for: playlist.id, profileID: media.activeProfileID)
        return renamed
    }

    func delete(_ playlist: Playlist) async throws {
        let session = media.playlists.sessionGeneration
        try await media.deletePlaylist(playlist)
        media.playlists.remove(playlist.id, sessionGeneration: session)
        media.setPlaylistPinned(false, id: playlist.id, title: playlist.title)
    }

    /// Where Play / Resume starts: the first item that is not fully watched
    /// (in progress or never watched). Nil when every item is watched.
    static func resumeIndex(in entries: [PlaylistEntry]) -> Int? {
        entries.firstIndex { entry in
            entry.item.isPartiallyWatched || !entry.item.isWatched
        }
    }

    /// "Resume" once anything has been watched or is in progress; plain
    /// "Play" for an untouched (or fully watched) playlist.
    static func playButtonTitle(for entries: [PlaylistEntry]) -> String {
        guard resumeIndex(in: entries) != nil else { return "Play" }
        let started = entries.contains { $0.item.isWatched || $0.item.isPartiallyWatched }
        return started ? "Resume" : "Play"
    }

    /// `12 items · 18 h 20 min`, then `7 watched` and `Smart` where they apply.
    static func metadataLine(for playlist: Playlist, entries: [PlaylistEntry]?, serverName: String?) -> String? {
        var parts: [String] = []
        let count = entries?.count ?? playlist.episodeCount
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
