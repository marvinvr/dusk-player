import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit

/// The downloads Live Activity: one `BGContinuedProcessingTask` (iOS 26+)
/// for the whole queue, submitted when the user starts, resumes or retries a
/// download. iOS draws the Live Activity (Lock Screen, Dynamic Island) from
/// the task's title, subtitle and progress, and keeps Dusk running after the
/// user leaves it, so the queue keeps handing off and Plex conversions keep
/// being polled.
///
/// The task only buys runtime and UI. Bytes still move in the background
/// URLSession, so a refused or expired task never loses a transfer: it just
/// stops the parts that need Dusk awake (server conversions, live transfers
/// moving over) until iOS wakes Dusk again or the user opens it.
///
/// Automatic work (Smart Downloads refills, auto-resume after a server comes
/// back, relaunch reconciliation) never submits one: Apple may cancel tasks
/// that were not started by the user, and a nightly banner would be noise.
@MainActor
final class DownloadContinuedTaskController {
    static let identifierPrefix = "com.dusk-player.app.downloads.continued"
    /// Without any work in the batch for this long, the task ends (the user
    /// tapped Download but the queueing found nothing to do).
    private static let emptyGrace: TimeInterval = 15
    /// Everything left waiting (Wi-Fi Only on cellular, server away) for this
    /// long ends the task. The background session keeps the transfers.
    private static let waitingGrace: TimeInterval = 20
    private static let tickInterval: Duration = .milliseconds(500)
    /// A request iOS queued but has not started after this long is replaced
    /// by the next user action.
    private static let staleSubmission: TimeInterval = 60
    private static let progressUnits: Int64 = 1000

    private weak var downloadManager: DownloadManager?

    private enum State {
        case idle
        case submitted(identifier: String, at: Date)
        case running(identifier: String)
    }

    private var state: State = .idle
    /// `BGContinuedProcessingTask` (kept untyped for the iOS 18 target).
    private var runningTask: AnyObject?
    private var ticker: Task<Void, Never>?
    /// Items of this run by global key, kept after they finish or fail so the
    /// count and the bar cover the whole batch.
    private var batch: [String: DownloadActivityItem] = [:]
    private var reportedUnits: Int64 = 0
    private var lastTitle = ""
    private var lastSubtitle = ""
    private var startedAt = Date()
    private var waitingSince: Date?

    init(downloadManager: DownloadManager) {
        self.downloadManager = downloadManager
    }

