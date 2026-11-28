import Foundation

/// Hub rows: Home, Continue Watching, a library's hubs and a hub's items.
/// The Plex calls behind `HomeProviding` (docs/jellyfin/04-architecture.md §11).
/// Every endpoint takes the item's or library's `serverID`, as in
/// `MediaService+Library`.
extension MediaService {
    /// A library's hub rows. On a library of tens of thousands of titles this
    /// is the server's most expensive read (10s on a 43k-movie test server,
    /// far longer on slower hardware), so it gets more than the usual 30s.
    func getLibraryHubs(sectionId: String, count: Int = 12, serverID: String? = nil) async throws -> [HomeRow] {
        try await fetchHomeRows(
            path: "/hubs/sections/\(sectionId)",
            queryItems: [
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "includeGuids", value: "1"),
            ],
            timeoutInterval: 90,
            serverID: serverID
        )
    }

    /// A library's promoted rows: Continue Watching, On Deck and Recently
    /// Added, the top of `getLibraryHubs` at a fraction of its cost (0.5s
    /// against 10s on the same server), so a big library paints before its
    /// full hub rows are in.
    func getLibraryPromotedHubs(sectionId: String, count: Int = 12, serverID: String? = nil) async throws -> [HomeRow] {
        let hubs = try await fetchHomeRows(
            path: "/hubs/promoted",
            queryItems: [
                URLQueryItem(name: "contentDirectoryID", value: sectionId),
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "includeGuids", value: "1"),
            ],
            serverID: serverID
        )
        // Continue Watching and On Deck are account-wide rows; keep this
        // library's titles.
        return hubs.map { hub in
            hub.replacingItems(hub.items.filter { $0.libraryID == nil || $0.libraryID == sectionId })
        }
    }

    /// `includeGuids=1` so merging across servers can match the same title by
    /// its global Plex guid instead of falling back to title/year heuristics.
    func getHubs(serverID: String? = nil) async throws -> [HomeRow] {
        try await fetchHomeRows(
            path: "/hubs",
            queryItems: [URLQueryItem(name: "includeGuids", value: "1")],
            serverID: serverID
        )
    }

    func getContinueWatching(serverID: String? = nil) async throws -> [MediaItem] {
        let hubs = try await fetchHomeRows(
            path: "/hubs/continueWatching",
            queryItems: [URLQueryItem(name: "includeGuids", value: "1")],
            serverID: serverID
        )
        return hubs.flatMap(\.items)
    }

    /// `includeGuids=1` for the same reason `getHubs` sends it: these items
    /// replace the row's own on "Show All", and without their guids the merge
    /// would fall back to title/year heuristics for the expanded row alone.
    func getHubItems(
        hubKey: String,
        start: Int = 0,
        size: Int? = nil,
        serverID: String? = nil
    ) async throws -> [MediaItem] {
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "includeGuids", value: "1")]

        if start > 0 || size != nil {
            queryItems.append(URLQueryItem(name: "X-Plex-Container-Start", value: String(start)))
        }

        if let size {
            queryItems.append(URLQueryItem(name: "X-Plex-Container-Size", value: String(size)))
        }

        let targetID = try resolveServerID(serverID)
        let data = try await rawServerRequest(
            path: hubKey,
            queryItems: queryItems,
            serverID: targetID
        )
        let response = try decodeJSON(PlexHubItemsResponseDTO.self, from: data, serverID: targetID)
        let items = ((response.MediaContainer.Metadata ?? []) + (response.MediaContainer.Directory ?? []))
            .map { PlexItemMapper.map($0, serverID: targetID) }
        return await loadedHiddenLibraryFilter().filtering(items)
    }

    /// `MediaContainer.Hub` rows, mapped onto the server they came from.
    func fetchHomeRows(
        path: String,
        queryItems: [URLQueryItem]? = nil,
        timeoutInterval: TimeInterval? = nil,
        serverID: String? = nil
    ) async throws -> [HomeRow] {
        let targetID = try resolveServerID(serverID)
        let data = try await rawServerRequest(
            path: path,
            queryItems: queryItems,
            timeoutInterval: timeoutInterval,
            serverID: targetID
        )
        let response = try decodeJSON(PlexHubResponseDTO.self, from: data, serverID: targetID)
        return (response.MediaContainer.Hub ?? []).map { PlexItemMapper.map($0, serverID: targetID) }
    }
}
