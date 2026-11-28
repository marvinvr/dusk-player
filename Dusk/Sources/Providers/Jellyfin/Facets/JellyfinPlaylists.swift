import Foundation

/// Jellyfin's `PlaylistProviding` (docs/jellyfin/02-jellyfin-api-mapping.md §5).
///
/// Measured on jellyfin-demo (12.4) as a non-admin user:
/// - an entry's `PlaylistItemId` is its item id, so repeats of one item share
///   it, and `DELETE …/Items?entryIds=` removes every repeat;
/// - adding appends repeats (Plex skips them) and a show or season id adds
///   its episodes. Dusk adds only what is not there yet, so a Jellyfin
///   playlist behaves like a Plex one and the add result counts the same way;
/// - `Move/{index}` is the entry's index in the final order;
/// - the owner deletes and renames their playlist without
///   `EnableContentDeletion` (`DELETE /Items/{id}`, `POST /Playlists/{id}`);
/// - `RunTimeTicks` and the `Primary` mosaic are redrawn a second or two
///   after an edit (a new playlist reads 0 and no image at first).
///
/// Video playlists only, like Plex. There are no smart playlists.
@MainActor
struct JellyfinPlaylists: PlaylistProviding {
    let serverID: String
    private let makeClient: @MainActor () throws -> JellyfinClient

    nonisolated init(server: JellyfinServerProvider) {
        serverID = server.descriptor.id
        makeClient = { try server.client() }
    }

    /// For tests: a client over a stub transport.
    nonisolated init(serverID: String, client: @escaping @MainActor () throws -> JellyfinClient) {
        self.serverID = serverID
        makeClient = client
    }

    /// Entries are read 200 at a time.
    private static let pageSize = 200
    private static let playlistFields: [JellyfinItemField] = [.overview, .childCount, .dateCreated]

    func playlists() async throws -> [Playlist] {
        let client = try makeClient()
        var query = JellyfinItemQuery()
        query.recursive = true
        query.includeItemTypes = [.playlist]
        query.sortBy = [.sortName]
        query.fields = Self.playlistFields
        return try await client.send(JellyfinAPI.items(query)).items
            .map { JellyfinItemMapper.playlist($0, serverID: serverID) }
            .filter(\.isVideo)
    }

    /// Read after every edit. The server redraws the playlist's runtime and
    /// mosaic a second or two after an edit, so the runtime is summed from
    /// the entries here, which is what the server settles on.
    func playlist(id: String) async throws -> Playlist? {
        let client = try makeClient()
        var query = JellyfinItemQuery()
        query.ids = [id]
        query.includeItemTypes = [.playlist]
        query.fields = Self.playlistFields
        guard let dto = try await client.send(JellyfinAPI.items(query)).items.first else { return nil }
        let entries = try await client.send(JellyfinAPI.playlistItems(id: id)).items
        let duration = entries.compactMap(JellyfinItemMapper.duration).reduce(0, +)
        return JellyfinItemMapper.playlist(dto, serverID: serverID, entriesDuration: duration)
    }

    func entries(playlistID: String) async throws -> [PlaylistEntry] {
        let client = try makeClient()
        var dtos: [JellyfinItemDTO] = []
        while true {
            let page = try await client.send(JellyfinAPI.playlistItems(
                id: playlistID,
                startIndex: dtos.count,
                limit: Self.pageSize,
                fields: JellyfinBrowseVocabulary.listFields
            ))
            dtos += page.items
            let total = page.totalRecordCount ?? dtos.count
            if page.items.count < Self.pageSize || dtos.count >= total { break }
        }
        return JellyfinItemMapper.playlistEntries(dtos, serverID: serverID)
    }

