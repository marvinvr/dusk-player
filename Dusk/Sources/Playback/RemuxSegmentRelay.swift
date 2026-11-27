import Foundation
import Network
import OSLog

private let segmentRelayLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "RemuxSegmentRelay"
)

/// Loopback relay for the media segments of a Plex fMP4 remux, so each one's
/// first keyframe timestamp can be repaired (`RemuxKeyframeTimestampRepair`)
/// on its way to AVPlayer.
///
/// An `AVAssetResourceLoader` cannot serve HLS media segments, so
/// `RemuxHLSLoader` points the video playlist's segments here instead of at
/// the server. The relay streams each one: it holds back only the bytes up to
/// the first `moof` (a few KB), patches one composition offset there, and
/// passes everything else through as it arrives, never buffering a segment
/// (they run to ~80 MB at UHD Blu-ray bitrates). Status, length and range
/// headers follow the server's; a segment it cannot read goes through
/// untouched.
///
/// Only reachable from this device (loopback interface, local-only), only
/// under a random per-session path token, and only relays URLs on the remux's
/// own origin.
final class RemuxSegmentRelay: @unchecked Sendable {
    /// Bytes handed to a connection and not yet sent before the upstream
    /// task is suspended, and the level it resumes at.
    private static let suspendThreshold = 8 << 20
    private static let resumeThreshold = 2 << 20
    /// See `DolbyVision7HLSProxy.maximumPendingConnections`.
    private static let maximumPendingConnections = 16
    private static let requestHeadTimeout: TimeInterval = 10
    private static let maximumListenerRestarts = 3

    private let origin: URL
    private let token: String
    private let queue = DispatchQueue(label: "com.dusk-player.remux-segment-relay")
    private let delegate: RemuxSegmentRelayDelegate
    private let session: URLSession

    private let lock = NSLock()
    // Everything below is guarded by `lock`.
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var startTask: Task<NWEndpoint.Port?, Never>?
    private var readyContinuation: CheckedContinuation<NWEndpoint.Port?, Never>?
    private var listenerRestarts = 0
    private var isStopped = false
    private var didLogFirstRepair = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pendingHeads: [ObjectIdentifier] = []
    private var streamsByTask: [Int: SegmentStream] = [:]
    private var tasksByConnection: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var relayed = 0
    private var repaired = 0

    /// Segments relayed / repaired so far (tests, diagnostics).
    var relayedSegmentCount: Int { lock.withLock { relayed } }
    var repairedSegmentCount: Int { lock.withLock { repaired } }

    /// `origin`: the remux's server; segments anywhere else are refused.
    init(origin: URL) {
        self.origin = origin
        self.token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let delegate = RemuxSegmentRelayDelegate()
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 600
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        delegate.relay = self
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Binds the listener once (later calls share the first) and checks it
    /// answers: a listener can reach `.ready` and still have every inbound
    /// connection reset (the simulator does this to loopback-only listeners),
    /// which would leave every segment on a dead port. False when it cannot
    /// come up or answer; segments then stay on the server.
    func start() async -> Bool {
        let task = lock.withLock { () -> Task<NWEndpoint.Port?, Never>? in
            guard !isStopped else { return nil }
            if let startTask { return startTask }
            let task = Task { [weak self] () -> NWEndpoint.Port? in
                guard let port = await self?.startListener(on: .any) else { return nil }
                guard await self?.answersPing(on: port) == true else {
                    segmentRelayLogger.error("Loopback listener is up but does not answer; not relaying segments")
                    self?.stop()
                    return nil
                }
                return port
            }
            startTask = task
            return task
        }
        guard let task else { return false }
        return await task.value != nil
    }

    /// The loopback URL that relays `upstream`; nil before `start()`
    /// succeeded or for a URL off the remux's origin.
    func relayURL(for upstream: URL) -> URL? {
        guard DolbyVision7HLSProxy.isSameOrigin(upstream, as: origin),
              let port = lock.withLock({ isStopped ? nil : port }) else { return nil }
        return URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/s/\(DolbyVision7HLSProxy.encodedUpstream(upstream)).m4s")
    }

    private func answersPing(on port: NWEndpoint.Port) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/ping") else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let pingSession = URLSession(configuration: configuration)
        defer { pingSession.invalidateAndCancel() }
        guard let (_, response) = try? await pingSession.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 204
    }

