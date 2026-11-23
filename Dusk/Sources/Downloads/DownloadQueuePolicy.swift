import Foundation

/// Pure queue decisions for `DownloadManager`, kept separate for tests.
enum DownloadQueuePolicy {
    /// Original downloads resolved (metadata + request) at the same time.
    /// Each one is a few small Plex requests before it reaches URLSession.
    static let maximumOriginalPreparations = 4
    /// Server conversions running at once (unchanged since conversion landed).
    static let maximumConversions = 2
    /// Transfers handed to the background session ahead of time. The session
    /// itself runs only `maximumActiveDownloads` of them; the rest wait inside
    /// it, which is what lets a long queue finish while Dusk is suspended.
    static let maximumHandedOffTransfers = 50
    /// How long a background wake may keep iOS waiting for Dusk to hand off
    /// the next download (iOS allows roughly 30 s).
    static let backgroundWakeSettleLimit: Duration = .seconds(20)

    struct Counts: Equatable {
        var originalPreparing = 0
        var convertedPreparing = 0
        var handedOff = 0

        init(originalPreparing: Int = 0, convertedPreparing: Int = 0, handedOff: Int = 0) {
            self.originalPreparing = originalPreparing
            self.convertedPreparing = convertedPreparing
            self.handedOff = handedOff
        }

        init(records: [DownloadedMediaRecord]) {
            for record in records {
                switch record.status {
                case .preparing where record.downloadQuality == .original:
                    originalPreparing += 1
                case .preparing:
                    convertedPreparing += 1
                case .downloading:
                    handedOff += 1
                default:
                    break
                }
            }
        }
    }

    /// Whether the queue may start preparing one more queued record.
    static func canStart(isOriginal: Bool, counts: Counts) -> Bool {
        if isOriginal {
            return counts.originalPreparing < maximumOriginalPreparations
                && counts.handedOff + counts.originalPreparing < maximumHandedOffTransfers
        }
        return counts.convertedPreparing < maximumConversions
    }

    /// URLSession task priority for the record at `position` in the queue
    /// (0 = oldest): 1.0 for the first, then down in steps of 0.02, never
    /// below 0.1. Only a hint, but the session starts higher ones first.
    static func transferPriority(position: Int) -> Float {
        max(0.1, 1.0 - Float(max(position, 0)) * 0.02)
    }

    /// Free-space check for one more transfer. Transfers already handed off
    /// have not written their bytes yet, so their remainder counts as used.
    static func hasRoom(
        availableBytes: Int64,
        expectedBytes: Int64,
        reserveBytes: Int64,
        otherPendingBytes: Int64
    ) -> Bool {
        availableBytes - max(0, otherPendingBytes) - max(0, expectedBytes) >= reserveBytes
    }

    /// A handed-off transfer that failed before any bytes arrived (its staged
    /// URL went stale when the network changed, or old resume data could not
    /// be used) is requeued once with a fresh request instead of failing.
    static func shouldRequeueAfterFailure(
        receivedBytes: Bool,
        alreadyRequeued: Bool,
        error: Error
    ) -> Bool {
        guard !receivedBytes, !alreadyRequeued else { return false }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return false }
        return true
    }

    /// A transfer that is in URLSession but has not received a byte yet. The
    /// queue shows it as queued: the session starts it when a slot frees up.
    static func isAwaitingTransfer(status: DownloadStatus, downloadedBytes: Int64, isMoving: Bool) -> Bool {
        status == .downloading && downloadedBytes == 0 && !isMoving
    }

    /// Wi-Fi Only on an expensive or constrained network: URLSession holds the
    /// transfers (every request disallows that network) until Wi-Fi is back.
    static func isWaitingForWiFi(status: DownloadStatus, wifiOnly: Bool, isNetworkConstrained: Bool) -> Bool {
        wifiOnly && isNetworkConstrained && (status == .queued || status == .downloading)
    }
}
