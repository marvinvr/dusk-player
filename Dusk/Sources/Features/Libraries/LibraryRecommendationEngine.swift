import Foundation
import OSLog

private let recommendationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "Recommendations"
)

@MainActor
struct LibraryRecommendationEngine {
    let library: PlexLibrary
    let plexService: PlexService
    var calendar: Calendar = .autoupdatingCurrent
    var nowProvider: @Sendable () -> Date = Date.init

    func loadShelves(
        itemsPerShelf: Int,
        shelfLimit: Int = 3
    ) async throws -> [LibraryPersonalizedShelf] {
        try await loadResult(
            itemsPerShelf: itemsPerShelf,
            shelfLimit: shelfLimit
        ).shelves
    }

    func loadResult(
        itemsPerShelf: Int,
        shelfLimit: Int = 3
    ) async throws -> LibraryRecommendationLoadResult {
        guard itemsPerShelf > 0, shelfLimit > 0 else {
            return LibraryRecommendationLoadResult(
                shelves: [],
                diagnostics: LibraryRecommendationDiagnostics(
                    candidateGenreCount: 0,
                    historyCount: 0,
                    historyGenreCount: 0,
                    fallbackViewedCount: 0,
                    fallbackGenreCount: 0,
                    shelfCount: 0
                )
            )
        }

        let availableGenres = try await LibraryGenreSupport.loadGenreOptions(
            sectionId: library.key,
            serverID: library.serverID,
            plexService: plexService
        )

        let candidateGenres = availableGenres.filter { $0.value != nil }

        guard let viewedSince = calendar.date(byAdding: .day, value: -30, to: nowProvider()) else {
            return LibraryRecommendationLoadResult(
                shelves: [],
                diagnostics: LibraryRecommendationDiagnostics(
                    candidateGenreCount: candidateGenres.count,
                    historyCount: 0,
                    historyGenreCount: 0,
                    fallbackViewedCount: 0,
                    fallbackGenreCount: 0,
                    shelfCount: 0
                )
            )
        }

        let currentUser = try? await plexService.getCurrentUser()
        var history = try await plexService.getPlaybackHistory(
            accountId: currentUser?.id,
            librarySectionId: library.key,
            viewedSince: viewedSince,
            serverID: library.serverID
        )

        // Some Plex servers under-serve account-scoped history. Fall back to
        // section-scoped history so recommendations still appear.
        if history.isEmpty, currentUser != nil {
            history = (try? await plexService.getPlaybackHistory(
                accountId: nil,
                librarySectionId: library.key,
                viewedSince: viewedSince,
                serverID: library.serverID
            )) ?? []
        }

        let usesRawGenreInference = candidateGenres.isEmpty
        var scoredGenres = usesRawGenreInference
            ? await scoreGenres(from: history)
            : await scoreGenres(from: history, availableGenres: candidateGenres)
        let historyGenreCount = scoredGenres.count
        var fallbackViewedCount = 0
        var fallbackGenreCount = 0

        if scoredGenres.isEmpty {
            let fallbackItems = try await loadRecentlyViewedItems(viewedSince: viewedSince)
            fallbackViewedCount = fallbackItems.count
            scoredGenres = usesRawGenreInference
                ? scoreGenres(fromRecentlyViewedItems: fallbackItems)
                : scoreGenres(fromRecentlyViewedItems: fallbackItems, availableGenres: candidateGenres)
            fallbackGenreCount = scoredGenres.count
        }

        guard !scoredGenres.isEmpty else {
            return LibraryRecommendationLoadResult(
                shelves: [],
                diagnostics: LibraryRecommendationDiagnostics(
                    candidateGenreCount: candidateGenres.count,
                    historyCount: history.count,
                    historyGenreCount: historyGenreCount,
                    fallbackViewedCount: fallbackViewedCount,
                    fallbackGenreCount: fallbackGenreCount,
                    shelfCount: 0
                )
            )
        }

        // Every genre's pool loads at once: on a large library each pool is a
        // few section-wide queries, and running them one genre after another
        // is what kept this screen on a spinner. Titles are de-duplicated
        // afterwards, in rank order, so a higher-ranked row keeps a title.
        let rankedGenres = Array(scoredGenres.prefix(shelfLimit))
        let pools = await withTaskGroup(of: (Int, [PlexItem]).self) { group in
            for (index, scoredGenre) in rankedGenres.enumerated() {
                group.addTask {
                    let pool = (try? await loadCandidatePool(
                        for: scoredGenre.genre,
                        itemsPerShelf: itemsPerShelf,
                        preferServerGenreFilter: !usesRawGenreInference
                    )) ?? []
                    return (index, pool)
                }
            }

            var pools = Array(repeating: [PlexItem](), count: rankedGenres.count)
            for await (index, pool) in group {
                pools[index] = pool
            }
            return pools
        }

        var shelves: [LibraryPersonalizedShelf] = []
        var usedTitles = RecommendationSeenTitles()

        for (scoredGenre, pool) in zip(rankedGenres, pools) {
            let items = Array(pool.filter { !usedTitles.contains($0) }.prefix(itemsPerShelf))

            guard items.count >= min(2, itemsPerShelf) else { continue }

            shelves.append(
                LibraryPersonalizedShelf(
                    genre: scoredGenre.genre,
                    title: "More \(scoredGenre.genre.title)",
                    items: items,
                    showAllLibrary: library
                )
            )

            usedTitles.formUnion(items)
        }

        return LibraryRecommendationLoadResult(
            shelves: shelves,
            diagnostics: LibraryRecommendationDiagnostics(
                    candidateGenreCount: candidateGenres.count,
                historyCount: history.count,
                historyGenreCount: historyGenreCount,
                fallbackViewedCount: fallbackViewedCount,
                fallbackGenreCount: fallbackGenreCount,
                shelfCount: shelves.count
            )
        )
    }

