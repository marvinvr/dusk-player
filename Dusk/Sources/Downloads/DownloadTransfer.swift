import Foundation

enum DownloadTransferEvent: Sendable {
    case progress(taskIdentifier: Int, globalKey: String?, progress: Double, downloadedBytes: Int64, totalBytes: Int64)
    case paused(taskIdentifier: Int, globalKey: String?, resumeData: Data?)
    case cancelled(taskIdentifier: Int, globalKey: String?)
    case finished(taskIdentifier: Int, globalKey: String?, temporaryURL: URL, response: DownloadTransferResponse?)
    case failed(taskIdentifier: Int, globalKey: String?, error: Error)
    /// iOS delivered every event of a background wake. The manager calls
    /// `DownloadBackgroundSessionRegistry.completeEvents` once its own
    /// follow-up work (the next hand-off) has settled.
    case backgroundEventsFinished(sessionIdentifier: String)
}

struct DownloadTransferResponse: Sendable {
    let statusCode: Int?
    let mimeType: String?
    let expectedContentLength: Int64
}

struct DownloadTransferTask: Sendable {
    let identifier: Int
    let globalKey: String?
}

enum DownloadBackgroundSessionRegistry {
    static let identifier = "com.dusk-player.app.downloads.background"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var completionHandlers: [String: () -> Void] = [:]

    static func setCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        lock.lock()
        completionHandlers[identifier] = handler
        lock.unlock()
    }

    static func completeEvents(for identifier: String) {
        lock.lock()
        let handler = completionHandlers.removeValue(forKey: identifier)
        lock.unlock()
        // Called from the main actor (`DownloadManager`), as UIKit expects.
        handler?()
    }
}

