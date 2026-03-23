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
            viewedSince: viewedSince
        )

        // Some Plex servers under-serve account-scoped history. Fall back to
        // section-scoped history so recommendations still appear.
        if history.isEmpty, currentUser != nil {
            history = (try? await plexService.getPlaybackHistory(
                accountId: nil,
                librarySectionId: library.key,
                viewedSince: viewedSince
            )) ?? []
        }

        let usesRawGenreInference = candidateGenres.isEmpty
        var scoredGenres = usesRawGenreInference
            ? try await scoreGenres(from: history)
            : try await scoreGenres(from: history, availableGenres: candidateGenres)
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

        var shelves: [LibraryPersonalizedShelf] = []
        var usedRatingKeys = Set<String>()

        for scoredGenre in scoredGenres.prefix(shelfLimit) {
            let items = (try? await loadCandidates(
                for: scoredGenre.genre,
                usedRatingKeys: usedRatingKeys,
                itemsPerShelf: itemsPerShelf,
                preferServerGenreFilter: !usesRawGenreInference
            )) ?? []

            guard items.count >= min(2, itemsPerShelf) else { continue }

            shelves.append(
                LibraryPersonalizedShelf(
                    genre: scoredGenre.genre,
                    title: "More \(scoredGenre.genre.title)",
                    items: items
                )
            )

            usedRatingKeys.formUnion(items.map(\.ratingKey))
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
    ) async throws -> [ScoredGenre] {
        let signals = collapsedSignals(from: history)
        guard !signals.isEmpty else { return [] }

        var genreScores: [String: ScoredGenre] = [:]

        for signal in signals.prefix(18) {
            guard let details = try? await plexService.getMediaDetails(ratingKey: signal.ratingKey) else {
                recommendationLogger.debug(
                    "Skipping ratingKey \(signal.ratingKey, privacy: .public) because metadata could not be loaded"
                )
                continue
            }
            let genres = LibraryGenreSupport.matchedGenres(
                for: details.genres ?? [],
                availableGenres: availableGenres
            )

            guard !genres.isEmpty else { continue }

            let perGenreWeight = signal.weight / Double(genres.count)

            for genre in genres {
                guard let value = genre.value else { continue }

                if var existing = genreScores[value] {
                    existing.score += perGenreWeight
                    genreScores[value] = existing
                } else {
                    genreScores[value] = ScoredGenre(genre: genre, score: perGenreWeight)
                }
            }
        }

        return genreScores.values
            .filter { $0.score >= 0.35 }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }

                return $0.genre.title.localizedStandardCompare($1.genre.title) == .orderedAscending
            }
    }

    private func scoreGenres(
        from history: [PlexPlaybackHistoryEntry]
    ) async throws -> [ScoredGenre] {
        let signals = collapsedSignals(from: history)
        guard !signals.isEmpty else { return [] }

        var genreScores: [String: ScoredGenre] = [:]

        for signal in signals.prefix(18) {
            guard let details = try? await plexService.getMediaDetails(ratingKey: signal.ratingKey) else {
                recommendationLogger.debug(
                    "Skipping ratingKey \(signal.ratingKey, privacy: .public) because metadata could not be loaded"
                )
                continue
            }

            let genres = LibraryGenreSupport.inferredGenres(from: details.genres ?? [])
            guard !genres.isEmpty else { continue }

            let perGenreWeight = signal.weight / Double(genres.count)

            for genre in genres {
                guard let value = genre.value else { continue }

                if var existing = genreScores[value] {
                    existing.score += perGenreWeight
                    genreScores[value] = existing
                } else {
                    genreScores[value] = ScoredGenre(genre: genre, score: perGenreWeight)
                }
            }
        }

        return genreScores.values
            .filter { $0.score >= 0.35 }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }

                return $0.genre.title.localizedStandardCompare($1.genre.title) == .orderedAscending
            }
    }

    private func scoreGenres(
        fromRecentlyViewedItems items: [PlexItem],
        availableGenres: [LibraryGenreOption]
    ) -> [ScoredGenre] {
        guard !items.isEmpty else { return [] }

        var genreScores: [String: ScoredGenre] = [:]

        for (index, item) in items.enumerated() {
            let matchedGenres = LibraryGenreSupport.matchedGenres(
                for: item.genres ?? [],
                availableGenres: availableGenres
            )

            guard !matchedGenres.isEmpty else { continue }

            let rankWeight = max(0.2, 1.0 - (Double(index) * 0.08))
            let perGenreWeight = rankWeight / Double(matchedGenres.count)

            for genre in matchedGenres {
                guard let value = genre.value else { continue }

                if var existing = genreScores[value] {
                    existing.score += perGenreWeight
                    genreScores[value] = existing
                } else {
                    genreScores[value] = ScoredGenre(genre: genre, score: perGenreWeight)
                }
            }
        }

        return genreScores.values
            .filter { $0.score >= 0.25 }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }

                return $0.genre.title.localizedStandardCompare($1.genre.title) == .orderedAscending
            }
    }

    private func scoreGenres(
        fromRecentlyViewedItems items: [PlexItem]
    ) -> [ScoredGenre] {
        guard !items.isEmpty else { return [] }

        var genreScores: [String: ScoredGenre] = [:]

        for (index, item) in items.enumerated() {
            let matchedGenres = LibraryGenreSupport.inferredGenres(from: item.genres ?? [])
            guard !matchedGenres.isEmpty else { continue }

            let rankWeight = max(0.2, 1.0 - (Double(index) * 0.08))
            let perGenreWeight = rankWeight / Double(matchedGenres.count)

            for genre in matchedGenres {
                guard let value = genre.value else { continue }

                if var existing = genreScores[value] {
                    existing.score += perGenreWeight
                    genreScores[value] = existing
                } else {
                    genreScores[value] = ScoredGenre(genre: genre, score: perGenreWeight)
                }
            }
        }

        return genreScores.values
            .filter { $0.score >= 0.25 }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }

                return $0.genre.title.localizedStandardCompare($1.genre.title) == .orderedAscending
            }
    }

    private func collapsedSignals(from history: [PlexPlaybackHistoryEntry]) -> [TasteSignal] {
        let now = nowProvider()
        var signalByIdentity: [String: TasteSignal] = [:]

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
                signalByIdentity[identity.identity] = TasteSignal(
                    identity: identity.identity,
                    ratingKey: identity.ratingKey,
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
                sort: "lastViewedAt:desc"
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

    private func loadCandidates(
        for genre: LibraryGenreOption,
        usedRatingKeys: Set<String>,
        itemsPerShelf: Int,
        preferServerGenreFilter: Bool
    ) async throws -> [PlexItem] {
        if preferServerGenreFilter, let genreValue = genre.value {
            let serverFilteredCandidates = try await loadServerFilteredCandidates(
                for: genreValue,
                usedRatingKeys: usedRatingKeys,
                itemsPerShelf: itemsPerShelf
            )

            if serverFilteredCandidates.count >= min(2, itemsPerShelf) {
                return serverFilteredCandidates
            }
        }

        return try await loadLocallyFilteredCandidates(
            for: genre,
            usedRatingKeys: usedRatingKeys,
            itemsPerShelf: itemsPerShelf
        )
    }

    private func loadServerFilteredCandidates(
        for genreValue: String,
        usedRatingKeys: Set<String>,
        itemsPerShelf: Int
    ) async throws -> [PlexItem] {
        let filters = ["genre": genreValue]
        let totalCount = try await plexService.getLibraryItemCount(
            sectionId: library.key,
            filters: filters
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
        var seenRatingKeys = usedRatingKeys
        let desiredPoolSize = max(itemsPerShelf * 3, 24)

        for page in shuffledPageOrder {
            let start = page * pageSize
            let items = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: start,
                size: pageSize,
                sort: "titleSort",
                filters: filters
            )

            guard !items.isEmpty else { continue }

            for item in items where shouldIncludeCandidate(item, seenRatingKeys: seenRatingKeys) {
                seenRatingKeys.insert(item.ratingKey)
                pool.append(item)
            }

            if pool.count >= desiredPoolSize || items.count < pageSize {
                break
            }
        }

        return Array(
            seededShuffle(pool, seed: dailySeed(for: "\(genreValue)|items"))
                .prefix(itemsPerShelf)
        )
    }

    private func loadLocallyFilteredCandidates(
        for genre: LibraryGenreOption,
        usedRatingKeys: Set<String>,
        itemsPerShelf: Int
    ) async throws -> [PlexItem] {
        let totalCount = try await plexService.getLibraryItemCount(sectionId: library.key)

        guard totalCount > 0 else { return [] }

        let pageSize = max(itemsPerShelf * 5, 60)
        let maxPagesToInspect = min(8, Int(ceil(Double(totalCount) / Double(pageSize))))
        guard maxPagesToInspect > 0 else { return [] }

        let shuffledPageOrder = rotatedPageOrder(
            pageCount: maxPagesToInspect,
            seed: dailySeed(for: "\(genre.title)|local-pages")
        )

        var pool: [PlexItem] = []
        var seenRatingKeys = usedRatingKeys
        let desiredPoolSize = max(itemsPerShelf * 3, 24)

        for page in shuffledPageOrder {
            let items = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: page * pageSize,
                size: pageSize,
                sort: "titleSort"
            )

            guard !items.isEmpty else { continue }

            for item in items where shouldIncludeCandidate(item, seenRatingKeys: seenRatingKeys) {
                guard await itemMatchesGenre(item, genre: genre) else { continue }

                seenRatingKeys.insert(item.ratingKey)
                pool.append(item)
            }

            if pool.count >= desiredPoolSize || items.count < pageSize {
                break
            }
        }

        return Array(
            seededShuffle(pool, seed: dailySeed(for: "\(genre.title)|local-items"))
                .prefix(itemsPerShelf)
        )
    }

    private func collapsedIdentity(
        for entry: PlexPlaybackHistoryEntry
    ) -> (identity: String, ratingKey: String, type: PlexMediaType)? {
        switch entry.type {
        case .episode:
            guard let showKey = extractRatingKey(from: entry.grandparentRatingKey),
                  !showKey.isEmpty else {
                return nil
            }

            return ("show:\(showKey)", showKey, .show)
        case .movie, .show:
            return ("\(entry.type.rawValue):\(entry.ratingKey)", entry.ratingKey, entry.type)
        default:
            return nil
        }
    }

    private func extractRatingKey(from metadataKey: String?) -> String? {
        guard let metadataKey else { return nil }
        return metadataKey.split(separator: "/").last.map(String.init)
    }

    private func shouldIncludeCandidate(
        _ item: PlexItem,
        seenRatingKeys: Set<String>
    ) -> Bool {
        guard !seenRatingKeys.contains(item.ratingKey) else { return false }
        return !isCompleted(item)
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

        guard let details = try? await plexService.getMediaDetails(ratingKey: item.ratingKey),
              let genres = details.genres else {
            return false
        }

        return LibraryGenreSupport.containsGenre(genres, matching: genre)
    }

    private func isCompleted(_ item: PlexItem) -> Bool {
        switch item.type {
        case .show, .season:
            if let leafCount = item.leafCount,
               leafCount > 0,
               let viewedLeafCount = item.viewedLeafCount {
                return viewedLeafCount >= leafCount
            }

            return item.isWatched
        default:
            return item.isWatched
        }
    }

    private func dailySeed(for value: String) -> UInt64 {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let seedSource = "\(library.key)|\(value)|\(formatter.string(from: nowProvider()))"
        return stableHash(seedSource)
    }

    private func rotatedPageOrder(pageCount: Int, seed: UInt64) -> [Int] {
        guard pageCount > 0 else { return [] }
        let startIndex = Int(seed % UInt64(pageCount))
        return (0..<pageCount).map { (startIndex + $0) % pageCount }
    }

    private func seededShuffle(_ items: [PlexItem], seed: UInt64) -> [PlexItem] {
        guard items.count > 1 else { return items }

        var shuffled = items
        var generator = SplitMix64(state: seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed)

        for index in stride(from: shuffled.count - 1, through: 1, by: -1) {
            let randomIndex = Int(generator.next() % UInt64(index + 1))
            if randomIndex != index {
                shuffled.swapAt(index, randomIndex)
            }
        }

        return shuffled
    }

    private func stableHash(_ string: String) -> UInt64 {
        let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3

        return string.utf8.reduce(offsetBasis) { hash, byte in
            (hash ^ UInt64(byte)) &* prime
        }
    }
}

private struct TasteSignal {
    let identity: String
    let ratingKey: String
    let type: PlexMediaType
    var weight: Double
    var lastViewedAt: Int
}

struct LibraryRecommendationLoadResult {
    let shelves: [LibraryPersonalizedShelf]
    let diagnostics: LibraryRecommendationDiagnostics
}

struct LibraryRecommendationDiagnostics {
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

private struct ScoredGenre {
    let genre: LibraryGenreOption
    var score: Double
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
