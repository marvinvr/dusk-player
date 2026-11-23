import Foundation

/// What the downloads Live Activity shows, computed from the queue. Pure, so
/// the wording and the progress maths are tested without BackgroundTasks.
struct DownloadActivityItem: Equatable, Sendable {
    let globalKey: String
    let title: String
    /// The show of an episode.
    let showTitle: String?
    /// "S2E3" for an episode.
    let episodeLabel: String?
    let isConverted: Bool
    let serverName: String?
    let status: DownloadStatus
    let progress: Double
    let preparationProgress: Double?
    let downloadedBytes: Int64
    let totalBytes: Int64?
    /// Handed to URLSession, no byte yet (the session starts it later).
    let isAwaitingTransfer: Bool
    /// Why it cannot move right now ("Waiting for Wi-Fi", "Waiting for <server>").
    let waitReason: String?

    var isEpisode: Bool { episodeLabel != nil }

    var isActive: Bool {
        status == .queued || status == .preparing || status == .downloading
    }

    /// 0...1 for this item. A converted copy is half preparation on Plex and
    /// half transfer, so the bar keeps moving while the server works.
    var fraction: Double {
        let value: Double
        switch status {
        case .completed, .failed:
            // A failed item is done as far as the bar is concerned.
            value = 1
        case .preparing:
            value = isConverted ? 0.5 * (preparationProgress ?? 0) : 0
        case .downloading, .paused:
            value = isConverted ? 0.5 + 0.5 * progress : progress
        case .queued, .cancelled:
            value = isConverted && (preparationProgress ?? 0) >= 1 ? 0.5 : 0
        }
        return min(max(value, 0), 1)
    }
}

struct DownloadActivitySummary: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Something can move now.
        case active
        /// Everything left is blocked (Wi-Fi Only on cellular, server away).
        case waiting
        /// Nothing left; `failedCount` of the batch failed.
        case finished(failedCount: Int)
        /// The batch is empty: the user paused or removed everything.
        case empty
    }

    let title: String
    let subtitle: String
    /// 0...1 over the whole batch.
    let fraction: Double
    let state: State

    /// - Parameters:
    ///   - items: the batch's current items: active ones plus those that
    ///     finished (`.completed`) or failed since the activity started.
    ///     Paused, cancelled and deleted items are left out by the caller.
    static func make(items: [DownloadActivityItem]) -> DownloadActivitySummary {
        guard !items.isEmpty else {
            return DownloadActivitySummary(title: "Downloads", subtitle: "", fraction: 0, state: .empty)
        }
        let active = items.filter(\.isActive)
        let failed = items.filter { $0.status == .failed }
        let completed = items.filter { $0.status == .completed }
        let fraction = weightedFraction(items)

        if active.isEmpty {
            if !failed.isEmpty {
                let title = failed.count == 1 ? "Download failed" : "\(failed.count) downloads failed"
                let subtitle = completed.isEmpty ? displayName(failed[0]) : "Downloaded \(countLabel(completed))"
                return DownloadActivitySummary(title: title, subtitle: subtitle, fraction: fraction,
                                               state: .finished(failedCount: failed.count))
            }
            return DownloadActivitySummary(
                title: "Downloaded \(countLabel(completed))",
                subtitle: completed.count == 1 ? detailLine(completed[0]) : sharedShowTitle(completed) ?? "",
                fraction: 1,
                state: .finished(failedCount: 0)
            )
        }

        let title = active.count == 1
            ? "Downloading \(displayName(active[0]))"
            : "Downloading \(countLabel(active))"
        let isWaiting = active.allSatisfy { $0.waitReason != nil }
        let subtitle = currentLine(active, single: active.count == 1)
        return DownloadActivitySummary(title: title, subtitle: subtitle, fraction: fraction,
                                       state: isWaiting ? .waiting : .active)
    }

    // MARK: - Wording

    /// "Severance" for an episode (the show leads), the title otherwise.
    private static func displayName(_ item: DownloadActivityItem) -> String {
        item.showTitle ?? item.title
    }

    /// "4 episodes", "2 movies", "3 titles".
    static func countLabel(_ items: [DownloadActivityItem]) -> String {
        let count = items.count
        if items.allSatisfy(\.isEpisode) {
            return count == 1 ? "1 episode" : "\(count) episodes"
        }
        if items.allSatisfy({ !$0.isEpisode }) {
            return count == 1 ? displayName(items[0]) : "\(count) movies"
        }
        return "\(count) titles"
    }

    private static func sharedShowTitle(_ items: [DownloadActivityItem]) -> String? {
        let shows = Set(items.compactMap(\.showTitle))
        return shows.count == 1 && items.allSatisfy(\.isEpisode) ? shows.first : nil
    }

    /// "S2E3 · Who Is Alive?" for an episode, the title for a movie.
    private static func detailLine(_ item: DownloadActivityItem) -> String {
        if let label = item.episodeLabel {
            return "\(label) · \(item.title)"
        }
        return item.title
    }

    /// The line for what is happening now: the item receiving bytes, else
    /// one Plex is preparing, else why the queue waits.
    private static func currentLine(_ active: [DownloadActivityItem], single: Bool) -> String {
        if let moving = active.first(where: { $0.status == .downloading && !$0.isAwaitingTransfer && $0.waitReason == nil }) {
            if single {
                return moving.isEpisode ? detailLine(moving) : sizeLine(moving) ?? moving.title
            }
            if let label = moving.episodeLabel {
                return moving.showTitle.map { "\($0) · \(label)" } ?? "\(label) · \(moving.title)"
            }
            return moving.title
        }
        if let preparing = active.first(where: { $0.status == .preparing && $0.isConverted }) {
            return preparing.serverName.map { "Preparing on \($0)" } ?? "Preparing on Plex"
        }
        if let reason = active.first(where: { $0.waitReason != nil })?.waitReason {
            return reason
        }
        return single && active[0].isEpisode ? detailLine(active[0]) : "Starting…"
    }

    private static func sizeLine(_ item: DownloadActivityItem) -> String? {
        guard let total = item.totalBytes, total > 0 else { return nil }
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        return "\(format(item.downloadedBytes)) of \(format(total))"
    }

    // MARK: - Progress

    /// Items weigh by their size; an item without a known size weighs the
    /// average of the known ones (or 1 when none is known).
    static func weightedFraction(_ items: [DownloadActivityItem]) -> Double {
        guard !items.isEmpty else { return 0 }
        let knownSizes = items.compactMap(\.totalBytes).filter { $0 > 0 }
        let fallback = knownSizes.isEmpty ? 1 : Double(knownSizes.reduce(0, +)) / Double(knownSizes.count)
        var weighted = 0.0
        var total = 0.0
        for item in items {
            let weight = item.totalBytes.flatMap { $0 > 0 ? Double($0) : nil } ?? fallback
            weighted += weight * item.fraction
            total += weight
        }
        return total > 0 ? min(max(weighted / total, 0), 1) : 0
    }
}
