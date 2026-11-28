import Foundation

/// "Keep Next N Unwatched" for one show: Dusk keeps the next `count`
/// unwatched episodes downloaded, removes the ones it downloaded once they are
/// watched, and refills the window. Profile- and server-scoped like records.
struct SmartDownloadRule: Codable, Sendable, Hashable, Identifiable {
    static let countOptions = [3, 5, 10]

    var accountProfileID: String
    var serverID: String
    let showRatingKey: String
    var count: Int
    var quality: DownloadQuality
    var showTitle: String?
    var thumbPath: String?
    var artPath: String?
    /// Unwatched episodes left after the last refill (nil: never refilled).
    /// Zero means the show is fully watched; the rule stays so new episodes
    /// added to Plex later download on their own.
    var remainingUnwatchedCount: Int?
    var lastRefillAt: Date?
    var createdAt: Date

    var id: String { globalKey }

    var showID: MediaItemID {
        MediaItemID(serverID: serverID, itemID: showRatingKey)
    }

    var globalKey: String {
        DownloadedMediaRecord.globalKey(
            accountProfileID: accountProfileID,
            serverID: serverID,
            itemID: showRatingKey
        )
    }

    /// The compact state shown in the Downloads grid and the show's menu.
    var shortLabel: String { "Next \(count)" }
    var menuLabel: String { "Keep Next \(count) Unwatched" }
}

/// What one refill does to a show. Pure so the rules can be tested without a
/// server: `SmartDownloadPlanner.plan`.
struct SmartDownloadPlan: Equatable, Sendable {
    /// Episodes to queue, in viewing order.
    var ratingKeysToQueue: [String]
    /// Smart-owned downloads that left the window (watched, beyond N, or gone
    /// from the server).
    var globalKeysToRemove: [String]
    /// Unwatched episodes from the next one on (may exceed the window).
    var remainingUnwatchedCount: Int
}

enum SmartDownloadPlanner {
    struct Episode: Equatable, Sendable {
        let itemID: String
        let seasonIndex: Int?
        let index: Int?
        let isWatched: Bool
    }

    struct Download: Equatable, Sendable {
        let globalKey: String
        let itemID: String
        /// Queued by the rule. Manual downloads are never removed by it.
        let isSmart: Bool
    }

    /// The next `count` unwatched episodes: specials (season 0) are left out,
    /// and "next" starts after the furthest watched episode, like Continue
    /// Watching, so an old skipped episode does not hold the window forever.
    static func window(episodes: [Episode], count: Int) -> (keys: [String], remaining: Int) {
        let ordered = episodes
            .filter { ($0.seasonIndex ?? 1) != 0 }
            .enumerated()
            .sorted { lhs, rhs in
                let left = (lhs.element.seasonIndex ?? 0, lhs.element.index ?? 0)
                let right = (rhs.element.seasonIndex ?? 0, rhs.element.index ?? 0)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        let start = (ordered.lastIndex { $0.isWatched } ?? -1) + 1
        let upcoming = ordered[start...].filter { !$0.isWatched }
        return (upcoming.prefix(max(count, 0)).map(\.itemID), upcoming.count)
    }

    static func plan(episodes: [Episode], downloads: [Download], count: Int) -> SmartDownloadPlan {
        let (keys, remaining) = window(episodes: episodes, count: count)
        let windowKeys = Set(keys)
        let downloadedKeys = Set(downloads.map(\.itemID))
        return SmartDownloadPlan(
            ratingKeysToQueue: keys.filter { !downloadedKeys.contains($0) },
            globalKeysToRemove: downloads
                .filter { $0.isSmart && !windowKeys.contains($0.itemID) }
                .map(\.globalKey),
            remainingUnwatchedCount: remaining
        )
    }
}
