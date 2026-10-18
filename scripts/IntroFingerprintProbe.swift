import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Darwin

/// Compile this alongside the production sources with probe-intro-fingerprints.sh.
/// No app, simulator, or test runner is involved. Media is optional and stays local.
@main
@MainActor
struct IntroFingerprintProbe {
    private enum Calibration {
        static let capturePhases = [0.0, 0.125, 0.25]
        static let expectedRepeatLatency: ClosedRange<TimeInterval> = 5...5.25
        static let minimumDistinctOpenings = 14
        static let minimumRepeatPairs = 12
        static let minimumDifferentOpeningPairs = 348
        static let maximumReferenceDuration: TimeInterval = 128
        static let queryDuration: TimeInterval = 14
        static let debugReferenceDuration: TimeInterval = 18
    }

    private enum FrameExtraction {
        static let framesPerSecond = 4
        static let sampleInterval = 1 / Double(framesPerSecond)
        static let width = 160
        static let height = 90
        static let maximumFrames = 512
        static let densePrefixDuration: TimeInterval = 14
        static let learningFrameStride = 2
        static let adapterComparisonFrameIndex = 20
        static let colorComponentBitDepth = 8
        static let frameFilenameFormat = "%04d.png"
    }

    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Manifest: Decodable { let clips: [Clip] }
    struct Clip: Decodable {
        let id: String
        let file: String
        let start: Double
        let end: Double
        let opening: String
    }

