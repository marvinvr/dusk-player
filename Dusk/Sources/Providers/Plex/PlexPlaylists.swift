import Foundation

/// Plex's `PlaylistProviding`: `/playlists` and `/playlists/{id}[/items]` on
/// one server. Items are addressed by a `server://` library URI that only Plex
/// knows, built here.
///
/// Verified against a real PMS (1.43): `PUT /playlists/{id}?title=&summary=`
/// renames; adding a show or season `uri` expands it into its episodes and the
/// server skips ones the playlist already holds (`leafCountAdded` vs
/// `leafCountRequested`); smart playlists reject item edits with HTTP 400 and
/// list their items without a `playlistItemID`; the list's `duration` is in
/// milliseconds but the `/items` container's is in seconds.
///
/// Every request goes to `serverID` through `transport`.
struct PlexPlaylists: PlaylistProviding {
    let serverID: String
    /// nil on the value `PlexServerProvider.playlists` hands out, which then
    /// throws `noServerConnected`; see `PlexServerTransport`.
    let transport: (any PlexServerTransport)?

    /// Video playlists only: Dusk shows no audio or photo playlists.
    @MainActor func playlists() async throws -> [Playlist] {
        let data = try await send(
            path: "/playlists",
            queryItems: [URLQueryItem(name: "playlistType", value: "video")]
        )
        return try metadata(PlexPlaylistDTO.self, from: data)
            .map { PlexUserContentMapper.playlist($0, serverID: serverID) }
            .filter(\.isVideo)
    }

    @MainActor func playlist(id: String) async throws -> Playlist? {
        let data = try await send(path: "/playlists/\(id)")
        return try metadata(PlexPlaylistDTO.self, from: data)
            .first
            .map { PlexUserContentMapper.playlist($0, serverID: serverID) }
    }

    /// Paged through, 200 entries a page.
    @MainActor func entries(playlistID: String) async throws -> [PlaylistEntry] {
        let transport = try routed()
        let pageSize = 200
        var entries: [PlaylistEntry] = []
        while true {
            let data = try await send(
                path: "/playlists/\(playlistID)/items",
                queryItems: [
                    URLQueryItem(name: "X-Plex-Container-Start", value: String(entries.count)),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(pageSize)),
                ]
            )
            let container = try transport.decodeJSON(
                MetadataResponse<PlexPlaylistEntryDTO>.self, from: data, serverID: serverID
            ).MediaContainer
            let page = (container.Metadata ?? []).map { PlexUserContentMapper.playlistEntry($0, serverID: serverID) }
            entries += page
            let total = container.totalSize ?? container.size ?? entries.count
            if page.isEmpty || page.count < pageSize || entries.count >= total { break }
        }
        return entries
    }

    @MainActor func createPlaylist(title: String, itemIDs: [String]) async throws -> Playlist {
        let data = try await send(
            method: "POST",
            path: "/playlists",
            queryItems: [
                URLQueryItem(name: "type", value: "video"),
                URLQueryItem(name: "title", value: title),
                URLQueryItem(name: "smart", value: "0"),
                URLQueryItem(name: "uri", value: libraryURI(itemIDs: itemIDs)),
            ]
        )
        guard let playlist = try metadata(PlexPlaylistDTO.self, from: data).first else {
            throw PlexServiceError.decodingError("Plex did not return the new playlist.")
        }
        return PlexUserContentMapper.playlist(playlist, serverID: serverID)
    }

    @MainActor func add(itemIDs: [String], to playlistID: String) async throws -> PlexPlaylistAddResult {
        let transport = try routed()
        let data = try await send(
            method: "PUT",
            path: "/playlists/\(playlistID)/items",
            queryItems: [
                URLQueryItem(name: "uri", value: libraryURI(itemIDs: itemIDs)),
            ]
        )
        let container = try? transport.decodeJSON(PlaylistAddResponse.self, from: data, serverID: serverID)
            .MediaContainer
        let requested = container?.leafCountRequested ?? itemIDs.count
        return PlexPlaylistAddResult(added: container?.leafCountAdded ?? requested, requested: requested)
    }

    @MainActor func removeEntry(_ entryID: Int, from playlistID: String) async throws {
        _ = try await send(method: "DELETE", path: "/playlists/\(playlistID)/items/\(entryID)")
    }

    @MainActor func moveEntry(_ entryID: Int, after afterEntryID: Int?, in playlistID: String) async throws {
        _ = try await send(
            method: "PUT",
            path: "/playlists/\(playlistID)/items/\(entryID)/move",
            queryItems: afterEntryID.map { [URLQueryItem(name: "after", value: String($0))] }
        )
    }

    @MainActor func rename(playlistID: String, to title: String) async throws {
        _ = try await send(
            method: "PUT",
            path: "/playlists/\(playlistID)",
            queryItems: [URLQueryItem(name: "title", value: title)]
        )
    }

    @MainActor func delete(playlistID: String) async throws {
        _ = try await send(method: "DELETE", path: "/playlists/\(playlistID)")
    }

    // MARK: - Requests

    /// `server://{machineID}/com.plexapp.plugins.library/library/metadata/{rk,rk}`.
    private func libraryURI(itemIDs: [String]) -> String {
        "server://\(serverID)/com.plexapp.plugins.library/library/metadata/\(itemIDs.joined(separator: ","))"
    }

    @MainActor private func send(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> Data {
        try await routed().rawServerRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            timeoutInterval: nil,
            serverID: serverID
        )
    }

    /// `MediaContainer.Metadata` of a payload from this server.
    @MainActor private func metadata<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
        try routed().decodeJSON(MetadataResponse<T>.self, from: data, serverID: serverID)
            .MediaContainer.Metadata ?? []
    }

    @MainActor private func routed() throws -> any PlexServerTransport {
        guard let transport else { throw PlexServiceError.noServerConnected }
        return transport
    }
}

/// The `PUT /playlists/{id}/items` answer.
private struct PlaylistAddResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let leafCountAdded: Int?
        let leafCountRequested: Int?
    }
}

extension PlexServerProvider {
    /// Not routed yet: see `PlexServerTransport`. Nothing reads it in
    /// Phase 0; the facade uses `MediaService.playlists(on:)`.
    var playlists: any PlaylistProviding { PlexPlaylists(serverID: descriptor.id, transport: nil) }
}
