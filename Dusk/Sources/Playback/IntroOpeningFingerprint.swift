import Foundation

/// Two complementary 64-bit gradients of the same normalized picture.
struct IntroFrameHash: Codable, Equatable, Sendable {
    static let bitCount = UInt64.bitWidth * 2

    let horizontal: UInt64
    let vertical: UInt64

    func distance(to other: Self) -> Double {
        Double((horizontal ^ other.horizontal).nonzeroBitCount
            + (vertical ^ other.vertical).nonzeroBitCount) / Double(Self.bitCount)
    }
}

struct IntroFrameSignature: Equatable, Sendable {
    let hash: IntroFrameHash
    let quality: Double
}

struct IntroFrameSample: Equatable, Sendable {
    private static let maximumSnapshotDuration: TimeInterval = 0.5
    private static let snapshotClockTickDuration: TimeInterval = 0.25

    let mediaTime: TimeInterval
    let signature: IntroFrameSignature
    /// Radius of the estimated frame timestamp, in media seconds.
    let timingUncertainty: TimeInterval

    init(mediaTime: TimeInterval, signature: IntroFrameSignature, timingUncertainty: TimeInterval = 0) {
        self.mediaTime = mediaTime
        self.signature = signature
        self.timingUncertainty = timingUncertainty
    }

    /// VLC exposes its media clock in approximately 250 ms ticks. Keep the
    /// capture-time estimate explicit so quantization is covered by evidence.
    static func snapshot(requestTime: TimeInterval, completionTime: TimeInterval, signature: IntroFrameSignature) -> IntroFrameSample? {
        let interval = completionTime - requestTime
        guard requestTime.isFinite, completionTime.isFinite,
              (0...maximumSnapshotDuration).contains(interval) else { return nil }
        return IntroFrameSample(mediaTime: requestTime + interval / 2, signature: signature,
                                timingUncertainty: interval / 2 + snapshotClockTickDuration)
    }
}

struct IntroFingerprintPoint: Codable, Equatable, Sendable {
    static let timestampTolerance: TimeInterval = 0.001
    static let maximumAge: TimeInterval = 1
    private static let maximumTimingUncertainty: TimeInterval = 0.5

    /// Relative to the Plex marker, never a rounded sample index.
    let time: TimeInterval
    let hash: IntroFrameHash
    let quality: Double
    let uncertainty: TimeInterval

    init(time: TimeInterval, hash: IntroFrameHash, quality: Double = 1, uncertainty: TimeInterval = 0) {
        self.time = time
        self.hash = hash
        self.quality = quality
        self.uncertainty = uncertainty
    }

    var isValid: Bool {
        time.isFinite && time >= 0 && quality.isFinite && quality > 0 && quality <= 1
            && uncertainty.isFinite && (0...Self.maximumTimingUncertainty).contains(uncertainty)
    }
}

struct IntroOpeningFingerprint: Codable, Equatable, Sendable {
    static let currentAlgorithmVersion = 3
    static let maximumPoints = 256
    private static let minimumReferencePoints = 8
    private static let minimumReferenceSpan: TimeInterval = 5
    private static let minimumReferenceVisualGroups = 3

    let algorithmVersion: Int
    let observationID: UUID
    let playbackSessionID: UUID
    let episodeRatingKey: String
    let mediaPartID: Int?
    let markerID: Int
    let points: [IntroFingerprintPoint]

    init(
        algorithmVersion: Int = currentAlgorithmVersion,
        observationID: UUID = UUID(),
        playbackSessionID: UUID = UUID(),
        episodeRatingKey: String = "",
        mediaPartID: Int? = nil,
        markerID: Int = 0,
        points: [IntroFingerprintPoint]
    ) {
        self.algorithmVersion = algorithmVersion
        self.observationID = observationID
        self.playbackSessionID = playbackSessionID
        self.episodeRatingKey = episodeRatingKey
        self.mediaPartID = mediaPartID
        self.markerID = markerID
        self.points = points.sorted { $0.time < $1.time }
    }

    var isEligibleReference: Bool {
        guard algorithmVersion == Self.currentAlgorithmVersion,
              (Self.minimumReferencePoints...Self.maximumPoints).contains(points.count),
              points.allSatisfy(\.isValid),
              let first = points.first, let last = points.last,
              last.time - first.time >= Self.minimumReferenceSpan else { return false }
        return IntroOpeningFingerprintMatcher.independentPoints(points).count >= Self.minimumReferencePoints
            && IntroOpeningFingerprintMatcher.visualDiversity(points) >= Self.minimumReferenceVisualGroups
    }
}

struct IntroFingerprintSeasonKey: Codable, Hashable, Sendable {
    let viewerProfileID: String
    let serverID: String
    let seasonRatingKey: String
}

struct IntroFingerprintComparison: Equatable, Sendable {
    var isRepeat = false
    var matchedPairs = 0
    var strongPairs = 0
    var coverage = 0.0
    var span = 0.0
    var diversity = 0
    var meanDistance = 1.0
    var rate = 1.0
    var offset = 0.0
    var maximumResidual = 0.0
    var latestStrongTime: TimeInterval?
    var queryWindow = 0.0

    var summary: String {
        String(format: "repeat=%@ pairs=%d strong=%d coverage=%.2f span=%.2f diversity=%d mean=%.3f rate=%.3f offset=%.3f residual=%.3f latestStrong=%.3f window=%.2f",
               String(isRepeat), matchedPairs, strongPairs, coverage, span, diversity,
               meanDistance, rate, offset, maximumResidual, latestStrongTime ?? -1, queryWindow)
    }
}
