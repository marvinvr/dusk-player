import Foundation
import Testing
@testable import Dusk

@Suite("Background downloads: queue hand-off policy")
struct DownloadQueuePolicyTests {
    private func record(
        _ key: String,
        status: DownloadStatus,
        quality: DownloadQuality = .original,
        downloadedBytes: Int64 = 0
    ) -> DownloadedMediaRecord {
        DownloadedMediaRecord(
            accountProfileID: "profile",
            serverID: "server",
            serverName: "Server",
            itemID: key,
            type: .episode,
            title: key,
            subtitle: nil,
            parentID: nil,
            parentTitle: nil,
            grandparentID: nil,
            grandparentTitle: nil,
            thumbPath: nil,
            artPath: nil,
            mediaID: nil,
            partID: nil,
            downloadQuality: quality,
            relativeVideoPath: nil,
            resumeDataPath: nil,
            downloadTaskIdentifier: nil,
            status: status,
            progress: 0,
            downloadedBytes: downloadedBytes,
            totalBytes: nil,
            errorMessage: nil,
            addedAt: .now,
            updatedAt: .now
        )
    }

    @Test func countsSplitOriginalAndConvertedPreparation() {
        let counts = DownloadQueuePolicy.Counts(records: [
            record("a", status: .preparing),
            record("b", status: .preparing, quality: .p720),
            record("c", status: .downloading),
            record("d", status: .downloading),
            record("e", status: .queued),
            record("f", status: .completed),
            record("g", status: .paused),
        ])
        #expect(counts == .init(originalPreparing: 1, convertedPreparing: 1, handedOff: 2))
    }

    /// The old queue waited for a free Simultaneous Downloads slot; now any
    /// number of transfers already running does not hold the next one back.
    @Test func originalsAreHandedOffWhileOthersTransfer() {
        let counts = DownloadQueuePolicy.Counts(originalPreparing: 0, convertedPreparing: 0, handedOff: 3)
        #expect(DownloadQueuePolicy.canStart(isOriginal: true, counts: counts))
    }

    @Test func originalPreparationIsBoundedSoPlexIsNotFlooded() {
        let busy = DownloadQueuePolicy.Counts(originalPreparing: DownloadQueuePolicy.maximumOriginalPreparations)
        #expect(!DownloadQueuePolicy.canStart(isOriginal: true, counts: busy))
        // Conversions have their own budget.
        #expect(DownloadQueuePolicy.canStart(isOriginal: false, counts: busy))
    }

    @Test func handOffStopsAtTheCap() {
        let full = DownloadQueuePolicy.Counts(
            originalPreparing: 1,
            handedOff: DownloadQueuePolicy.maximumHandedOffTransfers - 1
        )
        #expect(!DownloadQueuePolicy.canStart(isOriginal: true, counts: full))
    }

    @Test func conversionsStayLimitedToTwo() {
        #expect(DownloadQueuePolicy.canStart(isOriginal: false, counts: .init(convertedPreparing: 1)))
        #expect(!DownloadQueuePolicy.canStart(isOriginal: false, counts: .init(convertedPreparing: 2)))
        // Handed-off transfers never block a conversion from starting.
        #expect(DownloadQueuePolicy.canStart(isOriginal: false, counts: .init(handedOff: 49)))
    }

    @Test func storageCountsWhatHandedOffTransfersStillNeed() {
        let gb: Int64 = 1_000_000_000
        // 10 GB free, 1 GB reserve, 4 GB file: fine on its own...
        #expect(DownloadQueuePolicy.hasRoom(availableBytes: 10 * gb, expectedBytes: 4 * gb,
                                            reserveBytes: gb, otherPendingBytes: 0))
        // ...but not with 6 GB of other transfers still to land.
        #expect(!DownloadQueuePolicy.hasRoom(availableBytes: 10 * gb, expectedBytes: 4 * gb,
                                             reserveBytes: gb, otherPendingBytes: 6 * gb))
        #expect(DownloadQueuePolicy.hasRoom(availableBytes: 10 * gb, expectedBytes: 4 * gb,
                                            reserveBytes: gb, otherPendingBytes: 5 * gb))
    }

    @Test func earlyFailureIsRequeuedOnce() {
        let stale = URLError(.cannotConnectToHost)
        #expect(DownloadQueuePolicy.shouldRequeueAfterFailure(receivedBytes: false, alreadyRequeued: false, error: stale))
        #expect(!DownloadQueuePolicy.shouldRequeueAfterFailure(receivedBytes: false, alreadyRequeued: true, error: stale))
    }

    @Test func failureAfterBytesStillFails() {
        let lost = URLError(.networkConnectionLost)
        #expect(!DownloadQueuePolicy.shouldRequeueAfterFailure(receivedBytes: true, alreadyRequeued: false, error: lost))
    }

    @Test func cancellationIsNeverRequeued() {
        let cancelled = URLError(.cancelled)
        #expect(!DownloadQueuePolicy.shouldRequeueAfterFailure(receivedBytes: false, alreadyRequeued: false, error: cancelled))
    }

    @Test func handedOffWithoutBytesReadsAsQueued() {
        #expect(DownloadQueuePolicy.isAwaitingTransfer(status: .downloading, downloadedBytes: 0, isMoving: false))
        #expect(!DownloadQueuePolicy.isAwaitingTransfer(status: .downloading, downloadedBytes: 0, isMoving: true))
        // Resumed from pause data: shows its percentage, not "Queued".
        #expect(!DownloadQueuePolicy.isAwaitingTransfer(status: .downloading, downloadedBytes: 1024, isMoving: false))
        #expect(!DownloadQueuePolicy.isAwaitingTransfer(status: .queued, downloadedBytes: 0, isMoving: false))
    }

    @Test func wifiOnlyWaitsInsteadOfPausing() {
        #expect(DownloadQueuePolicy.isWaitingForWiFi(status: .downloading, wifiOnly: true, isNetworkConstrained: true))
        #expect(DownloadQueuePolicy.isWaitingForWiFi(status: .queued, wifiOnly: true, isNetworkConstrained: true))
        #expect(!DownloadQueuePolicy.isWaitingForWiFi(status: .downloading, wifiOnly: false, isNetworkConstrained: true))
        #expect(!DownloadQueuePolicy.isWaitingForWiFi(status: .downloading, wifiOnly: true, isNetworkConstrained: false))
        // Plex keeps preparing a conversion on cellular; only bytes wait.
        #expect(!DownloadQueuePolicy.isWaitingForWiFi(status: .preparing, wifiOnly: true, isNetworkConstrained: true))
        #expect(!DownloadQueuePolicy.isWaitingForWiFi(status: .paused, wifiOnly: true, isNetworkConstrained: true))
    }

    @Test func earlierQueueEntriesGetHigherPriority() {
        #expect(DownloadQueuePolicy.transferPriority(position: 0) == 1.0)
        #expect(DownloadQueuePolicy.transferPriority(position: 1) > DownloadQueuePolicy.transferPriority(position: 2))
        #expect(DownloadQueuePolicy.transferPriority(position: 500) == 0.1)
    }

    @Test func liveTaskIdentifiersAreNegative() {
        #expect(DownloadTransferController.isLiveIdentifier(-1))
        #expect(!DownloadTransferController.isLiveIdentifier(0))
        #expect(!DownloadTransferController.isLiveIdentifier(7))
    }
}