    struct FingerprintCorpus: Decodable {
        let algorithmVersion: Int
        let clips: [FingerprintClip]
    }
    struct FingerprintClip: Codable {
        let id: String
        let opening: String
        let phase: Double
        let points: [IntroFingerprintPoint]
    }

    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw Failure(description: message) }
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        try playbackProgressChecks()
        try earlyLatencyChecks()
        try coreChecks()
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--fingerprints" {
            guard arguments.count >= 2 else { throw Failure(description: "Missing fingerprint fixture path") }
            try fingerprintChecks(URL(fileURLWithPath: arguments[1]))
            arguments.removeFirst(2)
        }
        if arguments.count == 2 {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            try mediaChecks(manifest, directory: URL(fileURLWithPath: arguments[1], isDirectory: true))
        } else if !arguments.isEmpty {
            throw Failure(description: "Usage: probe-intro-fingerprints.sh [manifest.json media-directory]")
        }
        log("PASS: \(checks) production-core checks")
    }

    static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    static func hash(_ index: Int) -> IntroFrameHash {
        func mix(_ value: UInt64) -> UInt64 {
            var value = value &+ 0x9e3779b97f4a7c15
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            return value ^ (value >> 31)
        }
        return IntroFrameHash(horizontal: mix(UInt64(index)), vertical: mix(UInt64(index + 100)))
    }

    static func playbackProgressChecks() throws {
        var progress = IntroPlaybackProgress()
        progress.record(mediaTime: 10, at: 100)
        try require(!progress.allowsCapture(isPlaying: true, isBuffering: true, hasPendingSeek: false, at: 100),
                    "A startup position alone cannot override buffering")
        progress.record(mediaTime: 10.25, at: 100.25)
        progress.record(mediaTime: 10.5, at: 100.5)
        try require(progress.allowsCapture(isPlaying: true, isBuffering: true, hasPendingSeek: false, at: 100.5),
                    "Advancing VLC playback must permit intro capture despite cache-level buffering notifications")
        try require(!progress.allowsCapture(isPlaying: false, isBuffering: true, hasPendingSeek: false, at: 100.5),
                    "Pause must stop capture even with recent clock progress")
        try require(!progress.allowsCapture(isPlaying: true, isBuffering: true, hasPendingSeek: true, at: 100.5),
                    "A pending seek must stop capture even with recent clock progress")
        progress.record(mediaTime: 10.5, at: 100.75)
        progress.record(mediaTime: 10.5, at: 101.25)
        try require(!progress.allowsCapture(isPlaying: true, isBuffering: true, hasPendingSeek: false, at: 101.25),
                    "A real refill with frozen media time must stop capture")
        progress.record(mediaTime: 60, at: 101.5)
        try require(!progress.allowsCapture(isPlaying: true, isBuffering: true, hasPendingSeek: false, at: 101.5),
                    "A seek jump cannot supply playback-progress evidence")
        progress.reset()
        try require(!progress.allowsCapture(isPlaying: true, isBuffering: true, hasPendingSeek: false, at: 102),
                    "An engine reset must discard progress evidence")
        try require(progress.allowsCapture(isPlaying: true, isBuffering: false, hasPendingSeek: false, at: 102),
                    "Ordinary nonbuffering playback must retain its existing capture behavior")

        let suite = "Dusk.IntroBufferingProbe.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = IntroFingerprintSeasonKey(viewerProfileID: "viewer", serverID: "server", seasonRatingKey: "season")
        let store = IntroFingerprintStore(defaults: defaults)
        var first = observation(references: [], enteredAt: 1)
        var firstClock = IntroPlaybackProgress()
        for point in fixture().points {
            firstClock.record(mediaTime: point.time, at: 100 + point.time)
            if firstClock.allowsCapture(isPlaying: true, isBuffering: true, hasPendingSeek: false, at: 100 + point.time) {
                append(point, to: &first)
            }
        }
        try require(store.insert(first.fingerprint, for: key),
                    "VLC cache-level buffering must not prevent banking the first opening")
        let reloaded = IntroFingerprintStore(defaults: defaults)
        var repeated = observation(references: reloaded.fingerprints(for: key), enteredAt: 1)
        var secondClock = IntroPlaybackProgress()
        var skippedAt: Double?
        for point in fixture().points {
            secondClock.record(mediaTime: point.time, at: 200 + point.time)
            guard secondClock.allowsCapture(isPlaying: true, isBuffering: true, hasPendingSeek: false, at: 200 + point.time) else { continue }
            append(point, to: &repeated)
            repeated.advance(to: point.time)
            if let candidate = repeated.candidate(at: point.time) {
                let result = IntroOpeningFingerprintMatcher.recognize(candidate, among: repeated.references, at: point.time)
                if repeated.apply(result, at: point.time) { skippedAt = point.time; break }
            }
        }
        try require(skippedAt == 6,
                    "A banked opening must skip after the courtesy delay even if VLC's buffering flag remains set")
    }

    static func fixture(count: Int = 24, start: Double = 0) -> IntroOpeningFingerprint {
        IntroOpeningFingerprint(episodeRatingKey: "fixture", points: (0..<count).map {
            IntroFingerprintPoint(time: start + Double($0) * 0.5, hash: hash($0))
        })
    }

    static func earlyLatencyChecks() throws {
        let timedReference = IntroOpeningFingerprint(points: (0..<48).map {
            IntroFingerprintPoint(time: 0.125 + Double($0) * 0.25, hash: hash($0))
        })
        var clockLag = observation(references: [timedReference])
        var clockLagSkip: Double?
        for (i, point) in timedReference.points.prefix(21).enumerated() {
            let engineTime = Double(i) * 0.25
            append(point, to: &clockLag)
            clockLag.advance(to: engineTime)
            if let candidate = clockLag.candidate(at: engineTime) {
                let result = IntroOpeningFingerprintMatcher.recognize(candidate, among: [timedReference], at: clockLag.comparisonTime(at: engineTime))
                if clockLag.apply(result, at: engineTime) { clockLagSkip = engineTime; break }
            }
        }
        try require(clockLagSkip == 5, "Displayed-frame timestamps ahead of the periodic engine clock must still confirm at five seconds")

        var future = observation(references: [timedReference])
        for point in timedReference.points where (10...11).contains(point.time) { append(point, to: &future) }
        try require(future.candidate(at: 5) == nil, "Implausibly future-dated frames must not become skip evidence")
        let dimStructure = (0..<(IntroFrameHasher.side * IntroFrameHasher.side)).map { i in
            let x = i % IntroFrameHasher.side, y = i / IntroFrameHasher.side
            return Double((x / 8 + y / 8) % 2) * 8 + Double(x % 8) / 8
        }
        try require(IntroFrameHasher.hash(luminance: dimStructure) != nil,
                    "Dim structured footage must remain usable during an opening fade")
        let nearUniform = dimStructure.map { $0 / 4 }
        try require(IntroFrameHasher.hash(luminance: nearUniform) == nil,
                    "Nearly uniform dark noise must remain ineligible")
        let reference = IntroOpeningFingerprint(points: (0..<48).map {
            IntroFingerprintPoint(time: Double($0) * 0.25, hash: hash($0))
        })
        var delayedEvaluation = observation(references: [reference])
        for point in reference.points where point.time <= 5 { append(point, to: &delayedEvaluation) }
        let complete = IntroOpeningFingerprintMatcher.recognize(delayedEvaluation.fingerprint, among: [reference], at: 5)
        try require(delayedEvaluation.apply(complete, at: 5),
                    "A fresh complete sequence evaluated at the courtesy deadline must not incur another capture delay")
        var state = observation(references: [reference])
        var skippedAt: Double?
        for point in reference.points where (3.5...5).contains(point.time) {
            append(point, to: &state)
            state.advance(to: point.time)
            if let candidate = state.candidate(at: point.time),
               state.apply(IntroOpeningFingerprintMatcher.recognize(candidate, among: state.references, at: point.time), at: point.time) {
                skippedAt = point.time
            }
        }
        try require(skippedAt == 5, "A clear repeat after a dark prefix must confirm inside the five-second courtesy delay")
    }

    static func coreChecks() throws {
        let reference = fixture()
        let candidate = fixture()
        try require(reference.isEligibleReference, "Varied reference must be eligible")
        try require(IntroOpeningFingerprintMatcher.recognize(candidate, among: [reference], at: 5).isRepeat,
                    "Exact repeat must match after five seconds")
        let shifted = IntroOpeningFingerprint(points: candidate.points.map {
            IntroFingerprintPoint(time: $0.time + 0.35, hash: $0.hash, uncertainty: 0.08)
        })
        try require(IntroOpeningFingerprintMatcher.compare(shifted, reference, at: 5.35).isRepeat,
                    "Fractional marker/capture offset must match")
        let dropped = IntroOpeningFingerprint(points: candidate.points.enumerated().compactMap {
            [3, 7].contains($0.offset) ? nil : $0.element
        })
        try require(IntroOpeningFingerprintMatcher.compare(candidate, dropped, at: 5).isRepeat,
                    "Two missing reference captures must not shift the sequence")
        let edited = IntroOpeningFingerprint(points: candidate.points.map { point in
            let i = Int(point.time * 2)
            let damaged = [3, 7].contains(i) ? IntroFrameHash(horizontal: ~point.hash.horizontal, vertical: ~point.hash.vertical)
                : (i == 5 ? IntroFrameHash(horizontal: point.hash.horizontal ^ 0x0000_00ff_ffff_ffff, vertical: point.hash.vertical) : point.hash)
            return IntroFingerprintPoint(time: point.time, hash: damaged)
        })
        try require(IntroOpeningFingerprintMatcher.compare(edited, reference, at: 5).isRepeat,
                    "Alignment coverage must include a weak bridge while independent strong evidence and low mean remain mandatory")
        let staticCard = IntroOpeningFingerprint(points: candidate.points.map {
            IntroFingerprintPoint(time: $0.time, hash: hash(1))
        })
        try require(!staticCard.isEligibleReference, "Static card cannot seed a reference")
        try require(!IntroOpeningFingerprintMatcher.compare(staticCard, staticCard, at: 5).isRepeat,
                    "Static card must not be classified as a repeat")
        let reversed = IntroOpeningFingerprint(points: candidate.points.enumerated().map {
            IntroFingerprintPoint(time: $0.element.time, hash: candidate.points[candidate.points.count - 1 - $0.offset].hash)
        })
        try require(!IntroOpeningFingerprintMatcher.compare(reversed, reference, at: 5).isRepeat,
                    "A bag of identical hashes in reverse order must not match")
        let distant = fixture(start: 10)
        try require(!IntroOpeningFingerprintMatcher.compare(candidate, distant, at: 5).isRepeat,
                    "A distant matching motif must fail marker-relative alignment")
        try require(!IntroOpeningFingerprintMatcher.recognize(reference, among: [reference], at: 5).isRepeat,
                    "An observation must never match itself")
        let sibling = IntroOpeningFingerprint(playbackSessionID: reference.playbackSessionID, points: reference.points)
        try require(!IntroOpeningFingerprintMatcher.recognize(sibling, among: [reference], at: 5).isRepeat,
                    "A new segment in the same playback session must not self-match")
        try require(!IntroOpeningFingerprintMatcher.compare(candidate, reference, at: 20).isRepeat,
                    "Old matching evidence is not fresh enough to skip")
        try require(IntroFrameHasher.hash(luminance: [Double](repeating: 255, count: IntroFrameHasher.side * IntroFrameHasher.side)) == nil,
                    "Uniform white must fail quality without artificial letterboxing")
        try require(IntroFrameHasher.hash(luminance: [Double](repeating: 0, count: IntroFrameHasher.side * IntroFrameHasher.side)) == nil,
                    "Uniform black must fail quality")
        let clockSample = IntroFrameSample.snapshot(requestTime: 5, completionTime: 5,
                                                   signature: IntroFrameSignature(hash: hash(1), quality: 1))!
        try require(abs(5.24 - clockSample.mediaTime) <= clockSample.timingUncertainty,
                    "Snapshot uncertainty must cover the engine's 250 ms clock quantization")
        try require(IntroFrameSample.snapshot(requestTime: 5, completionTime: 5.6,
            signature: clockSample.signature) == nil, "Slow snapshots must be excluded when uncertainty exceeds half a second")
        for seed in 1...32 {
            let unrelated = IntroOpeningFingerprint(points: candidate.points.enumerated().map {
                IntroFingerprintPoint(time: $0.element.time, hash: hash(seed * 100 + $0.offset))
            })
            try require(!IntroOpeningFingerprintMatcher.recognize(unrelated, among: [reference], at: 5).isRepeat,
                        "Unrelated sequence must not match (seed \(seed))")
        }
        for rate in [0.92, 1.08] {
            let drifted = IntroOpeningFingerprint(points: reference.points.map {
                IntroFingerprintPoint(time: $0.time * rate, hash: $0.hash)
            })
            try require(IntroOpeningFingerprintMatcher.compare(drifted, reference, at: 5 * rate).isRepeat,
                        "Small playback-rate differences must retain a coherent match")
        }
        try policyChecks(reference)
        try storeChecks(reference)
        log("Synthetic sequence, policy, and persistence checks passed")
    }

    static func observation(references: [IntroOpeningFingerprint], sessionID: UUID = UUID(), enteredAt: Double = 0, episodeRatingKey: String = "query") -> IntroOpeningObservation {
        IntroOpeningObservation(playbackSessionID: sessionID, episodeRatingKey: episodeRatingKey, mediaPartID: 1,
                                markerID: 1, markerStart: 0, markerEnd: 90, enteredAt: enteredAt, references: references)
    }

    static func append(_ point: IntroFingerprintPoint, to observation: inout IntroOpeningObservation) {
        _ = observation.record(IntroFrameSample(mediaTime: point.time,
            signature: IntroFrameSignature(hash: point.hash, quality: point.quality), timingUncertainty: point.uncertainty))
    }

    static func policyChecks(_ reference: IntroOpeningFingerprint) throws {
        var state = observation(references: [reference])
        var skippedAt: Double?
        for point in fixture(count: 15).points {
            append(point, to: &state)
            state.advance(to: point.time)
            if let candidate = state.candidate(at: point.time) {
                let result = IntroOpeningFingerprintMatcher.recognize(candidate, among: state.references, at: point.time)
                if state.apply(result, at: point.time) { skippedAt = point.time; break }
            }
        }
        try require(skippedAt == 5, "Repeat must confirm on fresh evidence within the five-second courtesy delay")
        let full = IntroOpeningFingerprint(points: (0..<320).compactMap { i in
            let time = Double(i) * 0.25
            guard time < 14 || i.isMultiple(of: 2) else { return nil }
            return IntroFingerprintPoint(time: time, hash: hash(i))
        })
        var resumed = observation(references: [full], enteredAt: 30)
        var resumedSkip: Double?
        var resumedTime = 30.0
        while resumedTime <= 37 {
            let point = IntroFingerprintPoint(time: resumedTime, hash: hash(Int((resumedTime * 4).rounded())))
            append(point, to: &resumed)
            resumed.advance(to: point.time)
            if let candidate = resumed.candidate(at: point.time),
               resumed.apply(IntroOpeningFingerprintMatcher.recognize(candidate, among: resumed.references, at: point.time), at: point.time) {
                resumedSkip = point.time; break
            }
            resumedTime += resumed.samplingInterval(at: resumedTime)
        }
        try require(resumedSkip == 35, "A resumed opening must match a later segment of a full recording at its actual capture cadence")
        try require(resumed.samplingInterval(at: 5) == 0.25 && resumed.samplingInterval(at: 35) == 0.5,
                    "Dense recognition sampling must return to bounded 2 Hz learning by marker position")
        var noFreshFrame = observation(references: [reference])
        for point in fixture(count: 10).points { append(point, to: &noFreshFrame) }
        let result = IntroOpeningFingerprintMatcher.recognize(noFreshFrame.fingerprint, among: [reference], at: 4.5)
        try require(!noFreshFrame.apply(result, at: 4.5), "A repeat before the courtesy deadline only arms the countdown")
        try require(!noFreshFrame.apply(result, at: 5), "Elapsed time without another frame cannot confirm a skip")
        noFreshFrame.advance(to: 6)
        try require(noFreshFrame.phase != .confirming, "Stale evidence must disarm confirmation")
        noFreshFrame.allowPlayThrough()
        try require(!noFreshFrame.apply(result, at: 7), "A cancelled observation cannot rearm")
        var ending = IntroOpeningObservation(playbackSessionID: UUID(), episodeRatingKey: "ending", mediaPartID: 1,
            markerID: 2, markerStart: 0, markerEnd: 6.5, enteredAt: 0, references: [reference])
        for point in fixture(count: 10).points { append(point, to: &ending) }
        _ = ending.apply(result, at: 4.5)
        append(fixture(count: 13).points.last!, to: &ending)
        let endResult = IntroOpeningFingerprintMatcher.recognize(ending.fingerprint, among: [reference], at: 6)
        try require(endResult.isRepeat, "Marker-boundary control must contain fresh matching evidence")
        try require(!ending.apply(endResult, at: 6.75), "A delayed confirmation cannot seek after the live marker has ended")
        let dense = IntroOpeningFingerprint(points: (0..<32).map {
            IntroFingerprintPoint(time: Double($0) * 0.25, hash: hash($0))
        })
        var diverging = observation(references: [dense])
        for point in dense.points where point.time <= 4.5 { append(point, to: &diverging) }
        let established = IntroOpeningFingerprintMatcher.recognize(diverging.fingerprint, among: [dense], at: 4.5)
        _ = diverging.apply(established, at: 4.5)
        for i in 19...22 {
            let point = IntroFingerprintPoint(time: Double(i) * 0.25, hash: hash(i + 1_000))
            append(point, to: &diverging)
            let comparison = IntroOpeningFingerprintMatcher.recognize(diverging.fingerprint, among: [dense], at: point.time)
            try require(!diverging.apply(comparison, at: point.time), "A diverging suffix must not confirm from old matching evidence")
        }
        var empty = observation(references: [])
        try require(empty.phase == .playThrough, "Empty gallery plays through immediately")
        for point in fixture().points { append(point, to: &empty) }
        try require(empty.fingerprint.isEligibleReference, "The first played opening must be learnable")
        var missing = observation(references: [reference])
        missing.advance(to: 12.1)
        try require(missing.phase == .playThrough, "Missing captures must terminate recognition after twelve seconds")
        try require(missing.points.isEmpty, "Elapsed playback must not fabricate samples")
        let uncertain = IntroFrameSample(mediaTime: 0, signature: IntroFrameSignature(hash: hash(0), quality: 1), timingUncertainty: 0.6)
        try require(!missing.record(uncertain), "Uncertain capture must not become evidence")
        let first = IntroFrameSample(mediaTime: 1, signature: IntroFrameSignature(hash: hash(0), quality: 1))
        try require(missing.record(first), "A timed-out recognition may still learn playback")
        try require(!missing.record(first), "Duplicate display timestamp must not add evidence")
    }

    static func storeChecks(_ reference: IntroOpeningFingerprint) throws {
        let name = "Dusk.IntroProbe.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let key = IntroFingerprintSeasonKey(viewerProfileID: "viewer", serverID: "server", seasonRatingKey: "season")
        let store = IntroFingerprintStore(defaults: defaults)
        let partial = IntroOpeningFingerprint(observationID: reference.observationID, playbackSessionID: reference.playbackSessionID,
            episodeRatingKey: reference.episodeRatingKey, points: Array(reference.points.prefix(12)))
        try require(store.insert(partial, for: key), "Eligible partial recording must persist")
        try require(store.insert(reference, for: key), "An observation must extend as more is watched")
        try require(store.fingerprints(for: key) == [reference], "Extending an observation must not create a second reference")
        let reloaded = IntroFingerprintStore(defaults: defaults)
        try require(reloaded.fingerprints(for: key).count == 1, "Recording must survive reload")
        try require(reloaded.fingerprints(for: key, excluding: reference.playbackSessionID).isEmpty, "Current playback must be excluded after rebuild")
        for other in [
            IntroFingerprintSeasonKey(viewerProfileID: "other", serverID: "server", seasonRatingKey: "season"),
            IntroFingerprintSeasonKey(viewerProfileID: "viewer", serverID: "other", seasonRatingKey: "season"),
            IntroFingerprintSeasonKey(viewerProfileID: "viewer", serverID: "server", seasonRatingKey: "other")
        ] { try require(reloaded.fingerprints(for: other).isEmpty, "Viewer, server, and season must all isolate references") }
        for _ in 0..<18 { _ = store.insert(fixture(), for: key) }
        try require(store.fingerprints(for: key).count == 16, "Season reference cache must be bounded")
        let archive = String(decoding: defaults.data(forKey: "Dusk.IntroOpeningFingerprints")!, as: UTF8.self)
        let versionTwo = archive.replacingOccurrences(of: #""schemaVersion"\s*:\s*\d+"#,
                                                      with: #""schemaVersion":2"#, options: .regularExpression)
        defaults.set(Data(versionTwo.utf8), forKey: "Dusk.IntroOpeningFingerprints")
        try require(IntroFingerprintStore(defaults: defaults).fingerprints(for: key).isEmpty,
                    "Earlier recordings that discarded dim prefixes must be relearned")
        defaults.set(Data(#"{"schemaVersion":1,"records":[]}"#.utf8), forKey: "Dusk.IntroOpeningFingerprints")
        try require(IntroFingerprintStore(defaults: defaults).fingerprints(for: key).isEmpty, "Version one archive must be relearned")
    }

    static func fingerprintChecks(_ url: URL) throws {
        let corpus = try JSONDecoder().decode(FingerprintCorpus.self, from: Data(contentsOf: url))
        try require(corpus.algorithmVersion == IntroOpeningFingerprint.currentAlgorithmVersion,
                    "Fingerprint fixtures must use the production descriptor version")
        let references = corpus.clips.filter { $0.phase == 0 }.map {
            ($0, IntroOpeningFingerprint(episodeRatingKey: $0.id, points: $0.points))
        }
        try require(references.allSatisfy { $0.1.isEligibleReference }, "Every calibration reference must be eligible")
        try require(Set(corpus.clips.map(\.opening)).count >= Calibration.minimumDistinctOpenings,
                    "Calibration must retain its unrelated-opening controls")
        try openingTransitionChecks(corpus)
        var positive = 0, negative = 0
        var latencies: [Double] = []
        for clip in corpus.clips {
            for (other, reference) in references where other.id != clip.id {
                var state = observation(references: [reference], enteredAt: clip.phase)
                var latency: Double?
                for point in clip.points {
                    append(point, to: &state)
                    state.advance(to: point.time)
                    if let candidate = state.candidate(at: point.time) {
                        let result = IntroOpeningFingerprintMatcher.recognize(candidate, among: state.references, at: point.time)
                        if state.apply(result, at: point.time) { latency = point.time - clip.phase; break }
                    }
                }
                if clip.opening == other.opening {
                    positive += 1
                    try require(latency.map { Calibration.expectedRepeatLatency.contains($0) } == true,
                                "\(clip.id)/\(other.id) phase=\(clip.phase): repeat must skip within the five-second delay plus one capture interval; got \(String(describing: latency))")
                    latencies.append(latency!)
                } else {
                    negative += 1
                    try require(latency == nil, "Different opening \(clip.id)/\(other.id) must play through; \(state.lastComparison.summary)")
                }
            }
        }
        try require(positive >= Calibration.minimumRepeatPairs && negative >= Calibration.minimumDifferentOpeningPairs,
                    "Calibration cases must not disappear")
        let sorted = latencies.sorted()
        log("Saved media fingerprints: \(positive) repeats, \(negative) negative pairs, median=\(sorted[sorted.count / 2])s max=\(sorted.last!)s")
    }

    /// Exercise the actual opening change in viewing order, including learning
    /// the new opening without allowing its own checkpoint to cause a skip.
    static func openingTransitionChecks(_ corpus: FingerprintCorpus) throws {
        guard let previous = corpus.clips.first(where: { $0.id == "e12" && $0.phase == 0 }) else {
            throw Failure(description: "Episode 12 must remain in the opening-transition fixtures")
        }
        for phase in Calibration.capturePhases {
            guard let changed = corpus.clips.first(where: { $0.id == "e13" && $0.phase == phase }),
                  let repeated = corpus.clips.first(where: { $0.id == "e14" && $0.phase == phase }) else {
                throw Failure(description: "Episodes 13 and 14 must retain all three sampling phases")
            }
            let suite = "Dusk.IntroTransitionProbe.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let key = IntroFingerprintSeasonKey(viewerProfileID: "probe", serverID: "local", seasonRatingKey: "apothecary-s01")
            let store = IntroFingerprintStore(defaults: defaults)
            try require(store.insert(IntroOpeningFingerprint(episodeRatingKey: "e12", points: previous.points), for: key),
                        "Episode 12 must seed the previous opening")
            var changedState = observation(references: store.fingerprints(for: key), enteredAt: phase, episodeRatingKey: "e13")
            var changedSkipped = false, checkpointed = false
            for point in changed.points {
                append(point, to: &changedState)
                changedState.advance(to: point.time)
                if let candidate = changedState.candidate(at: point.time) {
                    let result = IntroOpeningFingerprintMatcher.recognize(candidate, among: changedState.references, at: point.time)
                    if changedState.apply(result, at: point.time) { changedSkipped = true; break }
                }
                if !checkpointed, changedState.fingerprint.isEligibleReference {
                    try require(store.insert(changedState.fingerprint, for: key), "New opening must become learnable while playing")
                    let rebuiltStore = IntroFingerprintStore(defaults: defaults)
                    try require(rebuiltStore.fingerprints(for: key, excluding: changedState.playbackSessionID).count == 1,
                                "Episode 13's checkpoint must not become its own reference after a rebuild")
                    checkpointed = true
                }
            }
            try require(!changedSkipped && changedState.phase == .playThrough,
                        "Episode 13 must play through when only episode 12 is remembered, phase=\(phase)")
            try require(checkpointed && changedState.references.count == 1,
                        "Learning episode 13 must preserve the frozen episode 12 reference set")
            try require(store.insert(changedState.fingerprint, for: key), "Episode 13's new opening must persist")
            let reloaded = IntroFingerprintStore(defaults: defaults)
            var repeatState = observation(references: reloaded.fingerprints(for: key), enteredAt: phase, episodeRatingKey: "e14")
            var latency: Double?
            for point in repeated.points {
                append(point, to: &repeatState)
                repeatState.advance(to: point.time)
                if let candidate = repeatState.candidate(at: point.time) {
                    let result = IntroOpeningFingerprintMatcher.recognize(candidate, among: repeatState.references, at: point.time)
                    if repeatState.apply(result, at: point.time) { latency = point.time - phase; break }
                }
            }
            try require(latency.map { (IntroOpeningObservation.courtesyDelay...IntroOpeningObservation.recognitionLimit).contains($0) } == true,
                        "Episode 14 must skip the newly learned episode 13 opening, phase=\(phase), latency=\(String(describing: latency))")
            log("Opening transition phase=\(phase): e12 → e13 plays through; learned e13 → e14 skips after \(latency!)s")
        }
    }

    static func mediaChecks(_ manifest: Manifest, directory: URL) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dusk-intro-media-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var references: [(Clip, IntroOpeningFingerprint)] = []
        for clip in manifest.clips {
            let points = try extract(clip, directory: directory, temporary: temporary, phase: 0,
                                     duration: min(Calibration.maximumReferenceDuration, clip.end - clip.start))
            let reference = IntroOpeningFingerprint(episodeRatingKey: clip.id, points: points)
            try require(reference.isEligibleReference, "\(clip.id): real opening must produce an eligible recording")
            references.append((clip, reference))
            log("\(clip.id): reference points=\(points.count)")
        }
        var latencies: [Double] = []
        var failures: [String] = []
        for (clip, _) in references {
            for phase in Calibration.capturePhases {
                let points = try extract(clip, directory: directory, temporary: temporary, phase: phase,
                                         duration: Calibration.queryDuration)
                for (other, reference) in references where other.id != clip.id {
                    if ProcessInfo.processInfo.environment["INTRO_PROBE_DEBUG"] == "1", clip.opening == other.opening {
                        for p in points {
                            let nearest = reference.points.filter { $0.time < Calibration.debugReferenceDuration }
                                .min { p.hash.distance(to: $0.hash) < p.hash.distance(to: $1.hash) }
                            if let nearest { log("nearest \(clip.id)/\(other.id) \(p.time) -> \(nearest.time) d=\(p.hash.distance(to: nearest.hash))") }
                        }
                    }
                    var state = observation(references: [reference], enteredAt: phase)
                    var latency: Double?
                    for point in points {
                        append(point, to: &state)
                        state.advance(to: point.time)
                        if let candidate = state.candidate(at: point.time) {
                            let result = IntroOpeningFingerprintMatcher.recognize(candidate, among: state.references, at: point.time)
                            if ProcessInfo.processInfo.environment["INTRO_PROBE_DEBUG"] == "1" {
                                log("  \(clip.id)/\(other.id) t=\(point.time): \(result.summary)")
                            }
                            if state.apply(result, at: point.time) { latency = point.time; break }
                        }
                    }
                    let shouldMatch = clip.opening == other.opening
                    log("\(clip.id) vs \(other.id) phase=\(phase): skip=\(latency.map { String(format: "%.2fs", $0) } ?? "none") \(state.lastComparison.summary)")
                    checks += 1
                    if (latency != nil) != shouldMatch {
                        failures.append("\(clip.id) vs \(other.id) phase=\(phase): expected repeat=\(shouldMatch)")
                    }
                    if let latency {
                        let elapsed = latency - phase
                        checks += 1
                        if !Calibration.expectedRepeatLatency.contains(elapsed) {
                            failures.append("\(clip.id)/\(other.id) phase=\(phase): repeat took \(elapsed)s")
                        }
                        latencies.append(elapsed)
                    }
                }
            }
        }
        try require(failures.isEmpty, failures.joined(separator: "\n"))
        if !latencies.isEmpty {
            let sorted = latencies.sorted()
            log("Media repeat latency median=\(sorted[sorted.count / 2])s max=\(sorted.last!)s; all cross-opening pairs rejected")
        }
    }

    static func extract(_ clip: Clip, directory: URL, temporary: URL, phase: Double, duration: Double) throws -> [IntroFingerprintPoint] {
        let output = temporary.appendingPathComponent("\(clip.id)-\(phase)-\(duration)-\(FrameExtraction.framesPerSecond)fps", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", String(clip.start + phase),
                             "-i", directory.appendingPathComponent(clip.file).path, "-t", String(duration),
                             "-vf", "fps=\(FrameExtraction.framesPerSecond),scale=\(FrameExtraction.width):\(FrameExtraction.height):flags=lanczos",
                             "-an", "-sn", "-dn", "-frames:v", String(FrameExtraction.maximumFrames),
                             "-start_number", "0", output.appendingPathComponent(FrameExtraction.frameFilenameFormat).path]
        try process.run()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "ffmpeg extraction failed for \(clip.id)")
        var points: [IntroFingerprintPoint] = []
        var index = 0
        while points.count < IntroOpeningFingerprint.maximumPoints {
            let url = output.appendingPathComponent(String(format: FrameExtraction.frameFilenameFormat, index))
            guard FileManager.default.fileExists(atPath: url.path) else { break }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw Failure(description: "Cannot read extracted frame \(url.path)")
            }
            let time = phase + Double(index) * FrameExtraction.sampleInterval
            // Match production's dense prefix followed by 2 Hz learning.
            if (time - phase < FrameExtraction.densePrefixDuration || index.isMultiple(of: FrameExtraction.learningFrameStride)),
               let signature = IntroFrameHasher.hash(cgImage: image) {
                points.append(IntroFingerprintPoint(time: time, hash: signature.hash, quality: signature.quality))
                if index == FrameExtraction.adapterComparisonFrameIndex { try adapterCheck(image, expected: signature) }
            }
            index += 1
        }
        return points
    }

    static func adapterCheck(_ image: CGImage, expected: IntroFrameSignature) throws {
        var buffer: CVPixelBuffer?
        let code = CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                      [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        guard code == kCVReturnSuccess, let buffer else { throw Failure(description: "Cannot create adapter control buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                bitsPerComponent: FrameExtraction.colorComponentBitDepth,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        let actual = IntroFrameHasher.hash(pixelBuffer: buffer)
        try require(actual?.hash == expected.hash, "CGImage and CVPixelBuffer adapters must produce identical gradients from the same pixels")
    }
}
