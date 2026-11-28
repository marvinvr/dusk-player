import Foundation

/// Libraries, browse, details and children. Each method is a route to the
/// server's `CatalogProviding` facet (docs/jellyfin/04-architecture.md §9,
/// `PlexCatalog`); the hidden-library filter, merging and the next/previous
/// episode walk stay here.
///
/// Every endpoint here takes a `serverID`. It is optional and defaults to nil
/// ("the primary server") so call sites that have not been routed yet keep
/// working, but anything that starts from a model — an item, a library, a
/// collection — must pass that model's own `serverID`, or the request lands on
/// a different server's rating keys.
extension MediaService {
    /// The catalog facet of one server's provider.
    func catalog(on serverID: String) -> any CatalogProviding {
        serverProvider(for: serverID).catalog
    }

    /// The Plex catalog itself, for the routes whose callers still pass Plex
    /// sort strings and filter parameters.
    func plexCatalog(on serverID: String) -> PlexCatalog {
        PlexCatalog(serverID: serverID, transport: plexAccount.router)
    }

    func getLibraries(serverID: String? = nil) async throws -> [Library] {
        try await catalog(on: resolveServerID(serverID)).libraries()
    }

    // MARK: - Library listings

    /// One page of a library in a neutral sort and filter.
    func libraryItems(
        in library: Library,
        start: Int = 0,
        size: Int = 50,
        sort: LibrarySortOption?,
        filter: LibraryFilter = LibraryFilter()
    ) async throws -> [MediaItem] {
        try await catalog(on: resolveServerID(library.serverID)).items(
            libraryID: library.key,
            kind: library.libraryType,
            start: start,
            size: size,
            sort: sort,
            filter: filter
        )
    }

    /// The A–Z table of a title-sorted listing under `filter`. Cheap even on
    /// a big library; it backs the grid's A–Z jump.
    func libraryLetterCounts(in library: Library, filter: LibraryFilter) async throws -> [LibraryLetterCount] {
        try await catalog(on: resolveServerID(library.serverID))
            .letterCounts(libraryID: library.key, kind: library.libraryType, filter: filter)
    }

    /// The sorts the library's menu offers.
    func librarySortFields(for library: Library) -> [LibrarySortField] {
        guard let serverID = try? resolveServerID(library.serverID) else {
            return LibrarySortField.fields(for: library.libraryType)
        }
        return catalog(on: serverID).sortFields(for: library.libraryType)
    }

    /// The Filters sheet's fields for the library.
    func libraryFilterFields(in library: Library, includesCollection: Bool) async throws -> [LibraryFilterField] {
        try await catalog(on: resolveServerID(library.serverID))
            .filterFields(libraryID: library.key, includesCollection: includesCollection)
    }

    /// The values a Filters sheet field offers.
    func libraryFilterChoices(for field: LibraryFilterField, in library: Library) async throws -> [LibraryFilterChoice] {
        try await catalog(on: resolveServerID(library.serverID)).filterChoices(for: field)
    }

    /// A page of a library in a Plex `sort` (`titleSort`, `addedAt:desc`, …)
    /// with Plex filter parameters. For the callers that still build their
    /// own (recommendation shelves, Siri, video channels); the grid uses
    /// `libraryItems(in:…)`.
    func getLibraryItems(
        sectionId: String,
        start: Int = 0,
        size: Int = 50,
        sort: String? = nil,
        filters: [String: String] = [:],
        serverID: String? = nil
    ) async throws -> [MediaItem] {
        try await plexCatalog(on: resolveServerID(serverID))
            .rawItems(libraryID: sectionId, start: start, size: size, sort: sort, filters: filters)
    }

    /// How many titles a library has under Plex filter parameters.
    func getLibraryItemCount(
        sectionId: String,
        filters: [String: String] = [:],
        serverID: String? = nil
    ) async throws -> Int {
        try await plexCatalog(on: resolveServerID(serverID)).rawItemCount(libraryID: sectionId, filters: filters)
    }

    /// The section's raw `/filters` rows, for the genre menu
    /// (`LibraryGenreSupport`).
    func getLibraryFilters(sectionId: String, serverID: String? = nil) async throws -> [LibraryFilterEntry] {
        try await plexCatalog(on: resolveServerID(serverID)).rawFilters(libraryID: sectionId)
    }

    /// The values of one raw `/filters` row, for the genre menu.
    func getLibraryFilterValues(path: String, serverID: String? = nil) async throws -> [LibraryFilterValue] {
        try await plexCatalog(on: resolveServerID(serverID)).rawFilterValues(path: path)
    }

    /// A video library's channels. Each returned `key` plugs into
    /// `getLibraryItems(sectionId:filters: ["collection": key])` or
    /// `LibraryFilter.collectionID`.
    func getLibraryCollections(sectionId: String, serverID: String? = nil) async throws -> [MediaCollection] {
        try await catalog(on: resolveServerID(serverID)).channelCollections(libraryID: sectionId)
    }

    // MARK: - Children

    func getSeasons(showKey: String, serverID: String? = nil) async throws -> [Season] {
        try await catalog(on: resolveServerID(serverID)).seasons(showID: showKey)
    }

    func getEpisodes(seasonKey: String, serverID: String? = nil) async throws -> [Episode] {
        try await catalog(on: resolveServerID(serverID)).episodes(seasonID: seasonKey)
    }

    /// Every episode of a show, across all its seasons, in one request.
    func getAllEpisodes(showKey: String, serverID: String? = nil) async throws -> [Episode] {
        try await catalog(on: resolveServerID(serverID)).allEpisodes(showID: showKey)
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

    /// Hidden libraries' titles never come back, nor those of libraries the
    /// server excludes from global search: search feeds both the Search screen
    /// and Siri.
    func search(query: String, serverID: String? = nil) async throws -> [SearchSection] {
        let groups = try await catalog(on: resolveServerID(serverID)).searchGroups(query: query)

        return await loadedHiddenLibraryFilter(for: .search).filtering(groups)
            .filter { !$0.items.isEmpty }
            .flatMap { SearchSection.results(from: $0) }
    }

    /// - Parameter checkFiles: when `true`, asks the server to check the
    ///   backing files first, so a stale/missing version isn't chosen for
    ///   direct play. Used right before playback.
    func getMediaDetails(
        itemID: String,
        checkFiles: Bool = false,
        serverID: String? = nil
    ) async throws -> MediaDetails {
        try await catalog(on: resolveServerID(serverID)).details(itemID: itemID, checkFiles: checkFiles)
    }

    /// The raw details payload, for the offline metadata cache. The same
    /// request `getMediaDetails` makes.
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
            path: PlexMetadataSnapshotFormat.metadataEndpoint(itemID),
            queryItems: queryItems,
            serverID: serverID
        )
    }
}
