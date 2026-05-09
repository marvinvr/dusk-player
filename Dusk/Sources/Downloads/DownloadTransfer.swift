import Foundation

enum DownloadTransferEvent: Sendable {
    case progress(taskIdentifier: Int, globalKey: String?, progress: Double, downloadedBytes: Int64, totalBytes: Int64)
    case paused(taskIdentifier: Int, globalKey: String?, resumeData: Data?)
    case cancelled(taskIdentifier: Int, globalKey: String?)
    case finished(taskIdentifier: Int, globalKey: String?, temporaryURL: URL)
    case failed(taskIdentifier: Int, globalKey: String?, error: Error)
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
        handler?()
    }
}

final class DownloadTransferController: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct ProgressSnapshot {
        let date: Date
    }

    private static let progressEventInterval: TimeInterval = 0.75

    private let eventHandler: @Sendable (DownloadTransferEvent) -> Void
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
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(eventHandler: @escaping @Sendable (DownloadTransferEvent) -> Void) {
        self.eventHandler = eventHandler
        super.init()
        _ = session
    }

    func start(
        request: URLRequest,
        resumeData: Data?,
        globalKey: String
    ) -> Int {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        task.taskDescription = globalKey
        task.resume()
        return task.taskIdentifier
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
        session.getAllTasks { tasks in
            let task = tasks.first { $0.taskIdentifier == taskIdentifier } as? URLSessionDownloadTask
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
        let totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        let progressValue: Double
        if totalBytes > 0 {
            progressValue = min(max(Double(totalBytesWritten) / Double(totalBytes), 0), 1)
        } else {
            progressValue = 0
        }

        stateLock.lock()
        let now = Date()
        let previous = progressSnapshots[downloadTask.taskIdentifier]
        let isComplete = totalBytes > 0 && totalBytesWritten >= totalBytes
        let shouldEmit = previous == nil
            || isComplete
            || now.timeIntervalSince(previous?.date ?? .distantPast) >= Self.progressEventInterval
        if shouldEmit {
            progressSnapshots[downloadTask.taskIdentifier] = ProgressSnapshot(
                date: now
            )
        }
        stateLock.unlock()

        guard shouldEmit else { return }

        eventHandler(.progress(
            taskIdentifier: downloadTask.taskIdentifier,
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
        do {
            let stableLocation = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: stableLocation)
            eventHandler(.finished(
                taskIdentifier: downloadTask.taskIdentifier,
                globalKey: downloadTask.taskDescription,
                temporaryURL: stableLocation
            ))
        } catch {
            eventHandler(.failed(
                taskIdentifier: downloadTask.taskIdentifier,
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
        stateLock.lock()
        let wasPaused = pausedTaskIdentifiers.remove(task.taskIdentifier) != nil
        let wasCancelled = cancelledTaskIdentifiers.remove(task.taskIdentifier) != nil
        progressSnapshots.removeValue(forKey: task.taskIdentifier)
        stateLock.unlock()

        if wasPaused {
            return
        }

        if wasCancelled {
            eventHandler(.cancelled(
                taskIdentifier: task.taskIdentifier,
                globalKey: task.taskDescription
            ))
            return
        }

        if let error {
            eventHandler(.failed(
                taskIdentifier: task.taskIdentifier,
                globalKey: task.taskDescription,
                error: error
            ))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DownloadBackgroundSessionRegistry.completeEvents(for: session.configuration.identifier ?? "")
    }
}