    private func scoreGenres(
        from history: [PlexPlaybackHistoryEntry],
        availableGenres: [LibraryGenreOption]
    ) async -> [RecommendationScoredGenre] {
        let signals = collapsedSignals(from: history)
        let genresByIdentity = await signalGenres(for: signals)
        return await RecommendationGenreScoring.scoreGenres(from: signals) { signal in
            LibraryGenreSupport.matchedGenres(
                for: genresByIdentity[signal.identity] ?? [],
                availableGenres: availableGenres
            )
        }
    }

    private func scoreGenres(
        from history: [PlexPlaybackHistoryEntry]
    ) async -> [RecommendationScoredGenre] {
        let signals = collapsedSignals(from: history)
        let genresByIdentity = await signalGenres(for: signals)
        return await RecommendationGenreScoring.scoreGenres(from: signals) { signal in
            LibraryGenreSupport.inferredGenres(from: genresByIdentity[signal.identity] ?? [])
        }
    }

    /// The genre tags of the titles scoring looks at, fetched concurrently: one
    /// metadata request per title, which in series added up to seconds before
    /// any row could be built.
    private func signalGenres(
        for signals: [RecommendationTasteSignal]
    ) async -> [String: [PlexTag]] {
        let service = plexService
        let scored = Array(signals.prefix(RecommendationGenreScoring.maxSignals))

        return await withTaskGroup(of: (String, [PlexTag]?).self) { group in
            for signal in scored {
                group.addTask {
                    let details = try? await service.getMediaDetails(
                        ratingKey: signal.ratingKey,
                        serverID: signal.serverID
                    )
                    return (signal.identity, details.map { $0.genres ?? [] })
                }
            }

            var genres: [String: [PlexTag]] = [:]
            for await (identity, tags) in group {
                if let tags {
                    genres[identity] = tags
                } else {
                    recommendationLogger.debug(
                        "Skipping \(identity, privacy: .public) because metadata could not be loaded"
                    )
                }
            }
            return genres
        }
    }

