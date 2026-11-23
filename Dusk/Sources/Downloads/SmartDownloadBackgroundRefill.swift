import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// Decisions for the background Keep Next N refill, kept pure for tests.
enum SmartDownloadBackgroundPolicy {
    /// Wi-Fi Only means no refill on an expensive or constrained network, the
    /// same rule `DownloadManager.evaluateNetworkConstraints` applies to the
    /// queue (and every transfer request carries it too).
    static func shouldRun(hasRules: Bool, wifiOnly: Bool, isNetworkConstrained: Bool) -> Bool {
        hasRules && !(wifiOnly && isNetworkConstrained)
    }

    /// A background run may end once every smart episode it can start has
    /// been handed to the background URLSession: none left preparing, and none
    /// queued for a server that is connected (others wait for that server).
    static func isHandedOff(_ pending: [(status: DownloadStatus, serverConnected: Bool)]) -> Bool {
        !pending.contains { $0.status == .preparing || ($0.status == .queued && $0.serverConnected) }
    }
}

#if os(iOS)
/// Runs the Keep Next N refill while Dusk is not open: a `BGProcessingTask`
/// that waits for power and network (iOS typically picks overnight on the
/// charger), plus a cheap `BGAppRefreshTask` for the same refill when iOS
/// grants one. Both are scheduled only while a rule exists; the transfers
/// themselves continue in the existing background URLSession.
@MainActor
enum SmartDownloadBackgroundRefill {
    static let processingIdentifier = "com.dusk-player.app.smart-downloads.refill"
    static let refreshIdentifier = "com.dusk-player.app.smart-downloads.refresh"

    /// Must run before the app finishes launching (`DuskApp.init`).
    static func register(downloadManager: DownloadManager) {
        for identifier in [processingIdentifier, refreshIdentifier] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                MainActor.assumeIsolated {
                    handle(task, downloadManager: downloadManager)
                }
            }
        }
        #if DEBUG
        runDebugSimulationIfRequested(downloadManager: downloadManager)
        #endif
    }

    /// Called when the app leaves the foreground and after every run.
    static func schedule(hasRules: Bool) {
        guard hasRules else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingIdentifier)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
            return
        }
        let processing = BGProcessingTaskRequest(identifier: processingIdentifier)
        processing.requiresExternalPower = true
        processing.requiresNetworkConnectivity = true
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        let refresh = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        // Submitting replaces a pending request with the same identifier. The
        // simulator rejects both (unavailable); nothing to do about that.
        try? BGTaskScheduler.shared.submit(processing)
        try? BGTaskScheduler.shared.submit(refresh)
    }

    private static func handle(_ task: BGTask, downloadManager: DownloadManager) {
        let work = Task { @MainActor in
            task.setTaskCompleted(success: await perform(downloadManager: downloadManager))
        }
        task.expirationHandler = {
            work.cancel()
        }
    }

    private static func perform(downloadManager: DownloadManager) async -> Bool {
        let success = await downloadManager.runBackgroundSmartRefill()
        schedule(hasRules: !downloadManager.storedSmartDownloadRules.isEmpty)
        return success
    }

    #if DEBUG
    /// The simulator cannot submit BGTask requests, so
    /// `_simulateLaunchForTaskWithIdentifier` has nothing to launch there.
    /// `-DuskSimulateSmartRefillAfter <seconds>` runs the same task body that
    /// long after launch (background the app first to mimic iOS).
    static func runDebugSimulationIfRequested(downloadManager: DownloadManager) {
        let delay = UserDefaults.standard.double(forKey: "DuskSimulateSmartRefillAfter")
        guard delay > 0 else { return }
        // Keeps the backgrounded app running until the simulated task, the
        // way iOS keeps it running for a real BGTask launch.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "SmartRefillSimulation")
        Task { @MainActor in
            defer { UIApplication.shared.endBackgroundTask(assertion) }
            try? await Task.sleep(for: .seconds(delay))
            print("[SmartDownloads] simulated background refill started")
            let success = await perform(downloadManager: downloadManager)
            print("[SmartDownloads] simulated background refill finished: \(success)")
        }
    }
    #endif
}
#endif
