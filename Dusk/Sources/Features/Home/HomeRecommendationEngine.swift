import Foundation
import OSLog

private let homeRecommendationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "HomeRecommendations"
)

@MainActor
struct HomeRecommendationEngine {
    let plexService: PlexService
    var calendar: Calendar = .autoupdatingCurrent
    var nowProvider: @Sendable () -> Date = Date.init

    func loadShelves(
        itemsPerShelf: Int,
        movieShelfLimit: Int = 4,
        showShelfLimit: Int = 4
    ) async throws -> [HomePersonalizedShelf] {
        guard itemsPerShelf > 0 else { return [] }

        // Every connected server's sections, already in the account's order.
        // Shelves therefore span servers: a genre the user likes pulls from
        // wherever those titles happen to live.
        let libraries = try await plexService.ensureLibraryOrderLoaded()
        let movieLibraries = libraries.filter { $0.libraryType == .movie }
        let showLibraries = libraries.filter { $0.libraryType == .show }

        guard let viewedSince = calendar.date(byAdding: .day, value: -30, to: nowProvider()) else {
            return []
        }

        let currentUser = try? await plexService.getCurrentUser()
        let currentUserID = currentUser?.id

        async let movieShelvesTask = loadShelves(
            for: .movie,
            libraries: movieLibraries,
            currentUserID: currentUserID,
            viewedSince: viewedSince,
            itemsPerShelf: itemsPerShelf,
            shelfLimit: movieShelfLimit
        )
        async let showShelvesTask = loadShelves(
            for: .show,
            libraries: showLibraries,
            currentUserID: currentUserID,
            viewedSince: viewedSince,
            itemsPerShelf: itemsPerShelf,
            shelfLimit: showShelfLimit
        )

        let movieShelves = try await movieShelvesTask
        let showShelves = try await showShelvesTask

        return interleavedShelves(movieShelves: movieShelves, showShelves: showShelves)
    }

    private func loadShelves(
        for libraryType: PlexLibraryType,
        libraries: [PlexLibrary],
        currentUserID: Int?,
        viewedSince: Date,
        itemsPerShelf: Int,
        shelfLimit: Int
    ) async throws -> [HomePersonalizedShelf] {
        guard !libraries.isEmpty, shelfLimit > 0 else { return [] }

        let availableGenresByLibrary = await loadAvailableGenresByLibrary(libraries: libraries)
        let history = try await loadHistory(
            libraries: libraries,
            currentUserID: currentUserID,
            viewedSince: viewedSince
        )

        var scoredGenres = await scoreGenres(from: history)

        if scoredGenres.isEmpty {
            let fallbackItems = try await loadRecentlyViewedItems(
                libraryType: libraryType,
                libraries: libraries,
                viewedSince: viewedSince
            )
            scoredGenres = scoreGenres(fromRecentlyViewedItems: fallbackItems)
        }

        guard !scoredGenres.isEmpty else { return [] }

        var shelves: [HomePersonalizedShelf] = []
        var usedTitles = RecommendationSeenTitles()
        let showAllLibrary = libraries.count == 1 ? libraries.first : nil

        for scoredGenre in scoredGenres.prefix(shelfLimit) {
            let items = try await loadCandidates(
                for: scoredGenre.genre,
                libraries: libraries,
                availableGenresByLibrary: availableGenresByLibrary,
                usedTitles: usedTitles,
                itemsPerShelf: itemsPerShelf,
                libraryType: libraryType
            )

            guard items.count >= min(2, itemsPerShelf) else { continue }

            shelves.append(
                HomePersonalizedShelf(
                    libraryType: libraryType,
                    genre: scoredGenre.genre,
                    title: "\(scoredGenre.genre.title) \(libraryType.tabTitle)",
                    items: items,
                    showAllLibrary: showAllLibrary
                )
            )

            usedTitles.formUnion(items)
        }

        return shelves
    }

    private func loadAvailableGenresByLibrary(
        libraries: [PlexLibrary]
    ) async -> [String: [LibraryGenreOption]] {
        var genresByLibrary: [String: [LibraryGenreOption]] = [:]

        // Keyed by `library.id`, never by `library.key`: section keys are
        // per-server counters and two servers' "3" would share one entry.
        for library in libraries {
            if let genres = try? await LibraryGenreSupport.loadGenreOptions(
                sectionId: library.key,
                serverID: library.serverID,
                plexService: plexService
            ) {
                genresByLibrary[library.id] = genres
            } else {
                genresByLibrary[library.id] = [.all]
            }
        }

        return genresByLibrary
    }

