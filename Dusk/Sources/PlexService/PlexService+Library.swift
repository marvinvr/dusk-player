import Foundation

/// Every endpoint here takes a `serverID`. It is optional and defaults to nil
/// ("the primary server") so call sites that have not been routed yet keep
/// working, but anything that starts from a model — an item, a library, a
/// collection — must pass that model's own `serverID`, or the request lands on
/// a different server's rating keys.
extension PlexService {
    func getLibraries(serverID: String? = nil) async throws -> [PlexLibrary] {
        try await fetchDirectories(path: "/library/sections", serverID: serverID)
    }

    func getLibraryItems(
        sectionId: String,
        start: Int = 0,
        size: Int = 50,
        sort: String? = nil,
        filters: [String: String] = [:],
        serverID: String? = nil
    ) async throws -> [PlexItem] {
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

        let items: [PlexItem] = try await fetchMetadata(
            path: "/library/sections/\(sectionId)/all",
            queryItems: queryItems,
            serverID: serverID
        )
        return items
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
        let response = try decodeJSON(MetadataResponse<PlexItem>.self, from: data, serverID: targetID)
        return response.MediaContainer.totalSize ?? response.MediaContainer.size ?? 0
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
    func getLibraryCollections(sectionId: String, serverID: String? = nil) async throws -> [PlexLibraryCollection] {
        let targetID = try resolveServerID(serverID)
        let values: [PlexLibraryFilterValue] = try await fetchDirectories(
            path: "/library/sections/\(sectionId)/collection",
            serverID: targetID
        )
        return values.compactMap { PlexLibraryCollection(filterValue: $0, serverID: targetID) }
    }

    func getLibraryHubs(sectionId: String, count: Int = 12, serverID: String? = nil) async throws -> [PlexHub] {
        try await fetchHubs(
            path: "/hubs/sections/\(sectionId)",
            queryItems: [
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "includeGuids", value: "1"),
            ],
            serverID: serverID
        )
    }

    func getSeasons(showKey: String, serverID: String? = nil) async throws -> [PlexSeason] {
        let targetID = try resolveServerID(serverID)
        let initiatingSession = serverSessionToken
        let seasons: [PlexSeason] = try await fetchMetadata(path: "/library/metadata/\(showKey)/children", serverID: targetID)
        if initiatingSession == serverSessionToken, let profile = initiatingSession.profileID {
            for season in seasons {
                IntroFingerprintStore.shared.registerSeason(
                    .init(viewerProfileID: profile, serverID: targetID, seasonRatingKey: season.ratingKey),
                    showRatingKey: showKey, accountProfileID: primaryProfileID
                )
            }
        }
        return seasons
    }

    func getEpisodes(seasonKey: String, serverID: String? = nil) async throws -> [PlexEpisode] {
        let targetID = try resolveServerID(serverID)
        let initiatingSession = serverSessionToken
        let store = IntroFingerprintStore.shared
        let metadataGeneration = store.metadataGeneration
        let data = try await rawServerRequest(path: "/library/metadata/\(seasonKey)/children", serverID: targetID)
        let container = try decodeJSON(MetadataResponse<PlexEpisode>.self, from: data, serverID: targetID).MediaContainer
        let episodes = container.Metadata ?? []
        if initiatingSession == serverSessionToken, metadataGeneration == store.metadataGeneration,
           !Task.isCancelled, let profile = initiatingSession.profileID,
           (container.offset ?? 0) == 0, (container.totalSize ?? container.size) == episodes.count,
           Set(episodes.map(\.ratingKey)).count == episodes.count,
           episodes.allSatisfy({ $0.parentRatingKey == seasonKey }) {
            let key = IntroFingerprintSeasonKey(viewerProfileID: profile, serverID: targetID, seasonRatingKey: seasonKey)
            store.registerSeason(key, showRatingKey: episodes.first?.grandparentRatingKey, accountProfileID: primaryProfileID)
            store.observeSeason(key, episodeIDs: Set(episodes.map(\.ratingKey)),
                                watchedEpisodeIDs: Set(episodes.filter(\.isWatched).map(\.ratingKey)))
        }
        return episodes
    }

    /// Every episode of a show, across all its seasons, in one request.
    func getAllEpisodes(showKey: String, serverID: String? = nil) async throws -> [PlexEpisode] {
        try await fetchMetadata(path: "/library/metadata/\(showKey)/allLeaves", serverID: serverID)
    }

