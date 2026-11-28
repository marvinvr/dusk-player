import Foundation

/// Plex's `HomeProviding`: `/hubs`, `/hubs/sections/{id}`, `/hubs/promoted`,
/// `/hubs/continueWatching`, a hub's own key, and the Home column of Plex
/// Web's per-library Manage Recommendations (`/hubs/sections/{id}/manage`,
/// whose `promotedToOwnHome` `GET /hubs` honours on the server).
///
/// Every request goes to `serverID` through `transport`.
struct PlexHomeRows: HomeProviding {
    let serverID: String
    /// nil on the value `PlexServerProvider.home` hands out, which then throws
    /// `noServerConnected`; see `PlexServerTransport`.
    let transport: (any PlexServerTransport)?

    /// `includeGuids=1` so merging across servers can match the same title by
    /// its global Plex guid instead of falling back to title/year heuristics.
    @MainActor func homeRows() async throws -> [HomeRow] {
        try await rows(
            path: "/hubs",
            queryItems: [URLQueryItem(name: "includeGuids", value: "1")]
        )
    }

    @MainActor func continueWatching() async throws -> [MediaItem] {
        let hubs = try await rows(
            path: "/hubs/continueWatching",
            queryItems: [URLQueryItem(name: "includeGuids", value: "1")]
        )
        return hubs.flatMap(\.items)
    }

    /// On a library of tens of thousands of titles this is the server's most
    /// expensive read (10s on a 43k-movie test server, far longer on slower
    /// hardware), so it gets more than the usual 30s.
    @MainActor func libraryRows(libraryID: String, count: Int) async throws -> [HomeRow] {
        try await rows(
            path: "/hubs/sections/\(libraryID)",
            queryItems: [
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "includeGuids", value: "1"),
            ],
            timeoutInterval: 90
        )
    }

    /// Continue Watching, On Deck and Recently Added, the top of
    /// `libraryRows` at a fraction of its cost (0.5s against 10s on the same
    /// server), so a big library paints before its full rows are in.
    @MainActor func promotedLibraryRows(libraryID: String, count: Int) async throws -> [HomeRow] {
        let hubs = try await rows(
            path: "/hubs/promoted",
            queryItems: [
                URLQueryItem(name: "contentDirectoryID", value: libraryID),
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "includeGuids", value: "1"),
            ]
        )
        // Continue Watching and On Deck are account-wide rows; keep this
        // library's titles.
        return hubs.map { hub in
            hub.replacingItems(hub.items.filter { $0.libraryID == nil || $0.libraryID == libraryID })
        }
    }

    /// `includeGuids=1` for the same reason `homeRows` sends it: these items
    /// replace the row's own on "Show All", and without their guids the merge
    /// would fall back to title/year heuristics for the expanded row alone.
    @MainActor func rowItems(rowKey: String, start: Int, size: Int?) async throws -> [MediaItem] {
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "includeGuids", value: "1")]

        if start > 0 || size != nil {
            queryItems.append(URLQueryItem(name: "X-Plex-Container-Start", value: String(start)))
        }

        if let size {
            queryItems.append(URLQueryItem(name: "X-Plex-Container-Size", value: String(size)))
        }

        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: rowKey,
            queryItems: queryItems,
            timeoutInterval: nil,
            serverID: serverID
        )
        let response = try transport.decodeJSON(PlexHubItemsResponseDTO.self, from: data, serverID: serverID)
        return ((response.MediaContainer.Metadata ?? []) + (response.MediaContainer.Directory ?? []))
            .map { PlexItemMapper.map($0, serverID: serverID) }
    }

    // MARK: - Hiding rows

    @MainActor func managedRows(libraryID: String) async throws -> [PlexManagedHub] {
        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: "/hubs/sections/\(libraryID)/manage",
            queryItems: nil,
            timeoutInterval: nil,
            serverID: serverID
        )
        return (try transport.decodeJSON(ManagedHubResponse.self, from: data, serverID: nil).MediaContainer.Hub ?? [])
            .map(PlexHubMapper.managedHub)
    }

    /// Plex Web sends all three flags on every change, so the other two are
    /// sent back as they were.
    @MainActor func setManagedRow(_ row: PlexManagedHub, libraryID: String) async throws {
        func flag(_ value: Bool) -> String { value ? "1" : "0" }
        _ = try await routed().rawServerRequest(
            method: "PUT",
            path: "/hubs/sections/\(libraryID)/manage/\(row.identifier)",
            queryItems: [
                URLQueryItem(name: "promotedToRecommended", value: flag(row.promotedToRecommended)),
                URLQueryItem(name: "promotedToOwnHome", value: flag(row.promotedToOwnHome)),
                URLQueryItem(name: "promotedToSharedHome", value: flag(row.promotedToSharedHome)),
            ],
            timeoutInterval: nil,
            serverID: serverID
        )
    }

    /// `GET /hubs` rows usually carry no `libraryID`, and the numbers in their
    /// identifier are not reliably the section (`movie.curated.2.1`), so the
    /// section comes from the row's titles when they say, else every library
    /// on this server is asked. A merged row keeps only its representative's
    /// identifier and library, so the other servers' come from `source`.
    @MainActor func managedRow(
        for row: HomeRow,
        source: PlexHubSource,
        libraryIDs: [String]
    ) async -> PlexManagedHomeRow? {
        let representative = source.serverID == row.sources.first?.serverID
        guard let identifier = (source.hubIdentifier ?? (representative ? row.hubIdentifier : nil))?.nilIfEmpty,
              !identifier.hasPrefix("home.") else { return nil }

        var sectionIDs = Set(row.items.filter { $0.serverID == source.serverID }.compactMap(\.libraryID))
        if representative, let sectionID = row.libraryID?.nilIfEmpty {
            sectionIDs.insert(sectionID)
        }
        let candidates = sectionIDs.isEmpty ? libraryIDs : Array(sectionIDs)

        for sectionID in candidates {
            guard let managed = try? await managedRows(libraryID: sectionID),
                  let match = managed.first(where: { $0.matches(hubIdentifier: identifier, sectionID: sectionID) })
            else { continue }
            return PlexManagedHomeRow(serverID: source.serverID, sectionID: sectionID, hub: match)
        }
        return nil
    }

    // MARK: - Requests

    /// `MediaContainer.Hub` rows of `path`, mapped onto this server.
    @MainActor func rows(
        path: String,
        queryItems: [URLQueryItem]? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> [HomeRow] {
        let transport = try routed()
        let data = try await transport.rawServerRequest(
            method: "GET",
            path: path,
            queryItems: queryItems,
            timeoutInterval: timeoutInterval,
            serverID: serverID
        )
        let response = try transport.decodeJSON(PlexHubResponseDTO.self, from: data, serverID: serverID)
        return (response.MediaContainer.Hub ?? []).map { PlexHubMapper.map($0, serverID: serverID) }
    }

    @MainActor private func routed() throws -> any PlexServerTransport {
        guard let transport else { throw PlexServiceError.noServerConnected }
        return transport
    }
}

private struct ManagedHubResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let Hub: [PlexManagedHubDTO]?
    }
}

extension PlexServerProvider {
    /// Sends through the account's routed send (`PlexServerRouter`).
    var home: any HomeProviding { PlexHomeRows(serverID: descriptor.id, transport: router) }
}
