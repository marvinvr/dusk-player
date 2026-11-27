import Foundation
import Network
import Testing
@testable import Dusk

/// `RemuxSegmentRelay` against a loopback stand-in for Plex: segments come
/// back byte for byte except the repaired keyframe offset, with the server's
/// status and framing.
@Suite("Remux segment relay", .serialized)
struct RemuxSegmentRelayTests {
    @Test func relaysAndRepairsASegmentWithContentLength() async throws {
        let segment = RemuxKeyframeTimestampRepairTests.plexSegmentFixture(mediaBytes: 3 << 20)
        var expected = segment
        RemuxKeyframeTimestampRepair.repairSegment(&expected)
        #expect(expected != segment)

        let server = try await FakeSegmentServer.start(body: segment, sendsContentLength: true)
        defer { server.stop() }
        let relay = RemuxSegmentRelay(origin: server.url(path: "/"))
        defer { relay.stop() }
        #expect(await relay.start())

        let relayURL = try #require(relay.relayURL(for: server.url(path: "/session/abc/base/00001.ts")))
        let (data, response) = try await URLSession.shared.data(from: relayURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == expected)
        #expect(server.requestedPaths.contains("/session/abc/base/00001.ts"))
    }

    /// No `Content-Length` upstream: the relay frames it chunked (URLSession
    /// hides the header, so only the bytes are checked).
    @Test func closeDelimitedUpstreamIsRelayedChunked() async throws {
        let segment = RemuxKeyframeTimestampRepairTests.plexSegmentFixture(mediaBytes: 1 << 20)
        var expected = segment
        RemuxKeyframeTimestampRepair.repairSegment(&expected)

        let server = try await FakeSegmentServer.start(body: segment, sendsContentLength: false)
        defer { server.stop() }
        let relay = RemuxSegmentRelay(origin: server.url(path: "/"))
        defer { relay.stop() }
        #expect(await relay.start())

        let relayURL = try #require(relay.relayURL(for: server.url(path: "/00002.ts")))
        let (data, response) = try await URLSession.shared.data(from: relayURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == expected)
    }

    @Test func upstreamErrorStatusPassesThrough() async throws {
        let server = try await FakeSegmentServer.start(body: Data(), sendsContentLength: true, status: 404)
        defer { server.stop() }
        let relay = RemuxSegmentRelay(origin: server.url(path: "/"))
        defer { relay.stop() }
        #expect(await relay.start())

        let relayURL = try #require(relay.relayURL(for: server.url(path: "/00003.ts")))
        let (_, response) = try await URLSession.shared.data(from: relayURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func refusesOffOriginAndUntokenedRequests() async throws {
        let relay = RemuxSegmentRelay(origin: URL(string: "http://plex.test:32400/")!)
        defer { relay.stop() }
        #expect(relay.relayURL(for: URL(string: "http://plex.test:32400/a.ts")!) == nil)   // not started
        #expect(await relay.start())
        #expect(relay.relayURL(for: URL(string: "http://other.test:32400/a.ts")!) == nil)
        #expect(relay.relayURL(for: URL(string: "https://plex.test:32400/a.ts")!) == nil)

        let relayURL = try #require(relay.relayURL(for: URL(string: "http://plex.test:32400/a.ts")!))
        var forged = try #require(URLComponents(url: relayURL, resolvingAgainstBaseURL: false))
        let parts = forged.path.split(separator: "/")
        forged.path = "/" + (["wrong-token"] + parts.dropFirst().map(String.init)).joined(separator: "/")
        let (_, response) = try await URLSession.shared.data(from: try #require(forged.url))
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
    }
}

extension RemuxKeyframeTimestampRepairTests {
    /// A Plex-layout segment with the misplaced keyframe and `mediaBytes` of
    /// sample data.
    static func plexSegmentFixture(mediaBytes: Int) -> Data {
        var segment = plexSegment()
        // Replace the fixture's small mdat with a large one.
        let mdatHeader = 8
        segment.removeLast(64 + mdatHeader)
        var size = UInt32(mediaBytes + mdatHeader).bigEndian
        segment.append(Data(bytes: &size, count: 4))
        segment.append(Data("mdat".utf8))
        segment.append(Data((0..<mediaBytes).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        return segment
    }
}

private final class ResumeOnce: @unchecked Sendable {
    var done = false
}

/// One-response-per-connection HTTP/1.1 server on loopback.
private final class FakeSegmentServer: @unchecked Sendable {
    private let listener: NWListener
    private let body: Data
    private let sendsContentLength: Bool
    private let status: Int
    private let queue = DispatchQueue(label: "fake-segment-server")
    private let lock = NSLock()
    private var paths: [String] = []
    private(set) var port: UInt16 = 0

    var requestedPaths: [String] { lock.withLock { paths } }

    private init(body: Data, sendsContentLength: Bool, status: Int) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.body = body
        self.sendsContentLength = sendsContentLength
        self.status = status
    }

    static func start(body: Data, sendsContentLength: Bool, status: Int = 200) async throws -> FakeSegmentServer {
        let server = try FakeSegmentServer(body: body, sendsContentLength: sendsContentLength, status: status)
        server.listener.newConnectionHandler = { [server] connection in server.serve(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // State updates arrive on the server's serial queue.
            let once = ResumeOnce()
            server.listener.stateUpdateHandler = { [listener = server.listener] state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error):
                    once.done = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            server.listener.start(queue: server.queue)
        }
        server.port = port
        return server
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] content, _, isComplete, error in
            var buffered = buffered
            if let content { buffered.append(content) }
            guard let headEnd = buffered.firstRange(of: Data("\r\n\r\n".utf8)) else {
                if error == nil, !isComplete { receive(on: connection, buffered: buffered) } else { connection.cancel() }
                return
            }
            let head = String(decoding: buffered[..<headEnd.lowerBound], as: UTF8.self)
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            lock.withLock { paths.append(path) }
            respond(on: connection)
        }
    }

    private func respond(on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) X\r\nContent-Type: video/mp4\r\nConnection: close\r\n"
        if sendsContentLength || status != 200 { head += "Content-Length: \(status == 200 ? body.count : 0)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        if status == 200 {
            // Several writes, so the relay sees the moof split across reads.
            var offset = 0
            for length in [40, 70, 300, 65_536] where offset < body.count {
                let end = min(body.count, offset + length)
                connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { _ in })
                offset = end
            }
            if offset < body.count {
                connection.send(content: body.subdata(in: offset..<body.count), completion: .contentProcessed { _ in })
            }
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