    private func loadHistory(
        libraries: [PlexLibrary],
        currentUserID: Int?,
        viewedSince: Date
    ) async throws -> [PlexPlaybackHistoryEntry] {
        var entries: [PlexPlaybackHistoryEntry] = []

        for library in libraries {
            var history = (try? await plexService.getPlaybackHistory(
                accountId: currentUserID,
                librarySectionId: library.key,
                viewedSince: viewedSince,
                serverID: library.serverID
            )) ?? []

            if history.isEmpty, currentUserID != nil {
                history = (try? await plexService.getPlaybackHistory(
                    accountId: nil,
                    librarySectionId: library.key,
                    viewedSince: viewedSince,
                    serverID: library.serverID
                )) ?? []
            }

            entries.append(contentsOf: history)
        }

        return entries
    }

    private func scoreGenres(
        from history: [PlexPlaybackHistoryEntry]
    ) async -> [RecommendationScoredGenre] {
        let signals = collapsedSignals(from: history)
        return await RecommendationGenreScoring.scoreGenres(from: signals) { signal in
            guard let details = try? await plexService.getMediaDetails(
                ratingKey: signal.ratingKey,
                serverID: signal.serverID
            ) else {
                homeRecommendationLogger.debug(
                    "Skipping ratingKey \(signal.ratingKey, privacy: .public) because metadata could not be loaded"
                )
                return []
            }

            return LibraryGenreSupport.inferredGenres(from: details.genres ?? [])
        }
    }

    private func scoreGenres(
        fromRecentlyViewedItems items: [PlexItem]
    ) -> [RecommendationScoredGenre] {
        RecommendationGenreScoring.scoreGenres(fromRecentlyViewedItems: items) { item in
            LibraryGenreSupport.inferredGenres(from: item.genres ?? [])
        }
    }

    private func collapsedSignals(from history: [PlexPlaybackHistoryEntry]) -> [RecommendationTasteSignal] {
        let now = nowProvider()
        var signalByIdentity: [String: RecommendationTasteSignal] = [:]

        for entry in history {
            guard let viewedAt = entry.viewedAt else { continue }
            guard let identity = collapsedIdentity(for: entry) else { continue }


            let viewedDate = Date(timeIntervalSince1970: TimeInterval(viewedAt))
            let dayAge = max(0, calendar.dateComponents([.day], from: viewedDate, to: now).day ?? 0)
            let recencyWeight = max(0.2, 1.0 - (Double(dayAge) / 30.0))

            if var existing = signalByIdentity[identity.identity] {
                existing.weight = min(existing.weight + (0.35 * recencyWeight), 2.0)
                existing.lastViewedAt = max(existing.lastViewedAt, viewedAt)
                signalByIdentity[identity.identity] = existing
            } else {
                signalByIdentity[identity.identity] = RecommendationTasteSignal(
                    identity: identity.identity,
                    id: identity.id,
                    type: nil,
                    weight: recencyWeight,
                    lastViewedAt: viewedAt
                )
            }
        }

        return signalByIdentity.values.sorted {
            if $0.weight != $1.weight {
                return $0.weight > $1.weight
            }

            return $0.lastViewedAt > $1.lastViewedAt
        }
    }

    private func loadRecentlyViewedItems(
        libraryType: PlexLibraryType,
        libraries: [PlexLibrary],
        viewedSince: Date
    ) async throws -> [PlexItem] {
        var items: [PlexItem] = []

        for library in libraries {
            let libraryItems = try await loadRecentlyViewedItems(
                in: library,
                libraryType: libraryType,
                viewedSince: viewedSince
            )
            items.append(contentsOf: libraryItems)
        }

        var seen = RecommendationSeenTitles()

        return items
            .sorted { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }
            .filter { seen.insert($0) }
    }

    private func loadRecentlyViewedItems(
        in library: PlexLibrary,
        libraryType: PlexLibraryType,
        viewedSince: Date
    ) async throws -> [PlexItem] {
        let epochSeconds = Int(viewedSince.timeIntervalSince1970.rounded(.down))
        let pageSize = 60
        let maxPagesToInspect = 4
        var recentItems: [PlexItem] = []
        var watchedFallbackItems: [PlexItem] = []

        for page in 0..<maxPagesToInspect {
            let items = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: page * pageSize,
                size: pageSize,
                sort: "lastViewedAt:desc",
                serverID: library.serverID
            )

            guard !items.isEmpty else { break }

            var pageHasPotentiallyRecentItems = false

            for item in items where isRecommendationSignalItem(item, libraryType: libraryType) {
                if let lastViewedAt = item.lastViewedAt {
                    if lastViewedAt >= epochSeconds {
                        recentItems.append(item)
                        pageHasPotentiallyRecentItems = true
                    } else if recentItems.isEmpty {
                        watchedFallbackItems.append(item)
                    }
                } else if item.isWatched {
                    watchedFallbackItems.append(item)
                }
            }

            if recentItems.count >= 40 {
                break
            }

            if !pageHasPotentiallyRecentItems && !recentItems.isEmpty {
                break
            }

            if items.count < pageSize {
                break
            }
        }

