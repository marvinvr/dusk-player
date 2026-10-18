import Foundation

/// Local sequence alignment on timestamped frame correspondences. No frame is
/// reused in a path, and skipped informative frames count against coverage.
enum IntroOpeningFingerprintMatcher {
    static let sampleWindow: TimeInterval = 5
    static let minimumSamples = 4
    // Calibrated against quarter-second sampling phase differences in real
    // openings. Mean-distance, coverage, clock and diversity gates still apply.
    private static let looseDistance = 0.40
    private static let maximumGap: TimeInterval = 2
    private static let consecutiveFrameDistance = 0.025
    private static let distinctVisualGroupDistance = 0.12
    private static let maximumVisualGroups = 3
    private static let maximumMarkerOffset: TimeInterval = 2
    private static let maximumSearchClockDrift = 0.1
    private static let allowedClockRates = 0.9...1.1
    private static let clockResidualTolerance: TimeInterval = 0.75
    private static let skippedFramePenalty = 0.25
    private static let minimumCoverageWeight = 0.001

    private struct Requirements {
        let window: TimeInterval
        let pairs: Int
        let span: TimeInterval
        let coverage: Double
        let meanDistance: Double
        let diversity: Int
        let strongDistance: Double
    }

    // Short, very close sequences can establish a repeat before the courtesy
    // delay expires. Longer evidence permits more visual variation.
    private static let shortSequenceRequirements = Requirements(
        window: 1.25, pairs: 4, span: 0.75, coverage: 0.8,
        meanDistance: 0.12, diversity: 2, strongDistance: 0.26
    )
    private static let motionTolerantRequirements = Requirements(
        window: 2, pairs: 6, span: 1.25, coverage: 0.75,
        meanDistance: 0.28, diversity: 3, strongDistance: 0.36
    )
    private static let fullWindowRequirements = Requirements(
        window: sampleWindow, pairs: 6, span: 4, coverage: 0.8,
        meanDistance: 0.15, diversity: 3, strongDistance: 0.26
    )
    private static let requirements = [shortSequenceRequirements, motionTolerantRequirements, fullWindowRequirements]

    static func independentPoints(_ points: [IntroFingerprintPoint]) -> [IntroFingerprintPoint] {
        var result: [IntroFingerprintPoint] = []
        for point in points where point.isValid {
            // Collapse only consecutive near-identical pictures, not a later
            // return to an earlier shot. A held card supplies one vote.
            if let previous = result.last, previous.hash.distance(to: point.hash) <= consecutiveFrameDistance { continue }
            result.append(point)
        }
        return result
    }

    static func visualDiversity(_ points: [IntroFingerprintPoint]) -> Int {
        var representatives: [IntroFrameHash] = []
        for point in points {
            if representatives.allSatisfy({ $0.distance(to: point.hash) > distinctVisualGroupDistance }) {
                representatives.append(point.hash)
            }
            if representatives.count >= maximumVisualGroups { break }
        }
        return representatives.count
    }

    static func recognize(
        _ candidate: IntroOpeningFingerprint,
        among references: [IntroOpeningFingerprint],
        at time: TimeInterval
    ) -> IntroFingerprintComparison {
        var best = IntroFingerprintComparison()
        for reference in references {
            if Task.isCancelled { break }
            guard reference.observationID != candidate.observationID,
                  reference.playbackSessionID != candidate.playbackSessionID,
                  reference.isEligibleReference else { continue }
            let comparison = compare(candidate, reference, at: time)
            if isBetter(comparison, than: best) { best = comparison }
        }
        return best
    }

    static func compare(
        _ candidate: IntroOpeningFingerprint,
        _ reference: IntroOpeningFingerprint,
        at time: TimeInterval
    ) -> IntroFingerprintComparison {
        guard candidate.algorithmVersion == IntroOpeningFingerprint.currentAlgorithmVersion,
              reference.algorithmVersion == IntroOpeningFingerprint.currentAlgorithmVersion,
              time.isFinite else { return IntroFingerprintComparison() }
        let known = independentPoints(reference.points)
        var best = IntroFingerprintComparison()
        for requirement in requirements {
            let query = independentPoints(candidate.points.filter {
                $0.time >= time - requirement.window - IntroFingerprintPoint.timestampTolerance
                    && $0.time <= time + IntroFingerprintPoint.timestampTolerance
            })
            guard query.count >= requirement.pairs, known.count >= requirement.pairs else { continue }
            let result = align(query, with: known, at: time, requirement: requirement)
            if isBetter(result, than: best) { best = result }
        }
        return best
    }

