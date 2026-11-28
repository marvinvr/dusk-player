import Foundation

/// Plex playlists. Each one lives on a single server and belongs to the
/// signed-in user, so every call is routed to the playlist's own server and an
/// item can only be added to a playlist on the server it came from.
///
/// Verified against a real PMS (1.43): `PUT /playlists/{id}?title=&summary=`
/// renames; adding a show or season `uri` expands it into its episodes and the
/// server skips ones the playlist already holds (`leafCountAdded` vs
/// `leafCountRequested`); smart playlists reject item edits with HTTP 400 and
/// list their items without a `playlistItemID`; the list's `duration` is in
/// milliseconds but the `/items` container's is in seconds.
extension PlexService {
    /// Video playlists on one server, in the server's order (title).
    func getPlaylists(serverID: String) async throws -> [Playlist] {
        let playlists: [Playlist] = try await fetchMetadata(
            path: "/playlists",
            queryItems: [URLQueryItem(name: "playlistType", value: "video")],
            serverID: serverID
        )
        return playlists.filter(\.isVideo)
    }

    /// Video playlists from every connected server, streamed as each answers.
    /// A server that fails contributes nothing (`nil`, not an empty list, so
    /// the caller can tell "has none" from "did not answer").
    func streamPlaylists() -> AsyncStream<ServerResult<[Playlist]?>> {
        streamAcrossServers { service, serverID in
            try? await service.getPlaylists(serverID: serverID)
        }
    }

    func getPlaylist(ratingKey: String, serverID: String?) async throws -> Playlist? {
        let playlists: [Playlist] = try await fetchMetadata(
            path: "/playlists/\(ratingKey)",
            serverID: serverID
        )
        return playlists.first
    }

    /// Every entry of a playlist, in playlist order, paged through.
    func getPlaylistEntries(ratingKey: String, serverID: String?) async throws -> [PlaylistEntry] {
        let targetID = try resolveServerID(serverID)
        let pageSize = 200
        var entries: [PlaylistEntry] = []
        while true {
            let data = try await rawServerRequest(
                path: "/playlists/\(ratingKey)/items",
                queryItems: [
                    URLQueryItem(name: "X-Plex-Container-Start", value: String(entries.count)),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(pageSize)),
                ],
                serverID: targetID
            )
            let container = try decodeJSON(MetadataResponse<PlaylistEntry>.self, from: data, serverID: targetID)
                .MediaContainer
            let page = container.Metadata ?? []
            entries += page
            let total = container.totalSize ?? container.size ?? entries.count
            if page.isEmpty || page.count < pageSize || entries.count >= total { break }
        }
        return entries
    }

    /// Plex cannot create an empty regular playlist, so a new one always
    /// starts with the items it was created from.
    func createPlaylist(title: String, ratingKeys: [String], serverID: String) async throws -> Playlist {
        let data = try await rawServerRequest(
            method: "POST",
            path: "/playlists",
            queryItems: [
                URLQueryItem(name: "type", value: "video"),
                URLQueryItem(name: "title", value: title),
                URLQueryItem(name: "smart", value: "0"),
                URLQueryItem(name: "uri", value: libraryURI(ratingKeys: ratingKeys, serverID: serverID)),
            ],
            serverID: serverID
        )
        guard let playlist = try decodeJSON(MetadataResponse<Playlist>.self, from: data, serverID: serverID)
            .MediaContainer.Metadata?.first else {
            throw PlexServiceError.decodingError("Plex did not return the new playlist.")
        }
        return playlist
    }

    /// Appends items (a show or season adds all its episodes).
    @discardableResult
    func addToPlaylist(_ playlist: Playlist, ratingKeys: [String]) async throws -> PlexPlaylistAddResult {
        let serverID = try resolveServerID(playlist.serverID)
        let data = try await rawServerRequest(
            method: "PUT",
            path: "/playlists/\(playlist.ratingKey)/items",
            queryItems: [
                URLQueryItem(name: "uri", value: libraryURI(ratingKeys: ratingKeys, serverID: serverID)),
            ],
            serverID: serverID
        )
        let container = try? decodeJSON(PlaylistAddResponse.self, from: data, serverID: serverID).MediaContainer
        let requested = container?.leafCountRequested ?? ratingKeys.count
        return PlexPlaylistAddResult(added: container?.leafCountAdded ?? requested, requested: requested)
    }

    func removeFromPlaylist(_ playlist: Playlist, playlistItemID: Int) async throws {
        _ = try await rawServerRequest(
            method: "DELETE",
            path: "/playlists/\(playlist.ratingKey)/items/\(playlistItemID)",
            serverID: playlist.serverID
        )
    }

    /// Moves an entry right after `afterPlaylistItemID`, or to the top when nil.
    func movePlaylistItem(_ playlist: Playlist, playlistItemID: Int, after afterPlaylistItemID: Int?) async throws {
        _ = try await rawServerRequest(
            method: "PUT",
            path: "/playlists/\(playlist.ratingKey)/items/\(playlistItemID)/move",
            queryItems: afterPlaylistItemID.map { [URLQueryItem(name: "after", value: String($0))] },
            serverID: playlist.serverID
        )
    }

    func renamePlaylist(_ playlist: Playlist, to title: String) async throws {
        _ = try await rawServerRequest(
            method: "PUT",
            path: "/playlists/\(playlist.ratingKey)",
            queryItems: [URLQueryItem(name: "title", value: title)],
            serverID: playlist.serverID
        )
    }

    func deletePlaylist(_ playlist: Playlist) async throws {
        _ = try await rawServerRequest(
            method: "DELETE",
            path: "/playlists/\(playlist.ratingKey)",
            serverID: playlist.serverID
        )
    }

    /// `server://{machineID}/com.plexapp.plugins.library/library/metadata/{rk,rk}`.
    func libraryURI(ratingKeys: [String], serverID: String) -> String {
        "server://\(serverID)/com.plexapp.plugins.library/library/metadata/\(ratingKeys.joined(separator: ","))"
    }
}

private struct PlaylistAddResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let leafCountAdded: Int?
        let leafCountRequested: Int?
    }
}

extension PlexService {
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
        guard let playlist = try? await getPlaylist(ratingKey: id.ratingKey, serverID: id.serverID) else { return }
        playlists.upsert(playlist, sessionGeneration: session)
    }
}
