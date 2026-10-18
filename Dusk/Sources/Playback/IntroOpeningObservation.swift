import Foundation

/// libvlc cache notifications can report buffering while video time advances.
/// Keep clock evidence separate from that notification flag.
struct IntroPlaybackProgress: Sendable {
    private static let maximumClockUpdateInterval: TimeInterval = 1
    private static let minimumAdvanceAllowance: TimeInterval = 1
    private static let maximumExpectedPlaybackRate = 4.0
    private static let advanceClockSlack: TimeInterval = 0.5
    private static let minimumAdvancingTicks = 2
    private static let maximumProgressAge: TimeInterval = 0.5

    private var previousMediaTime: TimeInterval?
    private var previousWallTime: TimeInterval?
    private var lastAdvanceWallTime: TimeInterval?
    private var advancingTicks = 0

    mutating func record(mediaTime: TimeInterval, at wallTime: TimeInterval) {
        guard mediaTime.isFinite, mediaTime >= 0, wallTime.isFinite else {
            reset()
            return
        }
        if let previousMediaTime, let previousWallTime {
            let delta = mediaTime - previousMediaTime
            let elapsed = wallTime - previousWallTime
            let advanceAllowance = max(Self.minimumAdvanceAllowance, elapsed * Self.maximumExpectedPlaybackRate + Self.advanceClockSlack)
            if (0...Self.maximumClockUpdateInterval).contains(elapsed), delta > 0, delta <= advanceAllowance {
                advancingTicks += 1
                lastAdvanceWallTime = wallTime
            } else if elapsed < 0 || elapsed > Self.maximumClockUpdateInterval || delta < 0 || delta > advanceAllowance {
                advancingTicks = 0
                lastAdvanceWallTime = nil
            }
        }
        previousMediaTime = mediaTime
        previousWallTime = wallTime
    }

    func allowsCapture(isPlaying: Bool, isBuffering: Bool, hasPendingSeek: Bool, at wallTime: TimeInterval) -> Bool {
        guard isPlaying, !hasPendingSeek else { return false }
        guard isBuffering else { return true }
        guard advancingTicks >= Self.minimumAdvancingTicks, let lastAdvanceWallTime else { return false }
        // A real refill freezes the clock. Old progress must not authorize
        // sampling or a delayed seek while that refill continues.
        return (0...Self.maximumProgressAge).contains(wallTime - lastAdvanceWallTime)
    }

    mutating func reset() {
        self = IntroPlaybackProgress()
    }
}

/// A single continuous observation. Reference membership is frozen before any
/// part of this observation is persisted. The coordinator retains this value
/// across engine and view-model rebuilds through IntroOpeningSessionState.
struct IntroOpeningObservation: Sendable {
    enum Phase: String, Sendable {
        case collecting, confirming, playThrough, skipped
    }

    static let recognitionLimit: TimeInterval = 12
    static let courtesyDelay: TimeInterval = 5
    static let denseSamplingDuration: TimeInterval = 14
    static let denseSamplingInterval: TimeInterval = 0.25
    static let learningSamplingInterval: TimeInterval = 0.5
    private static let maximumFrameTimestampLead: TimeInterval = 0.5
    private static let maximumConfirmationAge: TimeInterval = 1
    private static let minimumRemainingIntroDuration: TimeInterval = 0.5
    private static let courtesyCompletionMargin: TimeInterval = 0.25

    let id: UUID
    let playbackSessionID: UUID
    let episodeRatingKey: String
    let mediaPartID: Int?
    let markerID: Int
    let markerStart: TimeInterval
    let markerEnd: TimeInterval
    let enteredAt: TimeInterval
    let references: [IntroOpeningFingerprint]
    private(set) var points: [IntroFingerprintPoint] = []
    private(set) var phase: Phase
    private(set) var lastEvaluationTime: TimeInterval?
    private(set) var lastEvaluatedPointTime: TimeInterval?
    private(set) var lastComparison = IntroFingerprintComparison()
    var persistedPointCount = 0

    init(
        playbackSessionID: UUID, episodeRatingKey: String, mediaPartID: Int?, markerID: Int,
        markerStart: TimeInterval, markerEnd: TimeInterval, enteredAt: TimeInterval,
        references: [IntroOpeningFingerprint], allowRecognition: Bool = true
    ) {
        id = UUID()
        self.playbackSessionID = playbackSessionID
        self.episodeRatingKey = episodeRatingKey
        self.mediaPartID = mediaPartID
        self.markerID = markerID
        self.markerStart = markerStart
        self.markerEnd = markerEnd
        self.enteredAt = enteredAt
        self.references = references.filter {
            $0.playbackSessionID != playbackSessionID && $0.isEligibleReference
        }
        phase = allowRecognition && !self.references.isEmpty ? .collecting : .playThrough
    }