    /// Closes the listener and every connection and upstream task. Idempotent.
    func stop() {
        let teardown = lock.withLock {
            isStopped = true
            let teardown = (
                listener: listener,
                continuation: readyContinuation,
                connections: Array(connections.values),
                startTask: startTask
            )
            listener = nil
            readyContinuation = nil
            connections = [:]
            pendingHeads = []
            streamsByTask = [:]
            tasksByConnection = [:]
            startTask = nil
            return teardown
        }
        teardown.continuation?.resume(returning: nil)
        teardown.startTask?.cancel()
        teardown.connections.forEach { $0.cancel() }
        teardown.listener?.newConnectionHandler = nil
        teardown.listener?.stateUpdateHandler = nil
        teardown.listener?.cancel()
        session.invalidateAndCancel()
    }

    // MARK: - Listener

    private func startListener(on requestedPort: NWEndpoint.Port) async -> NWEndpoint.Port? {
        let parameters = NWParameters.tcp
        // Binding 127.0.0.1 already keeps it on this device. The simulator
        // resets every inbound connection on a listener that also requires
        // the loopback interface / local-only (`SO_NECP_LISTENUUID`, see
        // DolbyVision7ProxyTests), so only devices add them, like the DV7 proxy.
        #if !targetEnvironment(simulator)
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        #endif
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requestedPort)
        guard let listener = try? NWListener(using: parameters) else { return nil }

