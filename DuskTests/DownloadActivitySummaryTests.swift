import Foundation
import Testing
@testable import Dusk

@Suite("Background downloads: Live Activity summary")
struct DownloadActivitySummaryTests {
    private func episode(
        _ number: Int,
        status: DownloadStatus = .queued,
        progress: Double = 0,
        bytes: Int64? = 1_000,
        downloaded: Int64 = 0,
        awaiting: Bool = false,
        waitReason: String? = nil
    ) -> DownloadActivityItem {
        DownloadActivityItem(
            globalKey: "e\(number)",
            title: "Episode \(number)",
            showTitle: "Severance",
            episodeLabel: "S2E\(number)",
            isConverted: false,
            serverName: "Wohnzimmer",
            status: status,
            progress: progress,
            preparationProgress: nil,
            downloadedBytes: downloaded,
            totalBytes: bytes,
            isAwaitingTransfer: awaiting,
            waitReason: waitReason
        )
    }

    private func movie(
        _ title: String,
        status: DownloadStatus = .downloading,
        progress: Double = 0,
        converted: Bool = false,
        preparation: Double? = nil,
        bytes: Int64? = 4_000_000_000,
        downloaded: Int64 = 0
    ) -> DownloadActivityItem {
        DownloadActivityItem(
            globalKey: title,
            title: title,
            showTitle: nil,
            episodeLabel: nil,
            isConverted: converted,
            serverName: "Wohnzimmer",
            status: status,
            progress: progress,
            preparationProgress: preparation,
            downloadedBytes: downloaded,
            totalBytes: bytes,
            isAwaitingTransfer: false,
            waitReason: nil
        )
    }

    @Test func severalEpisodesShowTheCountAndTheMovingOne() {
        let summary = DownloadActivitySummary.make(items: [
            episode(1, status: .completed, progress: 1),
            episode(2, status: .downloading, progress: 0.5, downloaded: 500),
            episode(3, status: .downloading, awaiting: true),
            episode(4),
        ])
        #expect(summary.title == "Downloading 3 episodes")
        #expect(summary.subtitle == "Severance · S2E2")
        #expect(summary.state == .active)
        #expect(summary.fraction == 0.375)
    }

    @Test func oneEpisodeLeadsWithTheShow() {
        let summary = DownloadActivitySummary.make(items: [episode(3, status: .downloading, progress: 0.2, downloaded: 200)])
        #expect(summary.title == "Downloading Severance")
        #expect(summary.subtitle == "S2E3 · Episode 3")
    }

    @Test func oneMovieShowsItsSize() {
        let summary = DownloadActivitySummary.make(items: [
            movie("Dune: Part Two", progress: 0.25, downloaded: 1_000_000_000),
        ])
        #expect(summary.title == "Downloading Dune: Part Two")
        #expect(summary.subtitle == "1 GB of 4 GB")
    }

    @Test func conversionShowsTheServerAndHalfTheBar() {
        let preparing = movie("Dune: Part Two", status: .preparing, converted: true, preparation: 0.5, bytes: nil)
        let summary = DownloadActivitySummary.make(items: [preparing])
        #expect(summary.subtitle == "Preparing on Wohnzimmer")
        #expect(summary.fraction == 0.25)
        #expect(summary.state == .active)

        let transferring = movie("Dune: Part Two", progress: 0.5, converted: true, preparation: 1)
        #expect(transferring.fraction == 0.75)
    }

    @Test func mixedQueueCountsTitles() {
        let summary = DownloadActivitySummary.make(items: [episode(1), movie("Dune")])
        #expect(summary.title == "Downloading 2 titles")
        #expect(DownloadActivitySummary.countLabel([movie("A"), movie("B")]) == "2 movies")
    }

    @Test func everythingBlockedIsWaiting() {
        let summary = DownloadActivitySummary.make(items: [
            episode(1, status: .downloading, waitReason: "Waiting for Wi-Fi"),
            episode(2, waitReason: "Waiting for Wi-Fi"),
        ])
        #expect(summary.state == .waiting)
        #expect(summary.subtitle == "Waiting for Wi-Fi")
    }

    @Test func oneMovingItemKeepsTheActivityActive() {
        let summary = DownloadActivitySummary.make(items: [
            episode(1, status: .downloading, progress: 0.1, downloaded: 100),
            episode(2, waitReason: "Waiting for Other Server"),
        ])
        #expect(summary.state == .active)
    }

    @Test func doneBatchSaysWhatLanded() {
        let summary = DownloadActivitySummary.make(items: [
            episode(1, status: .completed), episode(2, status: .completed),
        ])
        #expect(summary.title == "Downloaded 2 episodes")
        #expect(summary.subtitle == "Severance")
        #expect(summary.state == .finished(failedCount: 0))
        #expect(summary.fraction == 1)
    }

    @Test func failuresEndTheBatchAsFailed() {
        let summary = DownloadActivitySummary.make(items: [
            episode(1, status: .completed), episode(2, status: .failed), episode(3, status: .failed),
        ])
        #expect(summary.title == "2 downloads failed")
        #expect(summary.subtitle == "Downloaded 1 episode")
        #expect(summary.state == .finished(failedCount: 2))
    }

    @Test func emptyBatch() {
        #expect(DownloadActivitySummary.make(items: []).state == .empty)
    }

    /// Items without a known size weigh like the average known one, so a
    /// tiny unknown item cannot jump the bar.
    @Test func unknownSizesWeighTheAverage() {
        let items = [
            episode(1, status: .completed, bytes: 3_000),
            episode(2, status: .queued, bytes: nil),
        ]
        #expect(DownloadActivitySummary.weightedFraction(items) == 0.5)
    }
}
