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
        movieShelfLimit: Int = 3,
        showShelfLimit: Int = 2
    ) async throws -> [HomePersonalizedShelf] {
        guard itemsPerShelf > 0 else { return [] }

        let libraries = try await plexService.getLibraries()
        let movieLibraries = libraries
            .filter { $0.libraryType == .movie }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let showLibraries = libraries
            .filter { $0.libraryType == .show }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

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

        var scoredGenres = try await scoreGenres(from: history)

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
        var usedRatingKeys = Set<String>()
        let showAllLibrary = libraries.count == 1 ? libraries.first : nil

        for scoredGenre in scoredGenres.prefix(shelfLimit) {
            let items = try await loadCandidates(
                for: scoredGenre.genre,
                libraries: libraries,
                availableGenresByLibrary: availableGenresByLibrary,
                usedRatingKeys: usedRatingKeys,
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

            usedRatingKeys.formUnion(items.map(\.ratingKey))
        }

        return shelves
    }

    private func loadAvailableGenresByLibrary(
        libraries: [PlexLibrary]
    ) async -> [String: [LibraryGenreOption]] {
        var genresByLibrary: [String: [LibraryGenreOption]] = [:]

        for library in libraries {
            if let genres = try? await LibraryGenreSupport.loadGenreOptions(
                sectionId: library.key,
                plexService: plexService
            ) {
                genresByLibrary[library.key] = genres
            } else {
                genresByLibrary[library.key] = [.all]
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
            var history = try await plexService.getPlaybackHistory(
                accountId: currentUserID,
                librarySectionId: library.key,
                viewedSince: viewedSince
            )

            if history.isEmpty, currentUserID != nil {
                history = (try? await plexService.getPlaybackHistory(
                    accountId: nil,
                    librarySectionId: library.key,
                    viewedSince: viewedSince
                )) ?? []
            }

            entries.append(contentsOf: history)
        }

        return entries
    }

    private func scoreGenres(
        from history: [PlexPlaybackHistoryEntry]
    ) async throws -> [HomeScoredGenre] {
        let signals = collapsedSignals(from: history)
        guard !signals.isEmpty else { return [] }

        var genreScores: [String: HomeScoredGenre] = [:]

        for signal in signals.prefix(18) {
            guard let details = try? await plexService.getMediaDetails(ratingKey: signal.ratingKey) else {
                homeRecommendationLogger.debug(
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
                    genreScores[value] = HomeScoredGenre(genre: genre, score: perGenreWeight)
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
        fromRecentlyViewedItems items: [PlexItem]
    ) -> [HomeScoredGenre] {
        guard !items.isEmpty else { return [] }

        var genreScores: [String: HomeScoredGenre] = [:]

        for (index, item) in items.enumerated() {
            let genres = LibraryGenreSupport.inferredGenres(from: item.genres ?? [])
            guard !genres.isEmpty else { continue }

            let rankWeight = max(0.2, 1.0 - (Double(index) * 0.08))
            let perGenreWeight = rankWeight / Double(genres.count)

            for genre in genres {
                guard let value = genre.value else { continue }

                if var existing = genreScores[value] {
                    existing.score += perGenreWeight
                    genreScores[value] = existing
                } else {
                    genreScores[value] = HomeScoredGenre(genre: genre, score: perGenreWeight)
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

    private func collapsedSignals(from history: [PlexPlaybackHistoryEntry]) -> [HomeTasteSignal] {
        let now = nowProvider()
        var signalByIdentity: [String: HomeTasteSignal] = [:]

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
                signalByIdentity[identity.identity] = HomeTasteSignal(
                    identity: identity.identity,
                    ratingKey: identity.ratingKey,
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

        var seenRatingKeys = Set<String>()

        return items
            .sorted { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }
            .filter { seenRatingKeys.insert($0.ratingKey).inserted }
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
                sort: "lastViewedAt:desc"
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
        usedRatingKeys: Set<String>,
        itemsPerShelf: Int,
        libraryType: PlexLibraryType
    ) async throws -> [PlexItem] {
        var pool: [PlexItem] = []
        var seenRatingKeys = usedRatingKeys
        let desiredPoolSize = max(itemsPerShelf * 4, 24)
        let librarySeed = libraries.map(\.key).joined(separator: ",")

        for library in libraries {
            let matchedLibraryGenre = matchingLibraryGenre(
                for: genre,
                availableGenres: availableGenresByLibrary[library.key] ?? [.all]
            )

            let libraryItems: [PlexItem]

            if let matchedLibraryGenre, let genreValue = matchedLibraryGenre.value {
                let serverFilteredItems = try await loadServerFilteredCandidates(
                    in: library,
                    genreValue: genreValue,
                    usedRatingKeys: seenRatingKeys,
                    itemsPerShelf: max(itemsPerShelf * 2, 12),
                    libraryType: libraryType
                )

                if serverFilteredItems.count >= min(2, itemsPerShelf) {
                    libraryItems = serverFilteredItems
                } else {
                    libraryItems = try await loadLocallyFilteredCandidates(
                        in: library,
                        genre: genre,
                        usedRatingKeys: seenRatingKeys,
                        itemsPerShelf: max(itemsPerShelf * 2, 12),
                        libraryType: libraryType
                    )
                }
            } else {
                libraryItems = try await loadLocallyFilteredCandidates(
                    in: library,
                    genre: genre,
                    usedRatingKeys: seenRatingKeys,
                    itemsPerShelf: max(itemsPerShelf * 2, 12),
                    libraryType: libraryType
                )
            }

            for item in libraryItems where shouldIncludeCandidate(item, seenRatingKeys: seenRatingKeys) {
                seenRatingKeys.insert(item.ratingKey)
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
        usedRatingKeys: Set<String>,
        itemsPerShelf: Int,
        libraryType: PlexLibraryType
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
            seed: dailySeed(for: "\(library.key)|\(genreValue)")
        )

        var pool: [PlexItem] = []
        var seenRatingKeys = usedRatingKeys
        let desiredPoolSize = max(itemsPerShelf * 3, 24)

        for page in shuffledPageOrder {
            let items = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: page * pageSize,
                size: pageSize,
                sort: "titleSort",
                filters: filters
            )

            guard !items.isEmpty else { continue }

            for item in items where shouldIncludeCandidate(item, seenRatingKeys: seenRatingKeys) {
                guard isCandidateType(item, libraryType: libraryType) else { continue }
                seenRatingKeys.insert(item.ratingKey)
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
        usedRatingKeys: Set<String>,
        itemsPerShelf: Int,
        libraryType: PlexLibraryType
    ) async throws -> [PlexItem] {
        let totalCount = try await plexService.getLibraryItemCount(sectionId: library.key)
        guard totalCount > 0 else { return [] }

        let pageSize = max(itemsPerShelf * 5, 60)
        let maxPagesToInspect = min(8, Int(ceil(Double(totalCount) / Double(pageSize))))
        guard maxPagesToInspect > 0 else { return [] }

        let shuffledPageOrder = rotatedPageOrder(
            pageCount: maxPagesToInspect,
            seed: dailySeed(for: "\(library.key)|\(genre.title)|local")
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
                guard isCandidateType(item, libraryType: libraryType) else { continue }
                guard await itemMatchesGenre(item, genre: genre) else { continue }

                seenRatingKeys.insert(item.ratingKey)
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
        [
            movieShelves[safe: 0],
            showShelves[safe: 0],
            movieShelves[safe: 1],
            showShelves[safe: 1],
            movieShelves[safe: 2],
        ]
        .compactMap { $0 }
    }

    private func collapsedIdentity(
        for entry: PlexPlaybackHistoryEntry
    ) -> (identity: String, ratingKey: String)? {
        switch entry.type {
        case .episode:
            guard let showKey = extractRatingKey(from: entry.grandparentRatingKey),
                  !showKey.isEmpty else {
                return nil
            }

            return ("show:\(showKey)", showKey)
        case .movie, .show:
            return ("\(entry.type.rawValue):\(entry.ratingKey)", entry.ratingKey)
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

        let seedSource = "\(value)|\(formatter.string(from: nowProvider()))"
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
        var generator = HomeSplitMix64(state: seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed)

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

private struct HomeTasteSignal {
    let identity: String
    let ratingKey: String
    var weight: Double
    var lastViewedAt: Int
}

private struct HomeScoredGenre {
    let genre: LibraryGenreOption
    var score: Double
}

private struct HomeSplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