        return await withCheckedContinuation { continuation in
            let isAccepted = lock.withLock {
                guard !isStopped else { return false }
                self.listener = listener
                readyContinuation = continuation
                return true
            }
            guard isAccepted else {
                continuation.resume(returning: nil)
                return
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.listener(listener, didChange: state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func listener(_ listener: NWListener, didChange state: NWListener.State) {
        switch state {
        case .ready:
            let continuation = lock.withLock { () -> CheckedContinuation<NWEndpoint.Port?, Never>? in
                guard self.listener === listener else { return nil }
                port = listener.port
                defer { readyContinuation = nil }
                return readyContinuation
            }
            continuation?.resume(returning: listener.port)
        case let .failed(error):
            listener.cancel()
            let (continuation, restartPort) = lock.withLock { () -> (CheckedContinuation<NWEndpoint.Port?, Never>?, NWEndpoint.Port?) in
                guard self.listener === listener else { return (nil, nil) }
                if let readyContinuation {
                    self.readyContinuation = nil
                    return (readyContinuation, nil)
                }
                // iOS can tear the listener down while the app is suspended.
                // Re-create it on the same port: the playlist AVPlayer holds
                // names it.
                guard !isStopped, let port, listenerRestarts < Self.maximumListenerRestarts else { return (nil, nil) }
                listenerRestarts += 1
                return (nil, port)
            }
            continuation?.resume(returning: nil)
            if let restartPort {
                segmentRelayLogger.notice("Loopback listener failed (\(String(describing: error), privacy: .public)); re-creating it")
                Task { [weak self] in _ = await self?.startListener(on: restartPort) }
            }
        case .cancelled:
            let continuation = lock.withLock { () -> CheckedContinuation<NWEndpoint.Port?, Never>? in
                guard self.listener === listener else { return nil }
                defer { readyContinuation = nil }
                return readyContinuation
            }
            continuation?.resume(returning: nil)
        default:
            break
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let (isAccepted, evicted) = lock.withLock { () -> (Bool, NWConnection?) in
            guard !isStopped else { return (false, nil) }
            var evicted: NWConnection?
            if pendingHeads.count >= Self.maximumPendingConnections {
                evicted = connections[pendingHeads.removeFirst()]
            }
            connections[key] = connection
            pendingHeads.append(key)
            return (true, evicted)
        }
        evicted?.cancel()
        guard isAccepted else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connectionClosed(key)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestHeadTimeout) { [weak self, weak connection] in
            guard let self, let connection else { return }
            if self.lock.withLock({ self.pendingHeads.contains(key) }) {
                connection.cancel()
            }
        }
        receiveHead(on: connection, buffered: Data())
    }

    private func receiveHead(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffered = buffered
            if let content { buffered.append(content) }
            if let headLength = HLSProxyRequest.headLength(in: buffered) {
                let key = ObjectIdentifier(connection)
                self.lock.withLock { self.pendingHeads.removeAll { $0 == key } }
                self.handle(HLSProxyRequest.parse(buffered.prefix(headLength)), on: connection)
            } else if buffered.count > HLSProxyRequest.maximumHeadLength {
                self.sendFinal(.empty(431), for: nil, on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receiveHead(on: connection, buffered: buffered)
            }
        }
    }

    /// `/<token>/s/<upstream>.m4s`, `<upstream>` the server URL in unpadded
    /// base64url (`DolbyVision7HLSProxy.encodedUpstream`).
    private func handle(_ request: HLSProxyRequest?, on connection: NWConnection) {
        guard let request else {
            sendFinal(.empty(400), for: nil, on: connection)
            return
        }
        guard request.method == "GET" || request.isHead else {
            sendFinal(.empty(405), for: request, on: connection)
            return
        }
        let components = request.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components == ["", token, "ping"] {
            sendFinal(.empty(204), for: nil, on: connection)
            return
        }
        guard components.count == 4, components[0].isEmpty, components[1] == token, components[2] == "s",
              components[3].hasSuffix(".m4s"),
              let upstream = DolbyVision7HLSProxy.decodedUpstream(String(components[3].dropLast(4))),
              DolbyVision7HLSProxy.isSameOrigin(upstream, as: origin) else {
            sendFinal(.empty(403), for: request, on: connection)
            return
        }

        var upstreamRequest = URLRequest(url: upstream)
        upstreamRequest.httpMethod = request.isHead ? "HEAD" : "GET"
        var startsAtZero = true
        if let range = request.range {
            switch range {
            case let .from(start, end):
                upstreamRequest.setValue("bytes=\(start)-\(end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
                startsAtZero = start == 0
            case let .suffix(count):
                upstreamRequest.setValue("bytes=-\(count)", forHTTPHeaderField: "Range")
                startsAtZero = false
            }
        }
        guard (try? PlexTransportSecurity.validate(upstreamRequest)) != nil else {
            sendFinal(.empty(403), for: request, on: connection)
            return
        }

        let task = session.dataTask(with: upstreamRequest)
        let stream = SegmentStream(connection: connection, task: task, isHead: request.isHead, mayRepair: startsAtZero)
        let key = ObjectIdentifier(connection)
        let isOpen = lock.withLock {
            guard connections[key] != nil else { return false }
            streamsByTask[task.taskIdentifier] = stream
            tasksByConnection[key] = task
            relayed += 1
            return true
        }
        guard isOpen else {
            task.cancel()
            return
        }
        watchForPeerClose(on: connection)
        task.resume()
    }

    /// The player hanging up (a seek) only shows as end of stream on the read
    /// side; keep a read pending so it cancels the upstream task.
    private func watchForPeerClose(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self?.watchForPeerClose(on: connection)
            }
        }
    }

    private func connectionClosed(_ key: ObjectIdentifier) {
        let task = lock.withLock { () -> URLSessionDataTask? in
            connections[key] = nil
            pendingHeads.removeAll { $0 == key }
            let task = tasksByConnection.removeValue(forKey: key)
            if let task { streamsByTask[task.taskIdentifier] = nil }
            return task
        }
        task?.cancel()
    }

    private func sendFinal(_ response: HLSProxyResponse, for request: HLSProxyRequest?, on connection: NWConnection) {
        connection.send(
            content: response.serialized(for: request),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: - Upstream (delegate queue = `queue`, serial)

    fileprivate func stream(for task: URLSessionTask) -> SegmentStream? {
        lock.withLock { streamsByTask[task.taskIdentifier] }
    }

    fileprivate func allowsRedirect(_ request: URLRequest, for task: URLSessionTask) -> Bool {
        guard let target = request.url, DolbyVision7HLSProxy.isSameOrigin(target, as: origin) else { return false }
        return PlexTransportSecurity.allowsRedirect(request, original: task.originalRequest)
    }

    fileprivate func received(_ response: URLResponse, for stream: SegmentStream) -> Bool {
        guard let http = response as? HTTPURLResponse else {
            stream.isFinished = true
            sendFinal(.empty(502), for: nil, on: stream.connection)
            return false
        }
        guard (200..<300).contains(http.statusCode) else {
            stream.isFinished = true
            sendFinal(.empty(http.statusCode), for: nil, on: stream.connection)
            return false
        }

        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        if http.statusCode != 200, contentRange?.lowercased().hasPrefix("bytes 0-") != true {
            stream.mayRepair = false
        }
        var headers = [
            "Content-Type": http.mimeType ?? HLSProxyResponse.mp4ContentType,
            "Cache-Control": "no-store",
            "Connection": "close",
        ]
        if let contentRange { headers["Content-Range"] = contentRange }
        if let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges") { headers["Accept-Ranges"] = acceptRanges }
        if response.expectedContentLength >= 0 {
            headers["Content-Length"] = String(response.expectedContentLength)
        } else if !stream.isHead {
            // Never close-delimited: a truncated segment must not look complete.
            headers["Transfer-Encoding"] = "chunked"
            stream.isChunked = true
        }
        var head = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized)\r\n"
        for name in headers.keys.sorted() {
            head += "\(name): \(headers[name] ?? "")\r\n"
        }
        head += "\r\n"
        stream.didSendHead = true

        if stream.isHead {
            stream.isFinished = true
            stream.connection.send(
                content: Data(head.utf8),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [connection = stream.connection] _ in connection.cancel() }
            )
            return false
        }
        stream.connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        if !stream.mayRepair { stream.prefix = nil }
        return true
    }

    fileprivate func received(_ data: Data, for stream: SegmentStream) {
        guard var prefix = stream.prefix else {
            forward(data, for: stream)
            return
        }
        prefix.append(data)
        switch RemuxKeyframeTimestampRepair.scanPrefix(prefix) {
        case .needsMoreBytes:
            stream.prefix = prefix
        case let .moofComplete(end):
            if RemuxKeyframeTimestampRepair.repair(&prefix, moofEnd: end) > 0 {
                logFirstRepair()
            }
            stream.prefix = nil
            forward(prefix, for: stream)
        case .passThrough:
            stream.prefix = nil
            forward(prefix, for: stream)
        }
    }

    fileprivate func completed(_ stream: SegmentStream, error: (any Error)?) {
        lock.withLock {
            streamsByTask[stream.task.taskIdentifier] = nil
            tasksByConnection[ObjectIdentifier(stream.connection)] = nil
        }
        guard !stream.isFinished else { return }
        stream.isFinished = true
        if let error {
            if (error as? URLError)?.code != .cancelled {
                segmentRelayLogger.error("Segment relay upstream failed: \(error.localizedDescription, privacy: .public)")
            }
            if stream.didSendHead {
                // Cut mid-body: the player sees the segment fail and retries.
                stream.connection.cancel()
            } else {
                sendFinal(.empty(502), for: nil, on: stream.connection)
            }
            return
        }
        if let prefix = stream.prefix {
            stream.prefix = nil
            forward(prefix, for: stream)
        }
        let tail = stream.isChunked ? Data("0\r\n\r\n".utf8) : Data()
        stream.connection.send(
            content: tail,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [connection = stream.connection] _ in connection.cancel() }
        )
    }

    private func forward(_ data: Data, for stream: SegmentStream) {
        guard !data.isEmpty else { return }
        var content = data
        if stream.isChunked {
            content = Data((String(data.count, radix: 16) + "\r\n").utf8)
            content.append(data)
            content.append(contentsOf: [0x0D, 0x0A])
        }
        let count = content.count
        stream.queuedBytes += count
        if stream.queuedBytes > Self.suspendThreshold, !stream.isSuspended {
            stream.isSuspended = true
            stream.task.suspend()
        }
        stream.connection.send(content: content, completion: .contentProcessed { [stream] error in
            // NWConnection completions run on `queue`, like the delegate.
            stream.queuedBytes -= count
            if error != nil {
                stream.task.cancel()
                stream.connection.cancel()
                return
            }
            if stream.isSuspended, stream.queuedBytes < Self.resumeThreshold {
                stream.isSuspended = false
                stream.task.resume()
            }
        })
    }

    private func logFirstRepair() {
        let isFirst = lock.withLock { () -> Bool in
            repaired += 1
            defer { didLogFirstRepair = true }
            return !didLogFirstRepair
        }
        if isFirst {
            segmentRelayLogger.notice("Repaired the misplaced first keyframe timestamp of a remux segment (open GOP)")
        }
    }
}

/// One relayed segment. Touched only on the relay's queue.
fileprivate final class SegmentStream: @unchecked Sendable {
    let connection: NWConnection
    let task: URLSessionDataTask
    let isHead: Bool
    var mayRepair: Bool
    /// Bytes held back until the first `moof` is complete; nil once flowing.
    var prefix: Data? = Data()
    var isChunked = false
    var didSendHead = false
    /// The response is complete (or refused); nothing more goes out.
    var isFinished = false
    var queuedBytes = 0
    var isSuspended = false

    init(connection: NWConnection, task: URLSessionDataTask, isHead: Bool, mayRepair: Bool) {
        self.connection = connection
        self.task = task
        self.isHead = isHead
        self.mayRepair = mayRepair
    }
}

/// Separate from the relay so the session (which retains its delegate until
/// invalidated) does not keep the relay alive.
private final class RemuxSegmentRelayDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var relay: RemuxSegmentRelay?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(relay?.allowsRedirect(request, for: task) == true ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let relay, let stream = relay.stream(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(relay.received(response, for: stream) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let relay, let stream = relay.stream(for: dataTask) else {
            dataTask.cancel()
            return
        }
        relay.received(data, for: stream)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let relay, let stream = relay.stream(for: task) else { return }
        relay.completed(stream, error: error)
    }
}
