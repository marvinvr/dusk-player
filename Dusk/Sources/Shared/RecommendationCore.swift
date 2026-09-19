import Foundation

/// One thing the user watched, collapsed to the title level, used to score
/// genres.
///
/// `id` carries the server: the signal is followed up with a metadata fetch, and
/// a bare rating key would read whatever item happens to share that key on the
/// primary server. `identity` is the de-duplication key and includes the server
/// for the same reason — two servers' "1423" are not the same show.
struct RecommendationTasteSignal: Sendable {
    let identity: String
    let id: PlexItemID
    let type: PlexMediaType?
    var weight: Double
    var lastViewedAt: Int

    var ratingKey: String { id.ratingKey }
    var serverID: String? { id.serverID }
}

struct RecommendationScoredGenre: Sendable {
    let genre: LibraryGenreOption
    var score: Double
}

@MainActor
enum RecommendationGenreScoring {
    static func scoreGenres(
        from signals: [RecommendationTasteSignal],
        minimumScore: Double = 0.35,
        genresForSignal: (RecommendationTasteSignal) async -> [LibraryGenreOption]
    ) async -> [RecommendationScoredGenre] {
        guard !signals.isEmpty else { return [] }

        var genreScores: [String: RecommendationScoredGenre] = [:]

        for signal in signals.prefix(18) {
            let genres = await genresForSignal(signal)
            addScores(
                for: genres,
                weight: signal.weight,
                to: &genreScores
            )
        }

        return sortedScores(genreScores, minimumScore: minimumScore)
    }

    static func scoreGenres(
        fromRecentlyViewedItems items: [PlexItem],
        minimumScore: Double = 0.25,
        genresForItem: (PlexItem) -> [LibraryGenreOption]
    ) -> [RecommendationScoredGenre] {
        guard !items.isEmpty else { return [] }

        var genreScores: [String: RecommendationScoredGenre] = [:]

        for (index, item) in items.enumerated() {
            let rankWeight = max(0.2, 1.0 - (Double(index) * 0.08))
            addScores(
                for: genresForItem(item),
                weight: rankWeight,
                to: &genreScores
            )
        }

        return sortedScores(genreScores, minimumScore: minimumScore)
    }

    private static func addScores(
        for genres: [LibraryGenreOption],
        weight: Double,
        to genreScores: inout [String: RecommendationScoredGenre]
    ) {
        guard !genres.isEmpty else { return }

        let perGenreWeight = weight / Double(genres.count)

        for genre in genres {
            guard let value = genre.value else { continue }

            if var existing = genreScores[value] {
                existing.score += perGenreWeight
                genreScores[value] = existing
            } else {
                genreScores[value] = RecommendationScoredGenre(genre: genre, score: perGenreWeight)
            }
        }
    }

    private static func sortedScores(
        _ genreScores: [String: RecommendationScoredGenre],
        minimumScore: Double
    ) -> [RecommendationScoredGenre] {
        genreScores.values
            .filter { $0.score >= minimumScore }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }

                return $0.genre.title.localizedStandardCompare($1.genre.title) == .orderedAscending
            }
    }
}

struct RecommendationSeededRandomizer {
    var calendar: Calendar
    var nowProvider: @Sendable () -> Date
    var seedScope: String? = nil

    func dailySeed(for value: String) -> UInt64 {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var seedParts: [String] = []
        if let seedScope = seedScope?.nilIfEmpty {
            seedParts.append(seedScope)
        }
        seedParts.append(value)
        seedParts.append(formatter.string(from: nowProvider()))
        return stableHash(seedParts.joined(separator: "|"))
    }

    func rotatedPageOrder(pageCount: Int, seed: UInt64) -> [Int] {
        guard pageCount > 0 else { return [] }
        let startIndex = Int(seed % UInt64(pageCount))
        return (0..<pageCount).map { (startIndex + $0) % pageCount }
    }

    func seededShuffle<Element>(_ items: [Element], seed: UInt64) -> [Element] {
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

/// The titles a recommendation pass has already used.
///
/// Tracks both the exact copy (`PlexItemID`) and the *content* (`PlexContentKey`)
/// because shelves now draw from several servers at once: without the content
/// key the same film sitting on two servers would fill two slots of the same
/// row, which is precisely the duplication merging is supposed to remove.
struct RecommendationSeenTitles {
    private var ids: Set<PlexItemID> = []
    private var contentKeys: Set<PlexContentKey> = []

    init() {}

    func contains(_ item: PlexItem) -> Bool {
        ids.contains(item.id) || contentKeys.contains(item.contentKey)
    }

    /// Returns false when the title was already used.
    @discardableResult
    mutating func insert(_ item: PlexItem) -> Bool {
        guard !contains(item) else { return false }
        ids.insert(item.id)
        contentKeys.insert(item.contentKey)
        return true
    }

    mutating func formUnion(_ items: some Sequence<PlexItem>) {
        for item in items {
            insert(item)
        }
    }
}

enum RecommendationCandidateSupport {
    static func extractRatingKey(from metadataKey: String?) -> String? {
        guard let metadataKey else { return nil }
        return metadataKey.split(separator: "/").last.map(String.init)
    }

    static func isCompleted(_ item: PlexItem) -> Bool {
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