    private func scoreGenres(
        fromRecentlyViewedItems items: [PlexItem],
        availableGenres: [LibraryGenreOption]
    ) -> [RecommendationScoredGenre] {
        RecommendationGenreScoring.scoreGenres(fromRecentlyViewedItems: items) { item in
            LibraryGenreSupport.matchedGenres(
                for: item.genres ?? [],
                availableGenres: availableGenres
            )
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
                    type: identity.type,
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

    private func loadRecentlyViewedItems(viewedSince: Date) async throws -> [PlexItem] {
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

            for item in items where isRecommendationSignalItem(item) {
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

    /// A shuffled pool of candidates for one genre row, larger than the row so
    /// titles another row already shows can be dropped afterwards.
    private func loadCandidatePool(
        for genre: LibraryGenreOption,
        itemsPerShelf: Int,
        preferServerGenreFilter: Bool
    ) async throws -> [PlexItem] {
        if preferServerGenreFilter, let genreValue = genre.value {
            let serverFilteredCandidates = try await loadServerFilteredCandidates(
                for: genreValue,
                itemsPerShelf: itemsPerShelf
            )

            if serverFilteredCandidates.count >= min(2, itemsPerShelf) {
                return serverFilteredCandidates
            }
        }

        return try await loadLocallyFilteredCandidates(
            for: genre,
            itemsPerShelf: itemsPerShelf
        )
    }

    private func loadServerFilteredCandidates(
        for genreValue: String,
        itemsPerShelf: Int
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
            seed: dailySeed(for: genreValue)
        )

        var pool: [PlexItem] = []
        var seen = RecommendationSeenTitles()
        let desiredPoolSize = max(itemsPerShelf * 3, 24)

        for page in shuffledPageOrder {
            let start = page * pageSize
            let items = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: start,
                size: pageSize,
                sort: "titleSort",
                filters: filters,
                serverID: library.serverID
            )

            guard !items.isEmpty else { continue }

            for item in items where shouldIncludeCandidate(item, seen: seen) {
                seen.insert(item)
                pool.append(item)
            }

            if pool.count >= desiredPoolSize || items.count < pageSize {
                break
            }
        }

        return seededShuffle(pool, seed: dailySeed(for: "\(genreValue)|items"))
    }

    private func loadLocallyFilteredCandidates(
        for genre: LibraryGenreOption,
        itemsPerShelf: Int
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
            seed: dailySeed(for: "\(genre.title)|local-pages")
        )

        var pool: [PlexItem] = []
        var seen = RecommendationSeenTitles()
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
                guard await itemMatchesGenre(item, genre: genre) else { continue }

                seen.insert(item)
                pool.append(item)
            }

            if pool.count >= desiredPoolSize || items.count < pageSize {
                break
            }
        }

        return seededShuffle(pool, seed: dailySeed(for: "\(genre.title)|local-items"))
    }

    /// Keys on the *server* plus the rating key: the same numeric key means a
    /// different title on every server, so a bare key would fuse two servers'
    /// taste signals together.
    private func collapsedIdentity(
        for entry: PlexPlaybackHistoryEntry
    ) -> (identity: String, id: PlexItemID, type: PlexMediaType)? {
        let serverID = entry.serverID

        switch entry.type {
        case .episode:
            guard let showKey = extractRatingKey(from: entry.grandparentRatingKey),
                  !showKey.isEmpty else {
                return nil
            }

            let id = PlexItemID(serverID: serverID, ratingKey: showKey)
            return ("show:\(id.storageKey)", id, .show)
        case .movie, .show:
            let id = PlexItemID(serverID: serverID, ratingKey: entry.ratingKey)
            return ("\(entry.type.rawValue):\(id.storageKey)", id, entry.type)
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

    private func isRecommendationSignalItem(_ item: PlexItem) -> Bool {
        switch item.type {
        case .movie, .show:
            return true
        default:
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
        RecommendationSeededRandomizer(
            calendar: calendar,
            nowProvider: nowProvider,
            seedScope: library.id
        )
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

struct LibraryRecommendationLoadResult: Sendable {
    let shelves: [LibraryPersonalizedShelf]
    let diagnostics: LibraryRecommendationDiagnostics
}

struct LibraryRecommendationDiagnostics: Sendable {
    let candidateGenreCount: Int
    let historyCount: Int
    let historyGenreCount: Int
    let fallbackViewedCount: Int
    let fallbackGenreCount: Int
    let shelfCount: Int

    var summary: String {
        "Personalized rows: genres=\(candidateGenreCount), history=\(historyCount), historyMatches=\(historyGenreCount), fallbackViewed=\(fallbackViewedCount), fallbackMatches=\(fallbackGenreCount), shelves=\(shelfCount)"
    }
}
