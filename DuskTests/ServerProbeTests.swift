import Foundation
import Testing
@testable import Dusk

@Suite("Plex connection probe cancellation", .timeLimit(.minutes(1)))
struct ServerProbeTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func plan(_ index: Int, host: String) -> ServerProbe.Plan {
        let baseURL = URL(string: "https://\(host)")!
        let connection = PlexConnection(
            protocol: "https", address: host, port: 443,
            uri: baseURL.absoluteString, local: index == 0, relay: false, iPv6: false
        )
        return ServerProbe.Plan(
            index: index, baseURL: baseURL, connection: connection,
            probeRequest: URLRequest(url: baseURL.appendingPathComponent("identity")),
            validationRequest: URLRequest(url: baseURL.appendingPathComponent("library/sections"))
        )
    }

    @Test func unbeatableWinnerCancelsOutstandingProbes() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        // Repeated races exercise a fast winner while another child is still
        // waiting on URLSession, as happens during post-profile discovery.
        for _ in 0..<50 {
            let result = await ServerProbe.resolve(
                plans: [plan(0, host: "ready.invalid"), plan(1, host: "pending.invalid")],
                serverName: "Test", session: session
            )
            guard case let .connected(url, _) = result else {
                Issue.record("Expected the reachable preferred connection")
                return
            }
            #expect(url.host == "ready.invalid")
        }
    }

    @Test func graceWinnerSurvivesCancelledHigherPriorityProbe() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        for _ in 0..<50 {
            let result = await ServerProbe.resolve(
                plans: [plan(0, host: "pending.invalid"), plan(1, host: "ready.invalid")],
                serverName: "Test", session: session, grace: .milliseconds(1)
            )
            guard case let .connected(url, _) = result else {
                Issue.record("A cancelled losing probe replaced the grace winner")
                return
            }
            #expect(url.host == "ready.invalid")
        }
    }

    @Test func reachablePreferredEndpointWinsRegardlessOfCompletionOrder() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let result = await ServerProbe.resolve(
            plans: [plan(0, host: "preferred.invalid"), plan(1, host: "ready.invalid")],
            serverName: "Test", session: session
        )
        guard case let .connected(url, _) = result else {
            Issue.record("Expected a connected endpoint")
            return
        }
        #expect(url.host == "preferred.invalid")
    }

    @Test func unauthorizedProbesRemainUnauthorized() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let result = await ServerProbe.resolve(
            plans: [plan(0, host: "unauthorized.invalid")],
            serverName: "Test", session: session
        )
        guard case .unauthorized = result else {
            Issue.record("Expected unauthorized rather than an offline error")
            return
        }
    }
}

/// No real network traffic. The pending endpoint only completes when the
/// resolver cancels its request; all other endpoints answer synchronously.
private final class ProbeURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.host != "pending.invalid" else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: url.host == "unauthorized.invalid" ? 401 : 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Debug test builds cannot hit the `-O` miscompile behind the
/// `completeFuture` -> `__cxa_pure_virtual` crash (see `Result.capturing`), so the
/// shape that triggers it is banned at the source level as well.
@Suite("Task group child shape", .timeLimit(.minutes(1)))
struct TaskGroupChildShapeTests {
    private struct Failure: Error, Equatable {}

    private struct ChildAnswer: Sendable {
        let key: String
        let outcome: Result<Int, any Error>
    }

    @Test("capturing reports the value")
    func capturingSuccess() async throws {
        let result = await Result.capturing { 42 }
        #expect(try result.get() == 42)
    }

    @Test("capturing reports the error")
    func capturingFailure() async {
        let result: Result<Int, any Error> = await Result.capturing { throw Failure() }
        #expect(throws: Failure.self) { try result.get() }
    }

    @Test("Every child answers once, with its own key, through capturing")
    func everyChildAnswers() async {
        let keys = (0..<32).map(String.init)
        let answers = await withTaskGroup(of: ChildAnswer.self) { group in
            for key in keys {
                group.addTask {
                    let outcome = await Result.capturing {
                        try await Task.sleep(for: .milliseconds(1))
                        guard key.hasSuffix("7") else { return key.count }
                        throw Failure()
                    }
                    return ChildAnswer(key: key, outcome: outcome)
                }
            }
            var answers: [ChildAnswer] = []
            for await answer in group {
                answers.append(answer)
            }
            return answers
        }

        #expect(answers.map(\.key).sorted() == keys.sorted())
        for answer in answers {
            if answer.key.hasSuffix("7") {
                #expect(throws: Failure.self) { try answer.outcome.get() }
            } else {
                #expect((try? answer.outcome.get()) == answer.key.count)
            }
        }
    }

    @Test("No addTask closure in the app contains a catch")
    func noCatchInTaskGroupChildren() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Dusk/Sources")
        // The sources are not there when the tests run away from this Mac.
        guard FileManager.default.fileExists(atPath: sources.path) else { return }

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var scannedChildren = 0
        var offenders: [String] = []
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for body in Self.addTaskBodies(in: text) {
                scannedChildren += 1
                if body.contains(/\bcatch\b/) {
                    offenders.append("\(file.lastPathComponent): \(body.prefix(120))")
                }
            }
        }

        #expect(scannedChildren > 10, "The scan stopped finding task group children")
        #expect(offenders.isEmpty, "Use Result.capturing: \(offenders)")
    }

    @Test("The scan sees a catch in a child and skips comments")
    func scanFindsChildBodies() {
        let source = """
        group.addTask {
            // catch
            do { return try await load() } catch { return nil }
        }
        """
        let bodies = Self.addTaskBodies(in: source)
        #expect(bodies.count == 1)
        #expect(bodies.first?.contains("do {") == true)
        #expect(bodies.first?.contains("// catch") == false)
    }

    /// The brace-balanced closure of every `addTask`, with line comments removed.
    private static func addTaskBodies(in text: String) -> [String] {
        let code = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
            }
            .joined(separator: "\n")

        var bodies: [String] = []
        var searchStart = code.startIndex
        while let call = code.range(of: "addTask", range: searchStart..<code.endIndex) {
            searchStart = call.upperBound
            guard let open = code[call.upperBound...].firstIndex(of: "{") else { break }
            var depth = 0
            var index = open
            while index < code.endIndex {
                if code[index] == "{" { depth += 1 }
                if code[index] == "}" { depth -= 1 }
                if depth == 0 {
                    bodies.append(String(code[open...index]))
                    break
                }
                index = code.index(after: index)
            }
        }
        return bodies
    }
}
