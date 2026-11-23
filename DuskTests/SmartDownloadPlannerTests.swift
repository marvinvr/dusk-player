import Foundation
import Testing
@testable import Dusk

@Suite("Smart downloads: Keep Next N Unwatched")
struct SmartDownloadPlannerTests {
    /// Season 1 episodes 1...`count`, the first `watched` of them watched.
    private func season(_ number: Int = 1, count: Int, watched: Int = 0) -> [SmartDownloadPlanner.Episode] {
        (1...count).map { index in
            SmartDownloadPlanner.Episode(
                ratingKey: "s\(number)e\(index)",
                seasonIndex: number,
                index: index,
                isWatched: index <= watched
            )
        }
    }

    private func smart(_ key: String) -> SmartDownloadPlanner.Download {
        .init(globalKey: "p:srv:\(key)", ratingKey: key, isSmart: true)
    }

    private func manual(_ key: String) -> SmartDownloadPlanner.Download {
        .init(globalKey: "p:srv:\(key)", ratingKey: key, isSmart: false)
    }

    @Test func freshShowQueuesTheFirstN() {
        let plan = SmartDownloadPlanner.plan(episodes: season(count: 10), downloads: [], count: 5)
        #expect(plan.ratingKeysToQueue == ["s1e1", "s1e2", "s1e3", "s1e4", "s1e5"])
        #expect(plan.globalKeysToRemove.isEmpty)
        #expect(plan.remainingUnwatchedCount == 10)
    }

    @Test func watchingOneRemovesItAndRefillsTheNextOne() {
        let downloads = ["s1e1", "s1e2", "s1e3"].map(smart)
        let plan = SmartDownloadPlanner.plan(episodes: season(count: 10, watched: 1), downloads: downloads, count: 3)
        #expect(plan.globalKeysToRemove == ["p:srv:s1e1"])
        #expect(plan.ratingKeysToQueue == ["s1e4"])
        #expect(plan.remainingUnwatchedCount == 9)
    }

    @Test func windowCrossesSeasonsInOrderAndSkipsSpecials() {
        let specials = [SmartDownloadPlanner.Episode(ratingKey: "special", seasonIndex: 0, index: 1, isWatched: false)]
        // Seasons arrive out of order, as a server may list them.
        let episodes = season(2, count: 3) + specials + season(1, count: 2, watched: 1)
        let plan = SmartDownloadPlanner.plan(episodes: episodes, downloads: [], count: 3)
        #expect(plan.ratingKeysToQueue == ["s1e2", "s2e1", "s2e2"])
        #expect(plan.remainingUnwatchedCount == 4)
    }

    @Test func nextStartsAfterTheFurthestWatchedEpisode() {
        // Episode 2 was skipped; watching 3 moves the window past it.
        var episodes = season(count: 6)
        episodes[0] = .init(ratingKey: "s1e1", seasonIndex: 1, index: 1, isWatched: true)
        episodes[2] = .init(ratingKey: "s1e3", seasonIndex: 1, index: 3, isWatched: true)
        let plan = SmartDownloadPlanner.plan(episodes: episodes, downloads: [smart("s1e2")], count: 2)
        #expect(plan.ratingKeysToQueue == ["s1e4", "s1e5"])
        #expect(plan.globalKeysToRemove == ["p:srv:s1e2"])
    }

    @Test func manualDownloadsCountTowardTheWindowAndAreNeverRemoved() {
        let downloads = [manual("s1e1"), manual("s1e3"), smart("s1e2")]
        // e1 watched: the manual copy stays even though it left the window.
        let plan = SmartDownloadPlanner.plan(episodes: season(count: 6, watched: 1), downloads: downloads, count: 3)
        #expect(plan.globalKeysToRemove.isEmpty)
        // e2 (smart) and e3 (manual) already cover two of the three slots.
        #expect(plan.ratingKeysToQueue == ["s1e4"])
    }

    @Test func fullyWatchedShowRemovesEverythingSmartAndQueuesNothing() {
        let downloads = [smart("s1e4"), smart("s1e5"), manual("s1e1")]
        let plan = SmartDownloadPlanner.plan(episodes: season(count: 5, watched: 5), downloads: downloads, count: 5)
        #expect(plan.ratingKeysToQueue.isEmpty)
        #expect(Set(plan.globalKeysToRemove) == ["p:srv:s1e4", "p:srv:s1e5"])
        #expect(plan.remainingUnwatchedCount == 0)
    }

    @Test func episodeDeletedOnTheServerLeavesTheWindow() {
        // s1e2 is gone from the server's episode list.
        let episodes = season(count: 5).filter { $0.ratingKey != "s1e2" }
        let plan = SmartDownloadPlanner.plan(episodes: episodes, downloads: [smart("s1e1"), smart("s1e2")], count: 2)
        #expect(plan.globalKeysToRemove == ["p:srv:s1e2"])
        #expect(plan.ratingKeysToQueue == ["s1e3"])
    }

    @Test func loweringNTrimsSmartDownloadsFromTheEnd() {
        let downloads = (1...5).map { smart("s1e\($0)") }
        let plan = SmartDownloadPlanner.plan(episodes: season(count: 10), downloads: downloads, count: 3)
        #expect(Set(plan.globalKeysToRemove) == ["p:srv:s1e4", "p:srv:s1e5"])
        #expect(plan.ratingKeysToQueue.isEmpty)
    }

    @Test func fewerEpisodesLeftThanNQueuesWhatIsLeft() {
        let plan = SmartDownloadPlanner.plan(episodes: season(count: 6, watched: 4), downloads: [], count: 5)
        #expect(plan.ratingKeysToQueue == ["s1e5", "s1e6"])
        #expect(plan.remainingUnwatchedCount == 2)
    }

    @Test func ruleAndFlagSurviveASnapshotRoundTrip() throws {
        let rule = SmartDownloadRule(
            accountProfileID: "p", serverID: "srv", showRatingKey: "42",
            count: 5, quality: .p720, createdAt: Date(timeIntervalSince1970: 0)
        )
        let snapshot = DownloadStoreSnapshot(records: [], smartDownloadRules: [rule])
        let decoded = try JSONDecoder().decode(DownloadStoreSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.smartDownloadRules == [rule])
        #expect(rule.shortLabel == "Next 5")

        // Snapshots written before smart downloads decode without rules.
        let old = try JSONDecoder().decode(DownloadStoreSnapshot.self, from: Data(#"{"records":[]}"#.utf8))
        #expect(old.smartDownloadRules == nil)
    }
}