    private static func align(_ query: [IntroFingerprintPoint], with known: [IntroFingerprintPoint],
                              at time: TimeInterval, requirement: Requirements) -> IntroFingerprintComparison {
        let columns = known.count
        let size = query.count * columns
        var scores = [Double](repeating: -.infinity, count: size)
        var predecessors = [Int](repeating: -1, count: size)
        var distances = [Double](repeating: 1, count: size)
        var best = IntroFingerprintComparison()

        for i in query.indices {
            if Task.isCancelled { return best }
            for j in known.indices {
                let index = i * columns + j
                // The fitted clock may drift by 10%, but marker-relative
                // position still bounds the search and rejects distant motifs.
                let allowedOffset = maximumMarkerOffset + maximumSearchClockDrift * max(query[i].time, known[j].time)
                guard abs(known[j].time - query[i].time) <= allowedOffset else { continue }
                let distance = query[i].hash.distance(to: known[j].hash)
                distances[index] = distance
                guard distance <= looseDistance else { continue }
                let reward = min(query[i].quality, known[j].quality) * (1 - distance / looseDistance)
                scores[index] = reward
                if i > 0, j > 0 {
                    var k = i - 1
                    while query[i].time - query[k].time <= maximumGap {
                        var l = j - 1
                        while known[j].time - known[l].time <= maximumGap {
                            let previous = k * columns + l
                            let queryDelta = query[i].time - query[k].time
                            let knownDelta = known[j].time - known[l].time
                            let tolerance = clockResidualTolerance + query[i].uncertainty + known[j].uncertainty
                            if queryDelta > 0, knownDelta > 0,
                               abs(queryDelta - knownDelta) <= tolerance,
                               scores[previous].isFinite {
                                let skipped = (i - k - 1) + (j - l - 1)
                                let score = scores[previous] + reward - skippedFramePenalty * Double(skipped)
                                if score > scores[index] {
                                    scores[index] = score
                                    predecessors[index] = previous
                                }
                            }
                            if l == 0 { break }
                            l -= 1
                        }
                        if k == 0 { break }
                        k -= 1
                    }
                }
                // Evaluate paths ending throughout the matrix, rather than
                // rejecting every other path when the highest score is invalid.
                var path: [(Int, Int)] = []
                var cursor = index
                while cursor >= 0 {
                    path.append((cursor / columns, cursor % columns))
                    cursor = predecessors[cursor]
                }
                guard path.count >= requirement.pairs else { continue }
                path.reverse()
                let result = assess(path, query: query, known: known, distances: distances, at: time, requirement: requirement)
                if isBetter(result, than: best) { best = result }
            }
        }
        return best
    }

    private static func isBetter(_ candidate: IntroFingerprintComparison, than best: IntroFingerprintComparison) -> Bool {
        if candidate.isRepeat != best.isRepeat { return candidate.isRepeat }
        // Confirm against the freshest accepted path, rather than the first
        // acceptable prefix encountered while filling the matrix.
        if candidate.isRepeat, candidate.latestStrongTime != best.latestStrongTime {
            return (candidate.latestStrongTime ?? -.infinity) > (best.latestStrongTime ?? -.infinity)
        }
        if candidate.strongPairs != best.strongPairs { return candidate.strongPairs > best.strongPairs }
        if candidate.coverage != best.coverage { return candidate.coverage > best.coverage }
        return candidate.meanDistance < best.meanDistance
    }

    private static func assess(
        _ path: [(Int, Int)],
        query: [IntroFingerprintPoint], known: [IntroFingerprintPoint],
        distances: [Double], at time: TimeInterval, requirement: Requirements
    ) -> IntroFingerprintComparison {
        let strong = path.filter { distances[$0.0 * known.count + $0.1] <= requirement.strongDistance }
        let weight = query.reduce(0) { $0 + $1.quality }
        // Coverage measures informative query frames used by the alignment,
        // including weak bridges. Strong-pair count, strong span and the mean
        // distance independently prevent weak matches from supplying confidence.
        let supported = path.reduce(0) { $0 + query[$1.0].quality }
        let mean = path.reduce(0) { $0 + distances[$1.0 * known.count + $1.1] } / Double(path.count)
        let points = strong.map { query[$0.0] }
        let span = (points.last?.time ?? 0) - (points.first?.time ?? 0)
        var result = IntroFingerprintComparison(
            matchedPairs: path.count, strongPairs: strong.count,
            coverage: supported / max(weight, minimumCoverageWeight), span: span,
            diversity: visualDiversity(points), meanDistance: mean, latestStrongTime: points.last?.time, queryWindow: requirement.window
        )
        // Fit all correspondences. Do not discard outliers to manufacture
        // a clean-looking clock from an otherwise incoherent match.
        let xMean = path.reduce(0) { $0 + query[$1.0].time } / Double(path.count)
        let yMean = path.reduce(0) { $0 + known[$1.1].time } / Double(path.count)
        let variance = path.reduce(0) { $0 + pow(query[$1.0].time - xMean, 2) }
        guard variance > 0 else { return result }
        result.rate = path.reduce(0) {
            $0 + (query[$1.0].time - xMean) * (known[$1.1].time - yMean)
        } / variance
        result.offset = yMean - result.rate * xMean
        var clockIsCoherent = allowedClockRates.contains(result.rate) && abs(result.offset) <= maximumMarkerOffset
        for (i, j) in path {
            let residual = abs(known[j].time - (result.rate * query[i].time + result.offset))
            result.maximumResidual = max(result.maximumResidual, residual)
            if residual > clockResidualTolerance + query[i].uncertainty + known[j].uncertainty { clockIsCoherent = false }
        }
        result.isRepeat = strong.count >= requirement.pairs && span >= requirement.span - IntroFingerprintPoint.timestampTolerance
            && result.coverage >= requirement.coverage && result.diversity >= requirement.diversity && mean <= requirement.meanDistance
            && time - (points.last?.time ?? -.infinity) <= IntroFingerprintPoint.maximumAge
            && clockIsCoherent
        return result
    }
}

/// Only immutable, Sendable descriptors cross this boundary. Matrix construction
/// never occupies the player's main actor; cancellation is checked between rows.
actor IntroFingerprintMatchingWorker {
    static let shared = IntroFingerprintMatchingWorker()

    func recognize(_ candidate: IntroOpeningFingerprint, among references: [IntroOpeningFingerprint], at time: TimeInterval) -> IntroFingerprintComparison {
        IntroOpeningFingerprintMatcher.recognize(candidate, among: references, at: time)
    }
}