        if !recentItems.isEmpty {
            return Array(recentItems.prefix(40))
        }

        return Array(watchedFallbackItems.prefix(40))
    }

    private func loadCandidates(
        for genre: LibraryGenreOption,
        libraries: [PlexLibrary],
        availableGenresByLibrary: [String: [LibraryGenreOption]],
        usedTitles: RecommendationSeenTitles,
        itemsPerShelf: Int,
        libraryType: PlexLibraryType
    ) async throws -> [PlexItem] {
        var pool: [PlexItem] = []
        var seen = usedTitles
        let desiredPoolSize = max(itemsPerShelf * 4, 24)
        // The seed spans every contributing library on every server, so the
        // daily shuffle changes when a server comes or goes rather than
        // silently producing the same row from a different catalogue.
        let librarySeed = libraries.map(\.id).joined(separator: ",")

        for library in libraries {
            let matchedLibraryGenre = matchingLibraryGenre(
                for: genre,
                availableGenres: availableGenresByLibrary[library.id] ?? [.all]
            )

            let libraryItems: [PlexItem]

            if let matchedLibraryGenre, let genreValue = matchedLibraryGenre.value {
                let serverFilteredItems = try await loadServerFilteredCandidates(
                    in: library,
                    genreValue: genreValue,
                    usedTitles: seen,
                    itemsPerShelf: max(itemsPerShelf * 2, 12),
                    libraryType: libraryType
                )

                if serverFilteredItems.count >= min(2, itemsPerShelf) {
                    libraryItems = serverFilteredItems
                } else {
                    libraryItems = try await loadLocallyFilteredCandidates(
                        in: library,
                        genre: genre,
                        usedTitles: seen,
                        itemsPerShelf: max(itemsPerShelf * 2, 12),
                        libraryType: libraryType
                    )
                }
            } else {
                libraryItems = try await loadLocallyFilteredCandidates(
                    in: library,
                    genre: genre,
                    usedTitles: seen,
                    itemsPerShelf: max(itemsPerShelf * 2, 12),
                    libraryType: libraryType
                )
            }

            for item in libraryItems where shouldIncludeCandidate(item, seen: seen) {
                seen.insert(item)
                pool.append(item)
            }

            if pool.count >= desiredPoolSize {
                break
            }
        }

        return Array(
            seededShuffle(
                pool,
                seed: dailySeed(for: "\(libraryType.rawValue)|\(genre.title)|\(librarySeed)")
            )
            .prefix(itemsPerShelf)
        )
    }

    private func loadServerFilteredCandidates(
        in library: PlexLibrary,
        genreValue: String,
        usedTitles: RecommendationSeenTitles,
        itemsPerShelf: Int,
        libraryType: PlexLibraryType
    ) async throws -> [PlexItem] {
        let filters = ["genre": genreValue]
        let totalCount = try await plexService.getLibraryItemCount(
            sectionId: library.key,
            filters: filters,
            serverID: library.serverID
        )

        guard totalCount > 0 else { return [] }

        let pageSize = max(itemsPerShelf * 4, 40)
        let maxPagesToInspect = min(6, Int(ceil(Double(totalCount) / Double(pageSize))))
        guard maxPagesToInspect > 0 else { return [] }

        let shuffledPageOrder = rotatedPageOrder(
            pageCount: maxPagesToInspect,
            seed: dailySeed(for: "\(library.id)|\(genreValue)")
        )

        var pool: [PlexItem] = []
        var seen = usedTitles
        let desiredPoolSize = max(itemsPerShelf * 3, 24)

        for page in shuffledPageOrder {
            let items = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: page * pageSize,
                size: pageSize,
                sort: "titleSort",
                filters: filters,
                serverID: library.serverID
            )

            guard !items.isEmpty else { continue }

            for item in items where shouldIncludeCandidate(item, seen: seen) {
                guard isCandidateType(item, libraryType: libraryType) else { continue }
                seen.insert(item)
                pool.append(item)
            }

            if pool.count >= desiredPoolSize || items.count < pageSize {
                break
            }
        }

        return pool
    }

    private func loadLocallyFilteredCandidates(
        in library: PlexLibrary,
        genre: LibraryGenreOption,
        usedTitles: RecommendationSeenTitles,
        itemsPerShelf: Int,
        libraryType: PlexLibraryType
    ) async throws -> [PlexItem] {
        let totalCount = try await plexService.getLibraryItemCount(
            sectionId: library.key,
            serverID: library.serverID
        )
        guard totalCount > 0 else { return [] }

        let pageSize = max(itemsPerShelf * 5, 60)
        let maxPagesToInspect = min(8, Int(ceil(Double(totalCount) / Double(pageSize))))
        guard maxPagesToInspect > 0 else { return [] }

        let shuffledPageOrder = rotatedPageOrder(
            pageCount: maxPagesToInspect,
            seed: dailySeed(for: "\(library.id)|\(genre.title)|local")
        )

        var pool: [PlexItem] = []
        var seen = usedTitles
        let desiredPoolSize = max(itemsPerShelf * 3, 24)

        for page in shuffledPageOrder {
            let items = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: page * pageSize,
                size: pageSize,
                sort: "titleSort",
                serverID: library.serverID
            )

            guard !items.isEmpty else { continue }

            for item in items where shouldIncludeCandidate(item, seen: seen) {
                guard isCandidateType(item, libraryType: libraryType) else { continue }
                guard await itemMatchesGenre(item, genre: genre) else { continue }

                seen.insert(item)
                pool.append(item)
            }

            if pool.count >= desiredPoolSize || items.count < pageSize {
                break
            }
        }

        return pool
    }

    private func matchingLibraryGenre(
        for genre: LibraryGenreOption,
        availableGenres: [LibraryGenreOption]
    ) -> LibraryGenreOption? {
        let normalizedGenreTitle = LibraryGenreSupport.normalizeGenreTitle(genre.title)

        return availableGenres.first { option in
            guard option.value != nil else { return false }
            return LibraryGenreSupport.normalizeGenreTitle(option.title) == normalizedGenreTitle
        }
    }

    private func interleavedShelves(
        movieShelves: [HomePersonalizedShelf],
        showShelves: [HomePersonalizedShelf]
    ) -> [HomePersonalizedShelf] {
        let combined = movieShelves + showShelves
        guard combined.count > 1 else { return combined }

        let seed = dailySeed(for: "shelf-order")
        return RecommendationSeededRandomizer(
            calendar: calendar,
            nowProvider: nowProvider
        ).seededShuffle(combined, seed: seed)
    }

    /// Collapses an episode to its show and keys on the *server* plus the
    /// rating key: the same numeric key means a different title on every
    /// server, so a bare key would fuse two servers' taste signals together.
    private func collapsedIdentity(
        for entry: PlexPlaybackHistoryEntry
    ) -> (identity: String, id: PlexItemID)? {
        let serverID = entry.serverID

        switch entry.type {
        case .episode:
            guard let showKey = extractRatingKey(from: entry.grandparentRatingKey),
                  !showKey.isEmpty else {
                return nil
            }

            let id = PlexItemID(serverID: serverID, ratingKey: showKey)
            return ("show:\(id.storageKey)", id)
        case .movie, .show:
            let id = PlexItemID(serverID: serverID, ratingKey: entry.ratingKey)
            return ("\(entry.type.rawValue):\(id.storageKey)", id)
        default:
            return nil
        }
    }

    private func extractRatingKey(from metadataKey: String?) -> String? {
        RecommendationCandidateSupport.extractRatingKey(from: metadataKey)
    }

    private func shouldIncludeCandidate(
        _ item: PlexItem,
        seen: RecommendationSeenTitles
    ) -> Bool {
        guard !seen.contains(item) else { return false }
        return !RecommendationCandidateSupport.isCompleted(item)
    }

    private func isRecommendationSignalItem(
        _ item: PlexItem,
        libraryType: PlexLibraryType
    ) -> Bool {
        isCandidateType(item, libraryType: libraryType)
    }

    private func isCandidateType(
        _ item: PlexItem,
        libraryType: PlexLibraryType
    ) -> Bool {
        switch libraryType {
        case .movie:
            return item.type == .movie
        case .show:
            return item.type == .show
        case .video, .liveTV:
            // Video ("Other Videos") libraries never feed the movie/show
            // recommendation engine.
            return false
        }
    }

    private func itemMatchesGenre(
        _ item: PlexItem,
        genre: LibraryGenreOption
    ) async -> Bool {
        if let genres = item.genres,
           LibraryGenreSupport.containsGenre(genres, matching: genre) {
            return true
        }

        guard let details = try? await plexService.getMediaDetails(
            ratingKey: item.ratingKey,
            serverID: item.serverID
        ), let genres = details.genres else {
            return false
        }

        return LibraryGenreSupport.containsGenre(genres, matching: genre)
    }

    private func dailySeed(for value: String) -> UInt64 {
        RecommendationSeededRandomizer(calendar: calendar, nowProvider: nowProvider)
            .dailySeed(for: value)
    }

    private func rotatedPageOrder(pageCount: Int, seed: UInt64) -> [Int] {
        RecommendationSeededRandomizer(calendar: calendar, nowProvider: nowProvider)
            .rotatedPageOrder(pageCount: pageCount, seed: seed)
    }

    private func seededShuffle(_ items: [PlexItem], seed: UInt64) -> [PlexItem] {
        RecommendationSeededRandomizer(calendar: calendar, nowProvider: nowProvider)
            .seededShuffle(items, seed: seed)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
