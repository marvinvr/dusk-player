import Foundation

/// One playlist: its entries in order, Play/Resume/Shuffle queues, and the
/// edits Plex allows on a regular playlist (remove, reorder, rename, delete).
/// Edits are optimistic and roll back with an error when the server refuses.
/// A smart playlist is read-only apart from Delete.
@MainActor
@Observable
final class PlaylistDetailViewModel {
    let id: MediaItemID
    private let plexService: PlexService

    private(set) var playlist: Playlist?
    private(set) var entries: [PlaylistEntry] = []
    private(set) var hasLoadedEntries = false
    private(set) var error: String?
    /// An edit that failed; shown as an alert.
    var actionError: String?

    init(id: MediaItemID, plexService: PlexService) {
        self.id = id
        self.plexService = plexService
        self.playlist = plexService.playlists.playlist(id: id)
    }

    private var actions: PlaylistActions { PlaylistActions(plexService: plexService) }

    var title: String { playlist?.title ?? "" }
    var isSmart: Bool { playlist?.smart ?? false }
    var canEdit: Bool { playlist.map { !$0.smart } ?? false }
    var summary: String? { playlist?.summary }

    var metadataLine: String? {
        guard let playlist else { return nil }
        let serverName = plexService.playlists.spansMultipleServers
            ? playlist.serverID.map(plexService.pool.displayName(for:))
            : nil
        return PlaylistActions.metadataLine(
            for: playlist,
            entries: hasLoadedEntries ? entries : nil,
            serverName: serverName
        )
    }

    var playButtonTitle: String { PlaylistActions.playButtonTitle(for: entries) }
    var canPlay: Bool { entries.contains { PlaybackQueueItem(item: $0.item).isPlayableKind } }

    // MARK: - Loading

    func load() async {
        if playlist == nil {
            do {
                playlist = try await plexService.getPlaylist(ratingKey: id.ratingKey, serverID: id.serverID)
                if playlist == nil {
                    error = "This playlist no longer exists."
                    return
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        await reloadEntries()
    }

    /// After playback or a return to the foreground: watch state moved on.
    func refresh() async {
        await plexService.refreshPlaylist(id)
        if let stored = plexService.playlists.playlist(id: id) {
            playlist = stored
        }
        await reloadEntries()
    }

    private func reloadEntries() async {
        do {
            entries = try await plexService.getPlaylistEntries(ratingKey: id.ratingKey, serverID: id.serverID)
            hasLoadedEntries = true
            error = nil
        } catch {
            if !hasLoadedEntries {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Playback

    /// Play / Resume: the first item that is not fully watched, at its
    /// offset; a fully watched playlist starts over.
    func resumeQueue() -> PlaybackQueue? {
        guard let playlist else { return nil }
        return actions.queue(for: playlist, entries: entries, startIndex: PlaylistActions.resumeIndex(in: entries) ?? 0)
    }

    /// Play from Here, and Play from Beginning (index 0).
    func queue(startingAt entry: PlaylistEntry) -> PlaybackQueue? {
        guard let playlist, let index = entries.firstIndex(of: entry) else { return nil }
        return actions.queue(for: playlist, entries: entries, startIndex: index)
    }

    func queueFromBeginning() -> PlaybackQueue? {
        guard let playlist else { return nil }
        return actions.queue(for: playlist, entries: entries, startIndex: 0)
    }

    func shuffledQueue() -> PlaybackQueue? {
        guard let playlist else { return nil }
        return actions.queue(for: playlist, entries: entries, shuffled: true)
    }

    // MARK: - Edits

    func remove(_ entry: PlaylistEntry) async {
        guard let playlist, canEdit, let playlistItemID = entry.playlistItemID,
              let index = entries.firstIndex(of: entry) else { return }
        let previous = entries
        entries.remove(at: index)
        do {
            try await plexService.removeFromPlaylist(playlist, playlistItemID: playlistItemID)
            await plexService.refreshPlaylist(id)
            self.playlist = plexService.playlists.playlist(id: id) ?? self.playlist
        } catch {
            entries = previous
            actionError = "Couldn’t remove “\(entry.item.title)”. \(error.localizedDescription)"
        }
    }

    func remove(atOffsets offsets: IndexSet) {
        let removed = offsets.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        Task {
            for entry in removed {
                await remove(entry)
            }
        }
    }

    /// iOS drag-reorder. Each moved entry goes right after the entry that now
    /// precedes it (or to the top), which is the only move Plex knows.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let playlist, canEdit else { return }
        let previous = entries
        let moved = source.map { entries[$0] }
        entries.move(fromOffsets: source, toOffset: destination)
        let reordered = entries

        Task {
            do {
                for entry in moved {
                    guard let playlistItemID = entry.playlistItemID,
                          let index = reordered.firstIndex(of: entry) else { continue }
                    let after = index > 0 ? reordered[index - 1].playlistItemID : nil
                    try await plexService.movePlaylistItem(playlist, playlistItemID: playlistItemID, after: after)
                }
                await plexService.refreshPlaylist(id)
            } catch {
                entries = previous
                actionError = "Couldn’t reorder the playlist. \(error.localizedDescription)"
            }
        }
    }

    func rename(to title: String) async {
        guard let playlist, canEdit else { return }
        do {
            self.playlist = try await actions.rename(playlist, to: title)
        } catch {
            actionError = "Couldn’t rename the playlist. \(error.localizedDescription)"
        }
    }

    /// True when the playlist is gone and the page should pop.
    func delete() async -> Bool {
        guard let playlist else { return false }
        do {
            try await actions.delete(playlist)
            return true
        } catch {
            actionError = "Couldn’t delete the playlist. \(error.localizedDescription)"
            return false
        }
    }

    func setWatched(_ watched: Bool, for entry: PlaylistEntry) async {
        do {
            try await plexService.setWatchedAcrossServers(watched, id: entry.item.id)
        } catch {
            actionError = error.localizedDescription
        }
        await reloadEntries()
    }

    // MARK: - Presentation

    func thumbnailURL(for item: MediaItem, width: Int, height: Int) -> URL? {
        item.landscapeImageURL(plexService: plexService, width: width, height: height)
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        if let first = entries.first?.item {
            let path = first.type == .episode ? (first.grandparentArt ?? first.art) : first.art
            if let url = plexService.imageURL(for: path ?? first.thumb, serverID: first.serverID, width: width, height: height) {
                return url
            }
        }
        return plexService.imageURL(for: playlist?.artworkPath, serverID: id.serverID, width: width, height: height)
    }

    /// `The Bear · S2 E6` for an episode, the year for a movie, the clip line
    /// for a video.
    static func secondaryLine(for item: MediaItem) -> String? {
        if item.isClip {
            return item.clipPosterSubtitle
        }
        switch item.type {
        case .episode:
            return [
                item.grandparentTitle,
                MediaTextFormatter.compactSeasonEpisodeLabel(season: item.parentIndex, episode: item.index),
            ]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " · ")
            .nilIfEmpty
        default:
            return item.appendingEdition(to: item.year.map(String.init))
        }
    }
}