/// Owns the URLSessions that move download bytes.
///
/// - The **background** session (iOS) is the transport: its transfers keep
///   going while Dusk is suspended, locked or killed by the system. Every
///   queued Original download is handed to it up front, and the session's
///   `httpMaximumConnectionsPerHost` (the Simultaneous Downloads setting at
///   launch) decides how many run at once, so the queue no longer needs Dusk
///   to wake up between files.
/// - The **live** session (iOS 26+) is used only for a transfer created while
///   Dusk runs in the background under the downloads continued-processing
///   task. iOS treats any background-session task created in the background
///   as discretionary (it may wait for power and Wi-Fi), so a converted file
///   that Plex finished preparing while the user was away would otherwise sit
///   idle. Live transfers are moved to the background session before Dusk can
///   be suspended (`DownloadManager.moveLiveTransfersToBackgroundSession`).
///
/// Task identifiers are only unique per session. Live tasks are reported with
/// negative identifiers (`-(taskIdentifier + 1)`) so a record's
/// `downloadTaskIdentifier` names exactly one task. Live tasks never survive
/// the process, so relaunch reconciliation only ever sees background ones.
final class DownloadTransferController: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct ProgressSnapshot {
        let date: Date
    }

    private static let progressEventInterval: TimeInterval = 0.75

    private let eventHandler: @Sendable (DownloadTransferEvent) -> Void
    private let maximumConnectionsPerHost: Int
    private let stateLock = NSLock()
    private var pausedTaskIdentifiers: Set<Int> = []
    private var cancelledTaskIdentifiers: Set<Int> = []
    private var progressSnapshots: [Int: ProgressSnapshot] = [:]
    private lazy var session: URLSession = {
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(
            withIdentifier: DownloadBackgroundSessionRegistry.identifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        #else
        let configuration = URLSessionConfiguration.default
        #endif
        Self.applyCommonSettings(to: configuration, maximumConnectionsPerHost: maximumConnectionsPerHost)
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private lazy var liveSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        Self.applyCommonSettings(to: configuration, maximumConnectionsPerHost: maximumConnectionsPerHost)
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(maximumConnectionsPerHost: Int, eventHandler: @escaping @Sendable (DownloadTransferEvent) -> Void) {
        self.maximumConnectionsPerHost = max(1, maximumConnectionsPerHost)
        self.eventHandler = eventHandler
        super.init()
        _ = session
    }

    private static func applyCommonSettings(to configuration: URLSessionConfiguration, maximumConnectionsPerHost: Int) {
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
    }

    static func isLiveIdentifier(_ identifier: Int) -> Bool {
        identifier < 0
    }

    private func reportedIdentifier(for task: URLSessionTask, in session: URLSession) -> Int {
        session === liveSessionIfCreated ? -(task.taskIdentifier + 1) : task.taskIdentifier
    }

    /// Avoids creating the live session just to compare against it.
    private var hasLiveSession = false
    private var liveSessionIfCreated: URLSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return hasLiveSession ? liveSession : nil
    }

    private func makeLiveSessionIfNeeded() -> URLSession {
        stateLock.lock()
        defer { stateLock.unlock() }
        hasLiveSession = true
        return liveSession
    }

    /// Starts a transfer and returns its reported identifier. `live` uses the
    /// in-process session (see the type comment); everything else goes to the
    /// background session.
    func start(
        request: URLRequest,
        resumeData: Data?,
        globalKey: String,
        live: Bool = false,
        priority: Float = URLSessionTask.defaultPriority
    ) throws -> Int {
        try TransportSecurity.validate(request)
        let targetSession = live ? makeLiveSessionIfNeeded() : session
        let task: URLSessionDownloadTask
        if let resumeData {
            let resumed = targetSession.downloadTask(withResumeData: resumeData)
            // Resume data may contain an endpoint saved by an older version.
            // If URLSession cannot expose that request yet, restart from the
            // freshly validated URL rather than trusting opaque resume data.
            if let original = resumed.originalRequest ?? resumed.currentRequest,
               original.url.map(TransportSecurity.allowsCredential(in:)) == true {
                task = resumed
            } else {
                resumed.cancel()
                task = targetSession.downloadTask(with: request)
            }
        } else {
            task = targetSession.downloadTask(with: request)
        }
        task.taskDescription = globalKey
        // Earlier queue entries first: the handed-off tasks wait inside the
        // session, which otherwise starts them in creation order (and
        // preparations finish in any order).
        task.priority = priority
        task.resume()
        return reportedIdentifier(for: task, in: targetSession)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(TransportSecurity.allowsRedirect(request, original: task.originalRequest) ? request : nil)
    }

    func pause(taskIdentifier: Int) {
        findDownloadTask(taskIdentifier: taskIdentifier) { [weak self] task in
            guard let self, let task else { return }
            self.stateLock.lock()
            self.pausedTaskIdentifiers.insert(taskIdentifier)
            self.stateLock.unlock()
            task.cancel(byProducingResumeData: { resumeData in
                self.eventHandler(.paused(
                    taskIdentifier: taskIdentifier,
                    globalKey: task.taskDescription,
                    resumeData: resumeData
                ))
            })
        }
    }

    func cancel(taskIdentifier: Int) {
        findDownloadTask(taskIdentifier: taskIdentifier) { [weak self] task in
            guard let self, let task else { return }
            self.stateLock.lock()
            self.cancelledTaskIdentifiers.insert(taskIdentifier)
            self.stateLock.unlock()
            task.cancel()
        }
    }

    /// Background-session tasks only: live tasks die with the process, so
    /// after a relaunch there are none to reconcile.
    func existingTasks() async -> [DownloadTransferTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let downloads = tasks.compactMap { task -> DownloadTransferTask? in
                    guard task is URLSessionDownloadTask else { return nil }
                    return DownloadTransferTask(
                        identifier: task.taskIdentifier,
                        globalKey: task.taskDescription
                    )
                }
                continuation.resume(returning: downloads)
            }
        }
    }

    private func findDownloadTask(
        taskIdentifier: Int,
        completion: @escaping @Sendable (URLSessionDownloadTask?) -> Void
    ) {
        let isLive = Self.isLiveIdentifier(taskIdentifier)
        guard let targetSession = isLive ? liveSessionIfCreated : session else {
            completion(nil)
            return
        }
        let rawIdentifier = isLive ? -taskIdentifier - 1 : taskIdentifier
        targetSession.getAllTasks { tasks in
            let task = tasks.first { $0.taskIdentifier == rawIdentifier } as? URLSessionDownloadTask
            completion(task)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let identifier = reportedIdentifier(for: downloadTask, in: session)
        let totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        let progressValue: Double
        if totalBytes > 0 {
            progressValue = min(max(Double(totalBytesWritten) / Double(totalBytes), 0), 1)
        } else {
            progressValue = 0
        }

        stateLock.lock()
        let now = Date()
        let previous = progressSnapshots[identifier]
        let isComplete = totalBytes > 0 && totalBytesWritten >= totalBytes
        let shouldEmit = previous == nil
            || isComplete
            || now.timeIntervalSince(previous?.date ?? .distantPast) >= Self.progressEventInterval
        if shouldEmit {
            progressSnapshots[identifier] = ProgressSnapshot(
                date: now
            )
        }
        stateLock.unlock()

        guard shouldEmit else { return }

        eventHandler(.progress(
            taskIdentifier: identifier,
            globalKey: downloadTask.taskDescription,
            progress: progressValue,
            downloadedBytes: totalBytesWritten,
            totalBytes: totalBytes
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let identifier = reportedIdentifier(for: downloadTask, in: session)
        do {
            let stableLocation = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: stableLocation)
            let httpResponse = downloadTask.response as? HTTPURLResponse
            eventHandler(.finished(
                taskIdentifier: identifier,
                globalKey: downloadTask.taskDescription,
                temporaryURL: stableLocation,
                response: DownloadTransferResponse(
                    statusCode: httpResponse?.statusCode,
                    mimeType: downloadTask.response?.mimeType,
                    expectedContentLength: downloadTask.response?.expectedContentLength ?? -1
                )
            ))
        } catch {
            eventHandler(.failed(
                taskIdentifier: identifier,
                globalKey: downloadTask.taskDescription,
                error: error
            ))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let identifier = reportedIdentifier(for: task, in: session)
        stateLock.lock()
        let wasPaused = pausedTaskIdentifiers.remove(identifier) != nil
        let wasCancelled = cancelledTaskIdentifiers.remove(identifier) != nil
        progressSnapshots.removeValue(forKey: identifier)
        stateLock.unlock()

        if wasPaused {
            return
        }

        if wasCancelled {
            eventHandler(.cancelled(
                taskIdentifier: identifier,
                globalKey: task.taskDescription
            ))
            return
        }

        if let error {
            eventHandler(.failed(
                taskIdentifier: identifier,
                globalKey: task.taskDescription,
                error: error
            ))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        eventHandler(.backgroundEventsFinished(sessionIdentifier: session.configuration.identifier ?? ""))
    }
}
