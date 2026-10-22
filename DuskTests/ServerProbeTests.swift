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