    var fingerprint: IntroOpeningFingerprint {
        IntroOpeningFingerprint(
            observationID: id, playbackSessionID: playbackSessionID,
            episodeRatingKey: episodeRatingKey, mediaPartID: mediaPartID,
            markerID: markerID, points: points
        )
    }

    /// Calibration on moving anime shots needs a denser initial recording.
    /// Learning then returns to 2 Hz so the 256-point cap covers long openings.
    /// Use marker position so a resumed query has the reference's cadence.
    func samplingInterval(at mediaTime: TimeInterval) -> TimeInterval {
        mediaTime - markerStart < Self.denseSamplingDuration ? Self.denseSamplingInterval : Self.learningSamplingInterval
    }

    var canRecognize: Bool { phase == .collecting || phase == .confirming }
    var canRecord: Bool { phase != .skipped && points.count < IntroOpeningFingerprint.maximumPoints }

    mutating func record(_ sample: IntroFrameSample) -> Bool {
        let point = IntroFingerprintPoint(
            time: sample.mediaTime - markerStart, hash: sample.signature.hash,
            quality: sample.signature.quality, uncertainty: sample.timingUncertainty
        )
        guard canRecord, point.isValid,
              sample.mediaTime >= enteredAt - Self.maximumFrameTimestampLead,
              sample.mediaTime < markerEnd,
              points.last.map({ point.time > $0.time + IntroFingerprintPoint.timestampTolerance }) ?? true else { return false }
        points.append(point)
        return true
    }

    mutating func advance(to mediaTime: TimeInterval) {
        guard mediaTime.isFinite, canRecognize else { return }
        if phase == .confirming,
           mediaTime - (lastEvaluationTime ?? -.infinity) > Self.maximumConfirmationAge {
            disarm()
        }
        if phase == .collecting, mediaTime - enteredAt > Self.recognitionLimit {
            allowPlayThrough()
        }
    }

    func comparisonTime(at mediaTime: TimeInterval) -> TimeInterval {
        // Displayed-frame PTS can lead a periodically published player clock.
        // Include that capture in the matrix; the seek still uses the live clock.
        max(mediaTime - markerStart, points.last?.time ?? 0)
    }

    func candidate(at mediaTime: TimeInterval) -> IntroOpeningFingerprint? {
        guard canRecognize, mediaTime.isFinite, mediaTime < markerEnd,
              mediaTime >= enteredAt, points.count >= IntroOpeningFingerprintMatcher.minimumSamples,
              let latestTime = points.last.map({ $0.time + markerStart }),
              mediaTime - latestTime <= IntroFingerprintPoint.maximumAge,
              latestTime - mediaTime <= Self.maximumFrameTimestampLead else { return nil }
        return fingerprint
    }

    /// Returns true only on a confirmed, fresh repeat. The player performs its
    /// own live setting/marker/transport checks immediately before the seek.
    mutating func apply(_ result: IntroFingerprintComparison, at mediaTime: TimeInterval) -> Bool {
        guard canRecognize, candidate(at: mediaTime) != nil,
              let latestPointTime = points.last?.time,
              lastEvaluatedPointTime.map({ latestPointTime > $0 }) ?? true else { return false }
        lastEvaluatedPointTime = latestPointTime
        lastComparison = result
        lastEvaluationTime = mediaTime
        guard result.isRepeat,
              let latestStrongTime = result.latestStrongTime,
              latestPointTime - latestStrongTime <= IntroFingerprintPoint.timestampTolerance else {
            disarm()
            advance(to: mediaTime)
            return false
        }
        if phase == .collecting {
            guard mediaTime - enteredAt <= Self.recognitionLimit,
                  markerEnd - mediaTime >= max(Self.minimumRemainingIntroDuration,
                                              Self.courtesyDelay - (mediaTime - enteredAt) + Self.courtesyCompletionMargin) else {
                allowPlayThrough()
                return false
            }
            phase = .confirming
        }
        // The alignment already confirms several independent frames, including
        // the newest capture. Its confirmation runs inside the courtesy delay.
        guard mediaTime - enteredAt >= Self.courtesyDelay else { return false }
        phase = .skipped
        return true
    }

    func progress(at mediaTime: TimeInterval) -> Double? {
        guard canRecognize,
              phase == .confirming || mediaTime - enteredAt < Self.courtesyDelay else { return nil }
        return min(1, max(0, (mediaTime - enteredAt) / Self.courtesyDelay))
    }

    mutating func allowPlayThrough() {
        phase = .playThrough
    }

    private mutating func disarm() {
        phase = .collecting
    }
}

@MainActor
final class IntroOpeningSessionState {
    let id = UUID()
    /// Shared across player rebuilds; seeking back never restores auto-skip.
    var hasSkippedIntro = false
    /// Frozen for this item so a cache reset cannot resume an old recording.
    var fingerprintCacheGeneration: UUID?
    var observations: [Int: IntroOpeningObservation] = [:]
}
