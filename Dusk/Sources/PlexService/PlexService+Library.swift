import Foundation

extension PlexService {
    func getLibraries() async throws -> [PlexLibrary] {
        try await fetchDirectories(path: "/library/sections")
    }

    func getLibraryItems(
        sectionId: String,
        start: Int = 0,
        size: Int = 50,
        sort: String? = nil,
        filters: [String: String] = [:]
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
            queryItems: queryItems
        )
        return items
    }

    func getLibraryItemCount(
        sectionId: String,
        filters: [String: String] = [:]
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

        let data = try await rawServerRequest(
            path: "/library/sections/\(sectionId)/all",
            queryItems: queryItems
        )
        let response = try decodeJSON(MetadataResponse<PlexItem>.self, from: data)
        return response.MediaContainer.totalSize ?? response.MediaContainer.size ?? 0
    }

    func getLibraryFilters(sectionId: String) async throws -> [PlexLibraryFilter] {
        try await fetchDirectories(path: "/library/sections/\(sectionId)/filters")
    }

    func getLibraryFilterValues(path: String) async throws -> [PlexLibraryFilterValue] {
        try await fetchDirectories(path: path)
    }

    func getLibraryHubs(sectionId: String, count: Int = 12) async throws -> [PlexHub] {
        try await fetchHubs(
            path: "/hubs/sections/\(sectionId)",
            queryItems: [
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "includeGuids", value: "1"),
            ]
        )
    }

    func getSeasons(showKey: String) async throws -> [PlexSeason] {
        try await fetchMetadata(path: "/library/metadata/\(showKey)/children")
    }

    func getEpisodes(seasonKey: String) async throws -> [PlexEpisode] {
        try await fetchMetadata(path: "/library/metadata/\(seasonKey)/children")
    }

    func getNextEpisode(after episode: PlexMediaDetails) async throws -> PlexEpisode? {
        guard episode.type == .episode,
              let seasonKey = episode.parentRatingKey,
              let showKey = episode.grandparentRatingKey else {
            return nil
        }

        let currentSeasonEpisodes = try await getEpisodes(seasonKey: seasonKey)
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

        if let currentEpisodeIndex = currentSeasonEpisodes.firstIndex(where: { $0.ratingKey == episode.ratingKey }),
           currentEpisodeIndex < currentSeasonEpisodes.index(before: currentSeasonEpisodes.endIndex) {
            return currentSeasonEpisodes[currentSeasonEpisodes.index(after: currentEpisodeIndex)]
        }

        if let currentEpisodeNumber = episode.index,
           let nextEpisodeInSeason = currentSeasonEpisodes.first(where: { ($0.index ?? 0) > currentEpisodeNumber }) {
            return nextEpisodeInSeason
        }

        let seasons = try await getSeasons(showKey: showKey)
            .sorted { $0.index < $1.index }

        let currentSeasonIndex = episode.parentIndex
            ?? seasons.first(where: { $0.ratingKey == seasonKey })?.index

        guard let currentSeasonIndex else { return nil }

        for season in seasons where season.index > currentSeasonIndex {
            let episodes = try await getEpisodes(seasonKey: season.ratingKey)
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            if let firstEpisode = episodes.first {
                return firstEpisode
            }
        }

        return nil
    }

    func getHubs() async throws -> [PlexHub] {
        try await fetchHubs(path: "/hubs")
    }

    func getContinueWatching() async throws -> [PlexItem] {
        let hubs = try await fetchHubs(path: "/hubs/continueWatching")
        return hubs.flatMap(\.items)
    }

    func getHubItems(hubKey: String, start: Int = 0, size: Int? = nil) async throws -> [PlexItem] {
        var queryItems: [URLQueryItem] = []

        if start > 0 || size != nil {
            queryItems.append(URLQueryItem(name: "X-Plex-Container-Start", value: String(start)))
        }

        if let size {
            queryItems.append(URLQueryItem(name: "X-Plex-Container-Size", value: String(size)))
        }

        let data = try await rawServerRequest(
            path: hubKey,
            queryItems: queryItems.isEmpty ? nil : queryItems
        )
        let response = try decodeJSON(HubItemsResponse.self, from: data)
        return (response.MediaContainer.Metadata ?? []) + (response.MediaContainer.Directory ?? [])
    }

    func search(query: String) async throws -> [PlexSearchResult] {
        let hubs = try await fetchHubs(
            path: "/hubs/search",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "includeCollections", value: "0"),
            ]
        )

        return hubs
            .filter { !$0.items.isEmpty }
            .map { PlexSearchResult(hub: $0) }
    }

    func getMediaDetails(ratingKey: String) async throws -> PlexMediaDetails {
        let items: [PlexMediaDetails] = try await fetchMetadata(
            path: "/library/metadata/\(ratingKey)",
            queryItems: [
                URLQueryItem(name: "includeMarkers", value: "1"),
            ]
        )

        guard let details = items.first else {
            throw PlexServiceError.decodingError("No metadata found for ratingKey \(ratingKey)")
        }

        return details
    }
}
