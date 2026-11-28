import Foundation

/// Every endpoint here takes a `serverID`. It is optional and defaults to nil
/// ("the primary server") so call sites that have not been routed yet keep
/// working, but anything that starts from a model — an item, a library, a
/// collection — must pass that model's own `serverID`, or the request lands on
/// a different server's rating keys.
extension PlexService {
    func getLibraries(serverID: String? = nil) async throws -> [Library] {
        let targetID = try resolveServerID(serverID)
        let sections: [PlexLibraryDTO] = try await fetchDirectories(path: "/library/sections", serverID: targetID)
        return sections.map { PlexItemMapper.map($0, serverID: targetID) }
    }

    func getLibraryItems(
        sectionId: String,
        start: Int = 0,
        size: Int = 50,
        sort: String? = nil,
        filters: [String: String] = [:],
        serverID: String? = nil
    ) async throws -> [MediaItem] {
        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(size)),
        ]

        if let sort, !sort.isEmpty {
            queryItems.append(URLQueryItem(name: "sort", value: sort))
        }

        queryItems.append(
            contentsOf: filters
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        )

        let targetID = try resolveServerID(serverID)
        let items: [PlexItemDTO] = try await fetchMetadata(
            path: "/library/sections/\(sectionId)/all",
            queryItems: queryItems,
            serverID: targetID
        )
        return items.map { PlexItemMapper.map($0, serverID: targetID) }
    }

    func getLibraryItemCount(
        sectionId: String,
        filters: [String: String] = [:],
        serverID: String? = nil
    ) async throws -> Int {
        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "1"),
        ]

        queryItems.append(
            contentsOf: filters
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        )

        let targetID = try resolveServerID(serverID)
        let data = try await rawServerRequest(
            path: "/library/sections/\(sectionId)/all",
            queryItems: queryItems,
            serverID: targetID
        )
        let response = try decodeJSON(MetadataResponse<PlexItemDTO>.self, from: data, serverID: targetID)
        return response.MediaContainer.totalSize ?? response.MediaContainer.size ?? 0
    }

    /// How many titles start with each character under the given filters, in
    /// title-sort order (`/library/sections/{id}/firstCharacter`). Cheap even on
    /// a big library; it backs the grid's A–Z jump.
    func getLibraryFirstCharacters(
        sectionId: String,
        filters: [String: String] = [:],
        serverID: String? = nil
    ) async throws -> [PlexFirstCharacter] {
        try await fetchDirectories(
            path: "/library/sections/\(sectionId)/firstCharacter",
            queryItems: filters
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) },
            serverID: serverID
        )
    }

    func getLibraryFilters(sectionId: String, serverID: String? = nil) async throws -> [PlexLibraryFilter] {
        try await fetchDirectories(path: "/library/sections/\(sectionId)/filters", serverID: serverID)
    }

    func getLibraryFilterValues(path: String, serverID: String? = nil) async throws -> [PlexLibraryFilterValue] {
        try await fetchDirectories(path: path, serverID: serverID)
    }

    /// Lists the collections defined in a library section (video libraries
    /// have one per channel) via the section's `collection` filter values.
    /// Each returned `key` plugs directly into
    /// `getLibraryItems(sectionId:filters: ["collection": key])`.
    func getLibraryCollections(sectionId: String, serverID: String? = nil) async throws -> [MediaCollection] {
        let targetID = try resolveServerID(serverID)
        let values: [PlexLibraryFilterValue] = try await fetchDirectories(
            path: "/library/sections/\(sectionId)/collection",
            serverID: targetID
        )
        return values.compactMap { MediaCollection(filterValue: $0, serverID: targetID) }
    }

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

    func getSeasons(showKey: String, serverID: String? = nil) async throws -> [Season] {
        let targetID = try resolveServerID(serverID)
        let seasons: [PlexSeasonDTO] = try await fetchMetadata(
            path: "/library/metadata/\(showKey)/children",
            serverID: targetID
        )
        return seasons.map { PlexItemMapper.map($0, serverID: targetID) }
    }

    func getEpisodes(seasonKey: String, serverID: String? = nil) async throws -> [Episode] {
        try await fetchEpisodes(path: "/library/metadata/\(seasonKey)/children", serverID: serverID)
    }

    /// Every episode of a show, across all its seasons, in one request.
    func getAllEpisodes(showKey: String, serverID: String? = nil) async throws -> [Episode] {
        try await fetchEpisodes(path: "/library/metadata/\(showKey)/allLeaves", serverID: serverID)
    }

    /// Walks forward from an episode to the next one. Everything it reads comes
    /// from the same server the episode came from — an episode's siblings and
    /// its show's later seasons only exist there.
    func getNextEpisode(after episode: MediaDetails) async throws -> Episode? {
        guard episode.type == .episode,
              let seasonKey = episode.parentID,
              let showKey = episode.grandparentID else {
            return nil
        }

        let serverID = episode.serverID
        let currentSeasonEpisodes = try await getEpisodes(seasonKey: seasonKey, serverID: serverID)
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

        if let currentEpisodeIndex = currentSeasonEpisodes.firstIndex(where: { $0.itemID == episode.itemID }),
           currentEpisodeIndex < currentSeasonEpisodes.index(before: currentSeasonEpisodes.endIndex) {
            return currentSeasonEpisodes[currentSeasonEpisodes.index(after: currentEpisodeIndex)]
        }

        if let currentEpisodeNumber = episode.index,
           let nextEpisodeInSeason = currentSeasonEpisodes.first(where: { ($0.index ?? 0) > currentEpisodeNumber }) {
            return nextEpisodeInSeason
        }

        let seasons = try await getSeasons(showKey: showKey, serverID: serverID)
            .sorted { $0.index < $1.index }

        let currentSeasonIndex = episode.parentIndex
            ?? seasons.first(where: { $0.itemID == seasonKey })?.index

        guard let currentSeasonIndex else { return nil }

        for season in seasons where season.index > currentSeasonIndex {
            let episodes = try await getEpisodes(seasonKey: season.itemID, serverID: serverID)
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            if let firstEpisode = episodes.first {
                return firstEpisode
            }
        }

        return nil
    }

    /// Both neighbours of an episode, for the player's Previous / Next Episode
    /// controls. Same server and ordering rules as `getNextEpisode`, but the
    /// current season is fetched once for both directions, and the show's
    /// seasons only when a neighbour lies outside it. Previous never steps from
    /// a regular season back into Specials (season 0).
    func getAdjacentEpisodes(around episode: MediaDetails) async throws -> AdjacentEpisodes {
        guard episode.type == .episode,
              let seasonKey = episode.parentID,
              let showKey = episode.grandparentID else {
            return AdjacentEpisodes()
        }

        let serverID = episode.serverID
        let currentSeasonEpisodes = try await getEpisodes(seasonKey: seasonKey, serverID: serverID)
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        var adjacent = AdjacentEpisodes.inSeason(currentSeasonEpisodes, around: episode)
        guard adjacent.previous == nil || adjacent.next == nil else { return adjacent }

        let seasons = try await getSeasons(showKey: showKey, serverID: serverID)
            .sorted { $0.index < $1.index }
        let currentSeasonIndex = episode.parentIndex
            ?? seasons.first(where: { $0.itemID == seasonKey })?.index
        guard let currentSeasonIndex else { return adjacent }

        if adjacent.next == nil {
            for season in seasons where season.index > currentSeasonIndex {
                let episodes = try await getEpisodes(seasonKey: season.itemID, serverID: serverID)
                if let first = episodes.min(by: { ($0.index ?? 0) < ($1.index ?? 0) }) {
                    adjacent.next = first
                    break
                }
            }
        }

        if adjacent.previous == nil {
            for season in seasons.reversed() where season.index < currentSeasonIndex && season.index > 0 {
                let episodes = try await getEpisodes(seasonKey: season.itemID, serverID: serverID)
                if let last = episodes.max(by: { ($0.index ?? 0) < ($1.index ?? 0) }) {
                    adjacent.previous = last
                    break
                }
            }
        }

        return adjacent
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

    /// Hidden libraries' titles never come back, nor those of libraries the
    /// server excludes from global search: search feeds both the Search screen
    /// and Siri.
    func search(query: String, serverID: String? = nil) async throws -> [SearchSection] {
        let hubs = try await fetchHomeRows(
            path: "/hubs/search",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "includeCollections", value: "0"),
                URLQueryItem(name: "includeGuids", value: "1"),
            ],
            serverID: serverID
        )

        return await loadedHiddenLibraryFilter(for: .search).filtering(hubs)
            .filter { !$0.items.isEmpty }
            .flatMap { SearchSection.results(from: $0) }
    }

    func getMediaDetails(
        itemID: String,
        checkFiles: Bool = false,
        serverID: String? = nil
    ) async throws -> MediaDetails {
        let targetID = try resolveServerID(serverID)
        let data = try await getMediaDetailsPayload(
            itemID: itemID,
            checkFiles: checkFiles,
            serverID: targetID
        )
        let response = try decodeJSON(MetadataResponse<PlexMediaDetailsDTO>.self, from: data, serverID: targetID)
        let items = response.MediaContainer.Metadata ?? []

        guard let details = items.first else {
            throw PlexServiceError.decodingError("No metadata found for ratingKey \(itemID)")
        }

        return PlexItemMapper.map(details, serverID: targetID)
    }

    /// - Parameter checkFiles: when `true`, asks Plex to stat the backing files so
    ///   each `Part` carries accurate `accessible`/`exists` flags. Used right
    ///   before playback so a stale/missing version isn't chosen for direct play.
    func getMediaDetailsPayload(
        itemID: String,
        checkFiles: Bool = false,
        serverID: String? = nil
    ) async throws -> Data {
        var queryItems = [
            URLQueryItem(name: "includeMarkers", value: "1"),
            URLQueryItem(name: "includeGuids", value: "1"),
        ]
        if checkFiles {
            queryItems.append(URLQueryItem(name: "checkFiles", value: "1"))
        }
        return try await rawServerRequest(
            path: PlexMetadataCache.metadataEndpoint(itemID),
            queryItems: queryItems,
            serverID: serverID
        )
    }

    func getChildrenPayload(itemID: String, serverID: String? = nil) async throws -> Data {
        try await rawServerRequest(
            path: PlexMetadataCache.childrenEndpoint(itemID),
            serverID: serverID
        )
    }

    // MARK: - Decoding

    private func fetchEpisodes(path: String, serverID: String?) async throws -> [Episode] {
        let targetID = try resolveServerID(serverID)
        let episodes: [PlexEpisodeDTO] = try await fetchMetadata(path: path, serverID: targetID)
        return episodes.map { PlexItemMapper.map($0, serverID: targetID) }
    }

    /// `MediaContainer.Hub` rows, mapped onto the server they came from.
    private func fetchHomeRows(
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
