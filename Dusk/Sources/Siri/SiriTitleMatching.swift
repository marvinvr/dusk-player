import Foundation

/// Movie or show: the only two things Siri can ask Dusk to play.
enum SiriTitleKind: String, Codable, Sendable, Hashable {
    case movie
    case show
}

/// What the user asked Siri for, cleaned up for matching against Plex titles.
///
/// Siri hands over the spoken words, not a title: "the movie Dune 2021",
/// "brooklyn 99", "Rocky two". The query strips the words that only steer the
/// match (a kind hint, a release year) and keeps the rest as the title text.
struct SiriTitleQuery: Equatable, Sendable {
    /// The title as spoken, minus kind and year hints.
    let text: String
    let kind: SiriTitleKind?
    let year: Int?

    private static let kindPrefixes: [(String, SiriTitleKind)] = [
        ("the movie ", .movie),
        ("the film ", .movie),
        ("movie ", .movie),
        ("film ", .movie),
        ("the tv show ", .show),
        ("the tv series ", .show),
        ("the show ", .show),
        ("the series ", .show),
        ("tv show ", .show),
        ("show ", .show),
        ("series ", .show),
    ]

    init(_ spoken: String) {
        var text = spoken
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        var kind: SiriTitleKind?

        let lowered = text.lowercased()
        for (prefix, prefixKind) in Self.kindPrefixes where lowered.hasPrefix(prefix) {
            let remainder = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard !remainder.isEmpty else { break }
            text = remainder
            kind = prefixKind
            break
        }

        // "Dune 2021": a trailing year picks between remakes. A title that *is*
        // a year ("1917", "2012") keeps it.
        var year: Int?
        let words = text.split(separator: " ")
        if words.count > 1,
           let last = words.last,
           last.count == 4,
           let value = Int(last),
           (1900...2099).contains(value) {
            year = value
            text = words.dropLast().joined(separator: " ")
        }

        self.text = text
        self.kind = kind
        self.year = year
    }

    /// Plex search terms, best first.
    ///
    /// Plex's own search matches words, so "brooklyn 99" never finds "Brooklyn
    /// Nine-Nine". The spoken text goes first, then its digits spelled out, then
    /// the longest word alone so a misheard word elsewhere in the title still
    /// surfaces the right candidates for the fuzzy match to score.
    var searchTerms: [String] {
        var terms: [String] = []
        func add(_ term: String) {
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
            terms.append(trimmed)
        }

        add(text)
        add(SiriTitleNormalizer.spellingOutDigits(in: text))

        let words = SiriTitleNormalizer.words(in: text)
        if words.count > 1,
           let longest = words.max(by: { $0.count < $1.count }),
           longest.count >= 4 {
            add(longest)
        }
        return terms
    }
}

/// Turns a title into comparable tokens: case, accents and punctuation folded,
/// number words and roman numerals turned into digits.
enum SiriTitleNormalizer {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Single letters (I, V, X) are left alone: "I, Robot", "V for Vendetta"
    /// and "Malcolm X" are words, not sequel numbers.
    private static let romanNumerals: [String: Int] = [
        "ii": 2, "iii": 3, "iv": 4, "vi": 6, "vii": 7, "viii": 8, "ix": 9,
        "xi": 11, "xii": 12, "xiii": 13, "xiv": 14, "xv": 15, "xvi": 16,
    ]