    /// iPhone and iPad on iOS 26+. Not on a Mac running the iPad app, where
    /// BackgroundTasks has no continued processing.
    static var isSupported: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return !ProcessInfo.processInfo.isiOSAppOnMac
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    /// The user started, resumed or retried downloads. Submits the task if
    /// none is pending or running; a running one picks the new items up on
    /// its next tick.
    func userStartedDownloads() {
        guard Self.isSupported, let downloadManager else { return }
        // Submission is only allowed for the app in front.
        guard UIApplication.shared.applicationState != .background else { return }
        let items = downloadManager.activityItems()
        guard items.contains(where: \.isActive) else { return }
        switch state {
        case .idle:
            if #available(iOS 26.0, *) {
                submit(items: items)
            }
        case let .submitted(identifier, at) where Date.now.timeIntervalSince(at) > Self.staleSubmission:
            // iOS never started the queued request; replace it.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            state = .idle
            if #available(iOS 26.0, *) {
                submit(items: items)
            }
        case .submitted, .running:
            mergeIntoBatch(items)
        }
    }

    // MARK: - Submission

    @available(iOS 26.0, *)
    private func submit(items: [DownloadActivityItem]) {
        batch = [:]
        mergeIntoBatch(items)
        let summary = DownloadActivitySummary.make(items: Array(batch.values))
        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.run(task, identifier: identifier)
            }
        }
        guard registered else {
            log("register refused \(identifier)")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: summary.title,
            subtitle: summary.subtitle.isEmpty ? "Starting…" : summary.subtitle
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            state = .submitted(identifier: identifier, at: .now)
            log("submitted \(identifier): \(summary.title)")
        } catch {
            // Downloads carry on in the background session without the
            // activity; nothing else to do.
            state = .idle
            batch = [:]
            log("submit failed: \(error)")
        }
    }

    @available(iOS 26.0, *)
    private func run(_ task: BGContinuedProcessingTask, identifier: String) {
        guard case let .submitted(current, _) = state, current == identifier else {
            // A stale request from an earlier run: nothing to show.
            task.setTaskCompleted(success: true)
            return
        }
        state = .running(identifier: identifier)
        runningTask = task
        startedAt = .now
        waitingSince = nil
        reportedUnits = 0
        lastTitle = task.title
        lastSubtitle = task.subtitle
        task.progress.totalUnitCount = Self.progressUnits
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.expire(identifier: identifier)
            }
        }
        log("running \(identifier)")
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                self.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    // MARK: - Updates

    private func mergeIntoBatch(_ items: [DownloadActivityItem]) {
        for item in items where item.isActive {
            batch[item.globalKey] = item
        }
    }

    /// Refreshes the batch from the queue: active items update, finished and
    /// failed ones stay as they ended, paused/cancelled/deleted ones leave.
    private func refreshBatch() {
        guard let downloadManager else { return }
        let current = Dictionary(
            downloadManager.activityItems(includingFinished: Set(batch.keys)).map { ($0.globalKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for key in Array(batch.keys) {
            guard let item = current[key] else {
                batch.removeValue(forKey: key)
                continue
            }
            switch item.status {
            case .queued, .preparing, .downloading, .completed, .failed:
                batch[key] = item
            case .paused, .cancelled:
                batch.removeValue(forKey: key)
            }
        }
        // Anything else that became active while the activity runs (more
        // episodes of a show, a refill) belongs to the same queue.
        for item in current.values where item.isActive && batch[item.globalKey] == nil {
            batch[item.globalKey] = item
        }
    }

    private func tick() {
        guard #available(iOS 26.0, *), let task = runningTask as? BGContinuedProcessingTask else { return }
        refreshBatch()
        let summary = DownloadActivitySummary.make(items: Array(batch.values))

        switch summary.state {
        case .active:
            waitingSince = nil
            publish(summary, to: task)
        case .waiting:
            publish(summary, to: task)
            let since = waitingSince ?? .now
            waitingSince = since
            if Date.now.timeIntervalSince(since) >= Self.waitingGrace {
                finish(task, success: true, reason: "waiting")
            }
        case let .finished(failedCount):
            publish(summary, to: task)
            finish(task, success: failedCount == 0, reason: "finished")
        case .empty:
            if Date.now.timeIntervalSince(startedAt) >= Self.emptyGrace {
                finish(task, success: true, reason: "empty")
            }
        }
    }

    @available(iOS 26.0, *)
    private func publish(_ summary: DownloadActivitySummary, to task: BGContinuedProcessingTask) {
        if summary.title != lastTitle || summary.subtitle != lastSubtitle {
            lastTitle = summary.title
            lastSubtitle = summary.subtitle
            task.updateTitle(summary.title, subtitle: summary.subtitle)
        }
        // Never move backwards: an item leaving the batch must not shrink
        // the bar the user already saw.
        let units = min(Self.progressUnits, Int64((summary.fraction * Double(Self.progressUnits)).rounded()))
        if units > reportedUnits {
            reportedUnits = units
            task.progress.completedUnitCount = units
        }
    }

    @available(iOS 26.0, *)
    private func finish(_ task: BGContinuedProcessingTask, success: Bool, reason: String) {
        log("finish (\(reason)) success=\(success)")
        endRun()
        task.setTaskCompleted(success: success)
        downloadManager?.continuedTaskDidEnd()
    }

    /// iOS expired the task, or the user stopped it from the Live Activity.
    /// The API does not say which, so this is treated as the user's ✕:
    /// Pause All (resume data kept, nothing deleted).
    private func expire(identifier: String) {
        guard case let .running(current) = state, current == identifier else { return }
        log("expired \(identifier): pausing all downloads")
        let task = runningTask
        endRun()
        downloadManager?.pauseAllDownloads()
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: false)
        }
        downloadManager?.continuedTaskDidEnd()
    }

    private func endRun() {
        state = .idle
        runningTask = nil
        ticker?.cancel()
        ticker = nil
        batch = [:]
        waitingSince = nil
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[DownloadsActivity] \(message)")
        #endif
    }
}
#endif
