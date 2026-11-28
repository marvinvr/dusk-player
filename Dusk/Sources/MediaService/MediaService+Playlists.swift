import Foundation

/// Playlists, routed to the playlist's server's `PlaylistProviding`. Each one
/// lives on a single server and belongs to the signed-in user, so every call
/// goes to the playlist's own server and an item can only be added to a
/// playlist on the server it came from.

extension MediaService {
    /// The playlist facet of one server. Built here rather than read off
    /// `session.provider` while routing and self-healing still live in the
    /// facade (`PlexServerTransport`).
    func playlistFacet(on serverID: String?) throws -> any PlaylistProviding {
        PlexPlaylists(serverID: try resolveServerID(serverID), transport: self)
    }

    /// Video playlists on one server, in the server's order (title).
    func getPlaylists(serverID: String) async throws -> [Playlist] {
        try await playlistFacet(on: serverID).playlists()
    }

    /// Video playlists from every connected server, streamed as each answers.
    /// A server that fails contributes nothing (`nil`, not an empty list, so
    /// the caller can tell "has none" from "did not answer").
    func streamPlaylists() -> AsyncStream<ServerResult<[Playlist]?>> {
        streamAcrossServers { service, serverID in
            try? await service.getPlaylists(serverID: serverID)
        }
    }

    func getPlaylist(itemID: String, serverID: String?) async throws -> Playlist? {
        try await playlistFacet(on: serverID).playlist(id: itemID)
    }

    /// Every entry of a playlist, in playlist order, paged through.
    func getPlaylistEntries(itemID: String, serverID: String?) async throws -> [PlaylistEntry] {
        try await playlistFacet(on: serverID).entries(playlistID: itemID)
    }

    /// Plex cannot create an empty regular playlist, so a new one always
    /// starts with the items it was created from.
    func createPlaylist(title: String, ratingKeys: [String], serverID: String) async throws -> Playlist {
        try await playlistFacet(on: serverID).createPlaylist(title: title, itemIDs: ratingKeys)
    }

    /// Appends items (a show or season adds all its episodes).
    @discardableResult
    func addToPlaylist(_ playlist: Playlist, ratingKeys: [String]) async throws -> PlexPlaylistAddResult {
        try await playlistFacet(on: playlist.serverID).add(itemIDs: ratingKeys, to: playlist.itemID)
    }

    func removeFromPlaylist(_ playlist: Playlist, playlistItemID: Int) async throws {
        try await playlistFacet(on: playlist.serverID).removeEntry(playlistItemID, from: playlist.itemID)
    }

    /// Moves an entry right after `afterPlaylistItemID`, or to the top when nil.
    func movePlaylistItem(_ playlist: Playlist, playlistItemID: Int, after afterPlaylistItemID: Int?) async throws {
        try await playlistFacet(on: playlist.serverID)
            .moveEntry(playlistItemID, after: afterPlaylistItemID, in: playlist.itemID)
    }

    func renamePlaylist(_ playlist: Playlist, to title: String) async throws {
        try await playlistFacet(on: playlist.serverID).rename(playlistID: playlist.itemID, to: title)
    }

    func deletePlaylist(_ playlist: Playlist) async throws {
        try await playlistFacet(on: playlist.serverID).delete(playlistID: playlist.itemID)
    }
}

extension MediaService {
    /// Loads every connected server's video playlists into `playlists`, once
    /// per server-content revision unless `force`d. Each server's list lands
    /// as it answers.
    func loadPlaylists(force: Bool = false) async {
        let revision = serverContentRevision
        guard force || playlists.loadedRevision != revision || playlists.state == .idle else { return }
        let generation = playlists.beginLoad(revision: revision)

        var failure: String?
        for await result in streamPlaylists() {
            if let lists = result.value {
                playlists.commit(lists, serverID: result.serverID, generation: generation)
            } else {
                failure = "Couldn’t load playlists from \(pool.displayName(for: result.serverID))."
            }
        }
        guard !Task.isCancelled else { return }
        playlists.finishLoad(failure: failure, generation: generation)
    }

    /// Re-reads one playlist (its count, runtime and mosaic change with every
    /// edit) into the store.
    func refreshPlaylist(_ id: MediaItemID) async {
        let session = playlists.sessionGeneration
        guard let playlist = try? await getPlaylist(itemID: id.itemID, serverID: id.serverID) else { return }
        playlists.upsert(playlist, sessionGeneration: session)
    }
}