    private static let digitWords = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    ]

    /// Lowercased, accent-free words with apostrophes dropped ("Ocean's" →
    /// "oceans") and every other symbol treated as a separator.
    static func words(in title: String) -> [String] {
        let folded = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")

        var words: [String] = []
        var current = ""
        for character in folded {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "’" || character == "ʼ" {
                continue
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    /// Comparable tokens: number words and sequel numerals become digits, and
    /// a leading "the" is dropped.
    static func tokens(_ title: String) -> [String] {
        var tokens: [String] = []
        var pendingTens: Int?

        func flushTens() {
            if let value = pendingTens {
                tokens.append(String(value))
                pendingTens = nil
            }
        }

        for word in words(in: title) {
            if let value = tens[word] {
                flushTens()
                pendingTens = value
            } else if let value = units[word] {
                if let tensValue = pendingTens, value < 10, value > 0 {
                    tokens.append(String(tensValue + value))
                    pendingTens = nil
                } else {
                    flushTens()
                    tokens.append(String(value))
                }
            } else if let value = romanNumerals[word] {
                flushTens()
                tokens.append(String(value))
            } else {
                flushTens()
                tokens.append(word)
            }
        }
        flushTens()

        if tokens.count > 1, tokens.first == "the" {
            tokens.removeFirst()
        }
        return tokens
    }

    /// "Brooklyn 99" → "Brooklyn nine nine", which Plex's word search matches.
    static func spellingOutDigits(in text: String) -> String {
        var result = ""
        var previousWasDigit = false
        for character in text {
            if let digit = character.wholeNumberValue, character.isASCII {
                if !result.isEmpty, !result.hasSuffix(" ") {
                    result.append(" ")
                }
                result.append(digitWords[digit])
                previousWasDigit = true
            } else {
                if previousWasDigit, character != " " {
                    result.append(" ")
                }
                result.append(character)
                previousWasDigit = false
            }
        }
        return result
    }
}

/// A movie or show Siri could mean.
struct SiriTitleCandidate: Equatable, Sendable {
    let id: MediaItemID
    let kind: SiriTitleKind
    let title: String
    let year: Int?
    /// Partly watched, or a show with an episode in progress.
    let isInProgress: Bool
    /// Unix seconds; any watch history at all is a signal.
    let lastViewedAt: Int?

    init(
        id: MediaItemID,
        kind: SiriTitleKind,
        title: String,
        year: Int?,
        isInProgress: Bool = false,
        lastViewedAt: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.year = year
        self.isInProgress = isInProgress
        self.lastViewedAt = lastViewedAt
    }
}

enum SiriTitleResolution: Equatable, Sendable {
    case match(SiriTitleCandidate)
    /// Equally good candidates, best first; Siri asks which one.
    case ambiguous([SiriTitleCandidate])
    case notFound
}

/// Picks the movie or show a spoken title means.
///
/// Exact matches (after folding) win outright, then titles the query starts
/// ("star wars" → "Star Wars: A New Hope"), then titles containing all of its
/// words, then near-misses by edit distance for mis-transcriptions. Candidates
/// that score about the same are separated by the kind/year hints and by watch
/// history; what is still tied comes back as ambiguous.
enum SiriTitleMatcher {
    static let minimumScore = 0.75
    /// Scores within this distance of the best one are treated as a tie.
    static let tieTolerance = 0.04
    static let maxChoices = 5

    static func resolve(_ query: SiriTitleQuery, among candidates: [SiriTitleCandidate]) -> SiriTitleResolution {
        let ranked = rank(query, among: candidates)
        guard let best = ranked.first else { return .notFound }

        var contenders = ranked
            .filter { $0.score >= best.score - tieTolerance }
            .map(\.candidate)
        guard contenders.count > 1 else { return .match(best.candidate) }

        if let year = query.year {
            contenders = narrowed(contenders) { $0.year == year }
        }
        contenders = narrowed(contenders) { $0.isInProgress }
        contenders = narrowed(contenders) { $0.lastViewedAt != nil }

        if contenders.count == 1, let only = contenders.first {
            return .match(only)
        }
        return .ambiguous(Array(contenders.prefix(maxChoices)))
    }

    /// Every candidate worth offering, best first, with duplicates of the same
    /// title (another server's copy) removed. Input order is the tie-breaker,
    /// so pass candidates in server priority order.
    static func rank(_ query: SiriTitleQuery, among candidates: [SiriTitleCandidate]) -> [(candidate: SiriTitleCandidate, score: Double)] {
        let queryTokens = SiriTitleNormalizer.tokens(query.text)
        guard !queryTokens.isEmpty else { return [] }

        var pool = candidates
        if let kind = query.kind {
            let ofKind = pool.filter { $0.kind == kind }
            if !ofKind.isEmpty {
                pool = ofKind
            }
        }

        var seen: Set<String> = []
        var scored: [(candidate: SiriTitleCandidate, score: Double, order: Int)] = []
        for (order, candidate) in pool.enumerated() {
            let titleTokens = SiriTitleNormalizer.tokens(candidate.title)
            let identity = "\(candidate.kind.rawValue)|\(titleTokens.joined())|\(candidate.year.map(String.init) ?? "")"
            guard seen.insert(identity).inserted else { continue }

            // "The Office (US)", "Doctor Who (2005)": the qualifier is how
            // Plex tells versions apart, never part of what anyone says.
            var matchScore = score(queryTokens, against: titleTokens)
            let unqualified = withoutQualifiers(candidate.title)
            if unqualified != candidate.title {
                matchScore = max(matchScore, score(queryTokens, against: SiriTitleNormalizer.tokens(unqualified)))
            }
            if let year = query.year, candidate.year == year {
                matchScore += 0.02
            }
            guard matchScore >= minimumScore else { continue }
            scored.append((candidate, matchScore, order))
        }

        return scored
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.order < rhs.order
            }
            .map { ($0.candidate, $0.score) }
    }

    static func score(_ query: String, against title: String) -> Double {
        score(SiriTitleNormalizer.tokens(query), against: SiriTitleNormalizer.tokens(title))
    }

    private static func score(_ query: [String], against title: [String]) -> Double {
        guard !query.isEmpty, !title.isEmpty else { return 0 }

        // Joined without spaces, so "Nine-Nine" / "99" / "S.W.A.T." / "SWAT"
        // compare equal however they were split.
        let queryCompact = query.joined()
        let titleCompact = title.joined()
        if queryCompact == titleCompact {
            return 1
        }

        let coverage = Double(queryCompact.count) / Double(max(titleCompact.count, 1))

        if title.count > query.count, Array(title.prefix(query.count)) == query {
            return 0.85 + 0.1 * coverage
        }

        if queryCompact.count >= 4, containsInOrder(query, in: title) {
            return 0.78 + 0.1 * coverage
        }

        let similarity = 1 - Double(editDistance(queryCompact, titleCompact))
            / Double(max(queryCompact.count, titleCompact.count))
        return similarity >= 0.8 ? similarity * 0.95 : 0
    }

    /// The title with parenthesised and bracketed parts removed.
    private static func withoutQualifiers(_ title: String) -> String {
        var result = ""
        var depth = 0
        for character in title {
            switch character {
            case "(", "[":
                depth += 1
            case ")", "]":
                depth = max(depth - 1, 0)
            default:
                if depth == 0 {
                    result.append(character)
                }
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    private static func containsInOrder(_ needle: [String], in haystack: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Keeps only the candidates matching `predicate`, unless none or all do.
    private static func narrowed(
        _ candidates: [SiriTitleCandidate],
        by predicate: (SiriTitleCandidate) -> Bool
    ) -> [SiriTitleCandidate] {
        let kept = candidates.filter(predicate)
        return kept.isEmpty ? candidates : kept
    }
}

/// Which episode "play <show>" starts: Plex's On Deck rule.
///
/// An episode in progress resumes (the most recently watched one if there are
/// several); otherwise the first unwatched episode after the one watched last;
/// otherwise the first unwatched episode; and a fully watched show starts over.
/// Specials only count when the show has nothing else.
enum SiriNextEpisodePicker {
    struct Episode: Equatable, Sendable {
        let id: MediaItemID
        let season: Int?
        let index: Int?
        let isWatched: Bool
        let isInProgress: Bool
        let lastViewedAt: Int?
    }

    static func pick(from episodes: [Episode]) -> Episode? {
        let regular = episodes.filter { ($0.season ?? 1) != 0 }
        let ordered = (regular.isEmpty ? episodes : regular).sorted { lhs, rhs in
            (lhs.season ?? 0, lhs.index ?? 0) < (rhs.season ?? 0, rhs.index ?? 0)
        }

        if let resuming = ordered
            .filter(\.isInProgress)
            .max(by: { ($0.lastViewedAt ?? 0) < ($1.lastViewedAt ?? 0) }) {
            return resuming
        }

        if let lastWatched = ordered.indices
            .filter({ ordered[$0].isWatched && ordered[$0].lastViewedAt != nil })
            .max(by: { (ordered[$0].lastViewedAt ?? 0) < (ordered[$1].lastViewedAt ?? 0) }),
           let next = ordered[(lastWatched + 1)...].first(where: { !$0.isWatched }) {
            return next
        }

        return ordered.first { !$0.isWatched } ?? ordered.first
    }
}