    func createPlaylist(title: String, itemIDs: [String]) async throws -> Playlist {
        let client = try makeClient()
        let leaves = try await leafIDs(of: itemIDs, client: client)
        let created = try await client.send(JellyfinAPI.createPlaylist(
            JellyfinCreatePlaylistDTO(name: title, ids: Self.unique(leaves))
        ))
        guard let playlist = try await playlist(id: created.id) else {
            throw JellyfinError.unexpectedResponse("new playlist not found")
        }
        return playlist
    }

    /// Adds what the playlist does not hold yet; a show or season adds its
    /// episodes. `requested` counts episodes, as Plex's does.
    func add(itemIDs: [String], to playlistID: String) async throws -> PlaylistAddResult {
        let client = try makeClient()
        async let present = client.send(JellyfinAPI.playlist(id: playlistID))
        let leaves = try await leafIDs(of: itemIDs, client: client)
        let existing = Set(try await present.itemIDs.map(JellyfinID.normalized))
        let added = Self.unique(leaves).filter { !existing.contains($0) }
        if !added.isEmpty {
            _ = try await client.send(JellyfinAPI.addToPlaylist(id: playlistID, itemIDs: added))
        }
        return PlaylistAddResult(added: added.count, requested: leaves.count)
    }

    func removeEntry(_ entryID: String, from playlistID: String) async throws {
        _ = try await makeClient().send(JellyfinAPI.removeFromPlaylist(id: playlistID, entryIDs: [entryID]))
    }

    /// "After X" becomes the index Jellyfin moves to: X's place in the order
    /// without the moved entry, plus one.
    func moveEntry(_ entryID: String, after afterEntryID: String?, in playlistID: String) async throws {
        let client = try makeClient()
        var index = 0
        if let afterEntryID {
            let order = try await client.send(JellyfinAPI.playlistItems(id: playlistID)).items
                .compactMap { $0.playlistItemID.map(JellyfinID.normalized) }
            let moved = JellyfinID.normalized(entryID)
            let wanted = JellyfinID.normalized(afterEntryID)
            guard let position = order.filter({ $0 != moved }).firstIndex(of: wanted) else {
                throw JellyfinError.unexpectedResponse("playlist entry not found")
            }
            index = position + 1
        }
        _ = try await client.send(JellyfinAPI.movePlaylistItem(id: playlistID, entryID: entryID, toIndex: index))
    }

    func rename(playlistID: String, to title: String) async throws {
        _ = try await makeClient().send(JellyfinAPI.updatePlaylist(id: playlistID, JellyfinUpdatePlaylistDTO(name: title)))
    }

    func delete(playlistID: String) async throws {
        _ = try await makeClient().send(JellyfinAPI.deleteItem(id: playlistID))
    }

    // MARK: - Requests

    /// The playable ids behind `itemIDs`, in order: a show or season becomes
    /// its episodes in episode order, anything else stays as it is.
    private func leafIDs(of itemIDs: [String], client: JellyfinClient) async throws -> [String] {
        let ids = itemIDs.map(JellyfinID.normalized)
        guard !ids.isEmpty else { return [] }
        var query = JellyfinItemQuery()
        query.ids = ids
        query.enableImages = false
        query.enableUserData = false
        let kinds = Dictionary(
            try await client.send(JellyfinAPI.items(query)).items.map { (JellyfinID.normalized($0.id), $0.type) },
            uniquingKeysWith: { first, _ in first }
        )
        var leaves: [String] = []
        for id in ids {
            guard let kind = kinds[id] ?? nil, kind.matches(.series) || kind.matches(.season) else {
                leaves.append(id)
                continue
            }
            var episodes = JellyfinItemQuery()
            episodes.parentID = id
            episodes.recursive = true
            episodes.includeItemTypes = [.episode]
            episodes.isMissing = false
            episodes.sortBy = [.parentIndexNumber, .indexNumber, .sortName]
            episodes.enableImages = false
            episodes.enableUserData = false
            leaves += try await client.send(JellyfinAPI.items(episodes)).items.map { JellyfinID.normalized($0.id) }
        }
        return leaves
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