    /// Walks forward from an episode to the next one. Everything it reads comes
    /// from the same server the episode came from — an episode's siblings and
    /// its show's later seasons only exist there.
    func getNextEpisode(after episode: PlexMediaDetails) async throws -> PlexEpisode? {
        guard episode.type == .episode,
              let seasonKey = episode.parentRatingKey,
              let showKey = episode.grandparentRatingKey else {
            return nil
        }

        let serverID = episode.serverID
        let currentSeasonEpisodes = try await getEpisodes(seasonKey: seasonKey, serverID: serverID)
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

        if let currentEpisodeIndex = currentSeasonEpisodes.firstIndex(where: { $0.ratingKey == episode.ratingKey }),
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
            ?? seasons.first(where: { $0.ratingKey == seasonKey })?.index

        guard let currentSeasonIndex else { return nil }

        for season in seasons where season.index > currentSeasonIndex {
            let episodes = try await getEpisodes(seasonKey: season.ratingKey, serverID: serverID)
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
    func getAdjacentEpisodes(around episode: PlexMediaDetails) async throws -> PlexAdjacentEpisodes {
        guard episode.type == .episode,
              let seasonKey = episode.parentRatingKey,
              let showKey = episode.grandparentRatingKey else {
            return PlexAdjacentEpisodes()
        }

        let serverID = episode.serverID
        let currentSeasonEpisodes = try await getEpisodes(seasonKey: seasonKey, serverID: serverID)
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        var adjacent = PlexAdjacentEpisodes.inSeason(currentSeasonEpisodes, around: episode)
        guard adjacent.previous == nil || adjacent.next == nil else { return adjacent }

        let seasons = try await getSeasons(showKey: showKey, serverID: serverID)
            .sorted { $0.index < $1.index }
        let currentSeasonIndex = episode.parentIndex
            ?? seasons.first(where: { $0.ratingKey == seasonKey })?.index
        guard let currentSeasonIndex else { return adjacent }

        if adjacent.next == nil {
            for season in seasons where season.index > currentSeasonIndex {
                let episodes = try await getEpisodes(seasonKey: season.ratingKey, serverID: serverID)
                if let first = episodes.min(by: { ($0.index ?? 0) < ($1.index ?? 0) }) {
                    adjacent.next = first
                    break
                }
            }
        }

        if adjacent.previous == nil {
            for season in seasons.reversed() where season.index < currentSeasonIndex && season.index > 0 {
                let episodes = try await getEpisodes(seasonKey: season.ratingKey, serverID: serverID)
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
    func getHubs(serverID: String? = nil) async throws -> [PlexHub] {
        try await fetchHubs(
            path: "/hubs",
            queryItems: [URLQueryItem(name: "includeGuids", value: "1")],
            serverID: serverID
        )
    }

    func getContinueWatching(serverID: String? = nil) async throws -> [PlexItem] {
        let hubs = try await fetchHubs(
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
    ) async throws -> [PlexItem] {
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
        let response = try decodeJSON(HubItemsResponse.self, from: data, serverID: targetID)
        return (response.MediaContainer.Metadata ?? []) + (response.MediaContainer.Directory ?? [])
    }

    func search(query: String, serverID: String? = nil) async throws -> [PlexSearchResult] {
        let hubs = try await fetchHubs(
            path: "/hubs/search",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "includeCollections", value: "0"),
                URLQueryItem(name: "includeGuids", value: "1"),
            ],
            serverID: serverID
        )

        return hubs
            .filter { !$0.items.isEmpty }
            .flatMap { PlexSearchResult.results(from: $0) }
    }

    func getMediaDetails(
        ratingKey: String,
        checkFiles: Bool = false,
        serverID: String? = nil
    ) async throws -> PlexMediaDetails {
        let targetID = try resolveServerID(serverID)
        let initiatingSession = serverSessionToken
        let data = try await getMediaDetailsPayload(
            ratingKey: ratingKey,
            checkFiles: checkFiles,
            serverID: targetID
        )
        let response = try decodeJSON(MetadataResponse<PlexMediaDetails>.self, from: data, serverID: targetID)
        let items = response.MediaContainer.Metadata ?? []

        guard let details = items.first else {
            throw PlexServiceError.decodingError("No metadata found for ratingKey \(ratingKey)")
        }

        if initiatingSession == serverSessionToken, !Task.isCancelled, let profile = initiatingSession.profileID {
            registerIntroFingerprintHierarchy(details, profileID: profile)
        }

        return details
    }

    /// - Parameter checkFiles: when `true`, asks Plex to stat the backing files so
    ///   each `Part` carries accurate `accessible`/`exists` flags. Used right
    ///   before playback so a stale/missing version isn't chosen for direct play.
    func getMediaDetailsPayload(
        ratingKey: String,
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
            path: PlexMetadataCache.metadataEndpoint(ratingKey),
            queryItems: queryItems,
            serverID: serverID
        )
    }

    func getChildrenPayload(ratingKey: String, serverID: String? = nil) async throws -> Data {
        try await rawServerRequest(
            path: PlexMetadataCache.childrenEndpoint(ratingKey),
            serverID: serverID
        )
    }
}
