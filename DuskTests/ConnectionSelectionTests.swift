import Foundation
import Testing
@testable import Dusk

/// Connection selection: ranking, the identity gate, redirects, persistence,
/// failover and the "away from home" case. No real network: every host is
/// scripted by `SelectionStub`.
@Suite("Plex connection selection", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ConnectionSelectionTests {
    private let serverID = "selection-server"

    // MARK: Ranking

    @Test func httpsBeatsHTTPEvenWhenTheHTTPOneIsLocal() async {
        let stub = SelectionStub.Scope()
        let lan = stub.host("lan", .ok(serverID))
        let proxy = stub.host("proxy", .ok(serverID))
        let selection = await select([
            candidate("http://\(lan):32400", address: "192.168.1.2", local: true),
            candidate("https://\(proxy)", address: proxy),
        ], session: stub.session)
        #expect(chosenHost(selection) == proxy)
    }

    @Test func localHTTPSBeatsTailnetAndRemoteHTTPS() async {
        let stub = SelectionStub.Scope()
        let remote = stub.host("remote", .ok(serverID))
        let lan = stub.host("lan", .ok(serverID, delay: 0.05))
        let selection = await select([
            candidate("https://\(remote)", address: remote),
            candidate("https://\(lan)", address: "192.168.1.2", local: true),
            candidate("https://storage.tail1.ts.net", address: "100.115.114.92"),
        ], session: stub.session)
        // The slower LAN still wins: it outranks the remote that answered first.
        #expect(chosenHost(selection) == lan)
    }

    @Test func directHTTPBeatsTheRelay() async {
        let stub = SelectionStub.Scope()
        let relay = stub.host("relay", .ok(serverID))
        let direct = stub.host("direct", .ok(serverID, delay: 0.05))
        let selection = await select([
            candidate("https://\(relay)", address: relay, relay: true),
            candidate("http://\(direct):32400", address: direct),
        ], session: stub.session)
        #expect(chosenHost(selection) == direct)
    }

    @Test func latencyBreaksTiesInsideOneClass() async {
        let stub = SelectionStub.Scope()
        let slow = stub.host("slow", .ok(serverID, delay: 0.15))
        let fast = stub.host("fast", .ok(serverID, delay: 0.01))
        let selection = await select([
            candidate("https://\(slow)", address: slow),
            candidate("https://\(fast)", address: fast),
        ], session: stub.session, waitForAll: true)
        #expect(chosenHost(selection) == fast)
        #expect(selection.report.entries.allSatisfy { $0.outcome.isReachable })
    }

    @Test func rankOrderIsHTTPSThenLocalityThenBridge() {
        let order = [
            candidate("https://a.plex.direct", address: "192.168.1.2", local: true),
            candidate("https://b.plex.direct", address: "172.18.0.2", local: true),
            candidate("https://100-64-0-1.x.plex.direct", address: "100.64.0.1"),
            candidate("https://plex.example.com", address: "plex.example.com"),
            candidate("http://192.168.1.2:32400", address: "192.168.1.2", local: true),
            candidate("http://storage:10003", address: "storage"),
            candidate("http://plex.example.com", address: "plex.example.com"),
            candidate("https://relay.plex.direct", address: "1.2.3.4", relay: true),
        ]
        #expect(order.map(\.rank) == order.map(\.rank).sorted())
        #expect(Set(order.map(\.rank)).count == order.count)
        #expect(order[2].locality == .tailnet)
        #expect(order[5].locality == .tailnet)
        #expect(order[7].locality == .relay)
    }

    // MARK: Robustness

    @Test func aHungBetterCandidateNeverHoldsUpAWorkingOne() async {
        let stub = SelectionStub.Scope()
        let hung = stub.host("hung", .hang)
        let working = stub.host("working", .ok(serverID))
        let started = Date()
        let selection = await select([
            candidate("https://\(hung)", address: "192.168.1.2", local: true),
            candidate("http://\(working):32400", address: working),
        ], session: stub.session, grace: .milliseconds(50))
        #expect(chosenHost(selection) == working)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(selection.report.entries[0].outcome == .skipped)
    }

    @Test func aDifferentServerNeverWinsWhateverItsRank() async {
        let stub = SelectionStub.Scope()
        let impostor = stub.host("impostor", .ok("someone-else"))
        let portal = stub.host("portal", .html)
        let real = stub.host("real", .ok(serverID, delay: 0.05))
        let selection = await select([
            candidate("https://\(impostor)", address: "192.168.1.2", local: true),
            candidate("https://\(portal)", address: "192.168.1.3", local: true),
            candidate("http://\(real):32400", address: real),
        ], session: stub.session)
        #expect(chosenHost(selection) == real)
        #expect(selection.report.entries[0].outcome == .wrongServer("someone-else"))
        #expect(selection.report.entries[1].outcome == .wrongServer(nil))
    }

    @Test func everyCandidateRejectingTheTokenIsUnauthorizedNotOffline() async {
        let stub = SelectionStub.Scope()
        let host = stub.host("denied", .unauthorized(serverID))
        let selection = await select([candidate("https://\(host)", address: host)], session: stub.session)
        guard case .unauthorized = selection.resolution else {
            Issue.record("Expected unauthorized, got \(selection.resolution)")
            return
        }
    }

    @Test func nothingReachableFailsWithAReportOfEveryCandidate() async {
        let stub = SelectionStub.Scope()
        let a = stub.host("a", .refuse)
        let b = stub.host("b", .refuse)
        let selection = await select([
            candidate("https://\(a)", address: a), candidate("http://\(b)", address: b),
        ], session: stub.session)
        guard case .failed = selection.resolution else {
            Issue.record("Expected failure")
            return
        }
        #expect(selection.report.chosenURL == nil)
        #expect(selection.report.entries.allSatisfy { $0.outcome == .failed("Connection refused") })
        #expect(!selection.report.text.contains("test-token"))
    }

    // MARK: Redirects and the token

    @Test func aCrossHostRedirectNeverGetsTheTokenAndNeverWins() async {
        let stub = SelectionStub.Scope()
        let elsewhere = stub.host("elsewhere", .ok(serverID))
        let bouncer = stub.host("bouncer", .redirect("https://\(elsewhere)/identity"))
        let selection = await select([candidate("https://\(bouncer)", address: bouncer)], session: stub.session)
        guard case .failed = selection.resolution else {
            Issue.record("A redirect to another host must not connect")
            return
        }
        #expect(SelectionStub.requests(host: elsewhere).isEmpty)
    }

    @Test func httpRedirectingToHTTPSLosesToTheHTTPSCandidate() async {
        let stub = SelectionStub.Scope()
        let proxy = stub.host("proxy", .ok(serverID))
        let selection = await select([
            candidate("http://\(proxy)", address: proxy),
            candidate("https://\(proxy)", address: proxy, source: .httpsUpgrade),
        ], session: stub.session, waitForAll: true)
        #expect(selection.report.chosenURL?.scheme == "https")
    }

    @Test func redirectRules() {
        var original = URLRequest(url: URL(string: "https://plex.example.com/identity")!)
        original.setValue("t", forHTTPHeaderField: "X-Plex-Token")
        func allows(_ raw: String) -> Bool {
            PlexTransportSecurity.allowsRedirect(URLRequest(url: URL(string: raw)!), original: original)
        }
        #expect(allows("https://plex.example.com/web"))
        #expect(allows("https://PLEX.example.com:32400/x"))
        #expect(!allows("http://plex.example.com/identity"))
        #expect(!allows("https://evil.example/identity"))
        original.url = URL(string: "http://plex.example.com/identity")
        #expect(allows("https://plex.example.com/identity"))
        #expect(allows("http://plex.example.com/other"))
        #expect(!allows("http://other.example.com/identity"))
        // Without a credential anything goes.
        #expect(PlexTransportSecurity.allowsRedirect(
            URLRequest(url: URL(string: "http://cdn.example/poster")!),
            original: URLRequest(url: URL(string: "https://metadata.example/poster")!)
        ))
    }

    // MARK: Candidates

    @Test func candidatesCoverEveryVariantOnce() throws {
        let server = try server([
            connection("https://192-168-1-2.abc.plex.direct:32400", address: "192.168.1.2", local: true),
            connection("https://37-17-1-2.abc.plex.direct:32400", address: "37.17.1.2"),
            connection("https://plex.example.com:443", address: "plex.example.com"),
            connection("http://plex.example.com:80", address: "plex.example.com"),
            connection("http://storage:10003", address: "storage"),
            connection("http://100.115.114.92:10003", address: "100.115.114.92"),
            connection("https://1-2-3-4.abc.plex.direct:8443", address: "1.2.3.4", relay: true),
            connection("https://[fe80::1]:32400", address: "fe80::1", local: true),
        ])
        let urls = ServerPool.connectionCandidates(
            for: server, lastKnownGood: URL(string: "http://old-name:32400")
        ).map(\.baseURL.absoluteString)
        for expected in [
            "https://192-168-1-2.abc.plex.direct:32400", "http://192.168.1.2:32400",
            "https://37-17-1-2.abc.plex.direct:32400", "http://37.17.1.2:32400",
            "https://plex.example.com:443", "http://plex.example.com:80",
            "http://storage:10003", "http://100.115.114.92:10003",
            "https://1-2-3-4.abc.plex.direct:8443", "http://old-name:32400",
        ] {
            #expect(urls.contains(expected), "\(expected) missing from \(urls)")
        }
        // https://plex.example.com (the upgrade of :80) is the listed :443 one.
        #expect(!urls.contains("https://plex.example.com"))
        #expect(!urls.contains("http://1.2.3.4:8443"), "a relay gets no raw-IP fallback")
        #expect(!urls.contains { $0.contains("fe80") })
        #expect(!urls.contains("https://storage:10003"), "private names are never upgraded")
        #expect(Set(urls).count == urls.count)
    }

    @Test func publicHTTPCustomURLIsACandidateAlongsideItsUpgrade() throws {
        let server = try server([connection("http://plex.example.com:32400", address: "plex.example.com")])
        let candidates = ServerPool.connectionCandidates(for: server)
        #expect(candidates.map(\.baseURL.absoluteString) == [
            "http://plex.example.com:32400", "https://plex.example.com:32400",
        ])
        #expect(candidates[1].source == .httpsUpgrade)
    }

    @Test func plainHTTPCarriesTheTokenAnywhere() throws {
        for raw in ["http://plex.example.com:32400", "http://8.8.8.8", "http://192.168.1.2", "https://x.example"] {
            var request = URLRequest(url: URL(string: raw)!)
            request.setValue("t", forHTTPHeaderField: "X-Plex-Token")
            try PlexTransportSecurity.validate(request)
        }
        for raw in ["ftp://192.168.1.2", "file:///etc/passwd"] {
            var request = URLRequest(url: URL(string: raw)!)
            request.setValue("t", forHTTPHeaderField: "X-Plex-Token")
            #expect(throws: URLError.self) { try PlexTransportSecurity.validate(request) }
        }
    }

    // MARK: Pool: persistence, fast path, failover

    @Test func theChosenConnectionIsPersistedAndRestoredFirst() async throws {
        let stub = SelectionStub.Scope()
        let service = PlexService(urlProtocolClasses: [SelectionStub.self])
        let id = "persist-\(UUID().uuidString.lowercased())"
        defer { tearDown(service, id) }
        let good = stub.host("good", .ok(id))
        let server = try server([connection("https://\(good)", address: good)], id: id, token: "test-token")

        let connection = await service.pool.connect(to: server)
        #expect(connection?.baseURL.host == good)
        #expect(ServerPool.storedBaseURL(serverID: id)?.host == good)
        #expect(ServerPool.restorableBaseURL(serverID: id)?.host == good)
        #expect(service.pool.reports[id]?.chosenURL?.host == good)
    }

    @Test func aPublicHTTPEndpointIsRestoredNow() {
        let id = "restore-\(UUID().uuidString.lowercased())"
        defer { ServerPool.forget(serverID: id) }
        ServerPool.rememberBaseURL(URL(string: "http://plex.example.com:80")!, serverID: id)
        #expect(ServerPool.restorableBaseURL(serverID: id)?.absoluteString == "http://plex.example.com:80")
    }

    /// The fast path goes stale (left the house, endpoint died): the first
    /// request that fails on it re-selects, persists the new endpoint and
    /// retries there — without plex.tv, which is unreachable in this test.
    @Test func aDeadRestoredEndpointFailsOverOnTheFirstRequest() async throws {
        let stub = SelectionStub.Scope()
        let service = PlexService(urlProtocolClasses: [SelectionStub.self])
        let id = "failover-\(UUID().uuidString.lowercased())"
        defer { tearDown(service, id) }
        service.activeAccountToken = "account-token"
        let dead = stub.host("dead", .refuse)
        let alive = stub.host("alive", .ok(id))
        stub.refuse(host: "plex.tv")
        let server = try server([
            connection("http://\(dead):32400", address: "192.168.1.2", local: true),
            connection("https://\(alive)", address: alive),
        ], id: id)
        service.pool.adopt(
            server: server, baseURL: URL(string: "http://\(dead):32400")!, token: "test-token", connection: nil
        )

        let data = try await service.rawServerRequest(path: "/library/sections", serverID: id)
        #expect(String(decoding: data, as: UTF8.self).contains("MediaContainer"))
        #expect(service.pool.connection(for: id)?.baseURL.host == alive)
        #expect(ServerPool.storedBaseURL(serverID: id)?.host == alive)
        #expect(service.pool.reports[id]?.trigger.hasPrefix("Request failed") == true)
    }

    /// Cold launch restored an endpoint that now blackholes (Tailscale off):
    /// the first request must not sit out the 15 s request timeout on it.
    @Test func aBlackholedRestoredEndpointIsValidatedAndReplacedQuickly() async throws {
        let stub = SelectionStub.Scope()
        let service = PlexService(urlProtocolClasses: [SelectionStub.self])
        let id = "restored-\(UUID().uuidString.lowercased())"
        defer { tearDown(service, id) }
        service.activeAccountToken = "account-token"
        stub.hang(host: "100.115.114.92")
        stub.refuse(host: "plex.tv")
        let alive = stub.host("alive", .ok(id))
        let server = try server([
            connection("http://100.115.114.92:10003", address: "100.115.114.92"),
            connection("https://\(alive)", address: alive),
        ], id: id)
        service.pool.adopt(
            server: server, baseURL: URL(string: "http://100.115.114.92:10003")!, token: "test-token",
            connection: nil, verified: false
        )
        #expect(service.pool.connection(for: id)?.isVerified == false)

        let started = Date()
        _ = try await service.rawServerRequest(path: "/library/sections", serverID: id)
        #expect(Date().timeIntervalSince(started) < PlexService.restoredEndpointValidationTimeout + 3)
        #expect(service.pool.connection(for: id)?.baseURL.host == alive)
        #expect(service.pool.connection(for: id)?.isVerified == true)
    }

    @Test func aHealthyRestoredEndpointIsKeptAndMarkedVerified() async throws {
        let stub = SelectionStub.Scope()
        let service = PlexService(urlProtocolClasses: [SelectionStub.self])
        let id = "restored-ok-\(UUID().uuidString.lowercased())"
        defer { tearDown(service, id) }
        let home = stub.host("home", .ok(id))
        let server = try server([connection("https://\(home)", address: home)], id: id)
        service.pool.adopt(
            server: server, baseURL: URL(string: "https://\(home)")!, token: "test-token",
            connection: nil, verified: false
        )
        _ = try await service.rawServerRequest(path: "/library/sections", serverID: id)
        #expect(service.pool.connection(for: id)?.baseURL.host == home)
        #expect(service.pool.connection(for: id)?.isVerified == true)
    }

    /// The owner's setup away from home: LAN, Docker bridge and Tailscale all
    /// dead, the HTTPS reverse proxy alive.
    @Test func awayFromHomeTheRemoteHTTPSProxyWins() async throws {
        let stub = SelectionStub.Scope()
        let service = PlexService(urlProtocolClasses: [SelectionStub.self])
        let id = "away-\(UUID().uuidString.lowercased())"
        defer { tearDown(service, id) }
        let proxy = stub.host("proxy", .ok(id, delay: 0.05))
        stub.hang(host: "172.19.0.11")
        stub.refuse(host: "storage")
        stub.refuse(host: "100.115.114.92")
        let server = try server([
            connection("https://172-19-0-11.abc.plex.direct:32400", address: "172.19.0.11", local: true),
            connection("https://\(proxy):443", address: proxy),
            connection("http://storage:10003", address: "storage"),
            connection("http://100.115.114.92:10003", address: "100.115.114.92"),
        ], id: id, token: "test-token")
        let connection = await service.pool.connect(to: server)
        #expect(connection?.baseURL.host == proxy)
        #expect(connection?.isRemote == true)
    }

    @Test func atHomeTheSameServerStillPrefersHTTPS() async throws {
        let stub = SelectionStub.Scope()
        let service = PlexService(urlProtocolClasses: [SelectionStub.self])
        let id = "home-\(UUID().uuidString.lowercased())"
        defer { tearDown(service, id) }
        let proxy = stub.host("proxy", .ok(id, delay: 0.03))
        stub.answer(host: "storage", .ok(id))
        stub.answer(host: "100.115.114.92", .ok(id))
        let server = try server([
            connection("https://\(proxy):443", address: proxy),
            connection("http://storage:10003", address: "storage"),
            connection("http://100.115.114.92:10003", address: "100.115.114.92"),
        ], id: id, token: "test-token")
        let connection = await service.pool.connect(to: server)
        #expect(connection?.baseURL.host == proxy)
    }

    @Test func onlyHTTPWorksSoHTTPIsUsed() async throws {
        let stub = SelectionStub.Scope()
        let service = PlexService(urlProtocolClasses: [SelectionStub.self])
        let id = "http-only-\(UUID().uuidString.lowercased())"
        defer { tearDown(service, id) }
        let host = stub.host("httponly", .ok(id))
        stub.refuseHTTPS(host: host)
        let server = try server([connection("http://\(host):32400", address: host)], id: id, token: "test-token")
        let connection = await service.pool.connect(to: server)
        #expect(connection?.baseURL.absoluteString == "http://\(host):32400")
        let data = try await service.rawServerRequest(path: "/library/sections", serverID: id)
        #expect(!data.isEmpty)
    }

    // MARK: Helpers

    private func select(
        _ candidates: [ConnectionCandidate],
        session: URLSession,
        grace: Duration = .milliseconds(400),
        waitForAll: Bool = false
    ) async -> ConnectionSelector.Selection {
        await ConnectionSelector.select(
            candidates: candidates, serverID: serverID, serverName: "Test", token: "test-token",
            headers: ["Accept": "application/json"], session: session, trigger: "Test",
            grace: grace, waitForAll: waitForAll
        )
    }

    private func chosenHost(_ selection: ConnectionSelector.Selection) -> String? {
        guard case let .connected(url, _) = selection.resolution else { return nil }
        return url.host
    }

    private func candidate(
        _ raw: String, address: String, local: Bool = false, relay: Bool = false,
        source: ConnectionCandidateSource = .plex
    ) -> ConnectionCandidate {
        ConnectionCandidate(
            baseURL: URL(string: raw)!, connection: connection(raw, address: address, local: local, relay: relay),
            source: source
        )
    }

    private func connection(_ uri: String, address: String, local: Bool = false, relay: Bool = false) -> PlexConnection {
        let url = URL(string: uri)!
        return PlexConnection(protocol: url.scheme!, address: address, port: url.port ?? 443,
                              uri: uri, local: local, relay: relay, iPv6: address.contains(":"))
    }

    private func server(_ connections: [PlexConnection], id: String = UUID().uuidString, token: String? = nil) throws -> PlexServer {
        var object: [String: Any] = ["name": "Test", "clientIdentifier": id, "owned": true]
        if let token { object["accessToken"] = token }
        object["connections"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(connections))
        return try JSONDecoder().decode(PlexServer.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func tearDown(_ service: PlexService, _ id: String) {
        ServerPool.forget(serverID: id)
        service.session.invalidateAndCancel()
        service.slowQuerySession.invalidateAndCancel()
        service.probeSession.invalidateAndCancel()
    }
}

/// Scripted hosts. Unknown hosts are refused, so nothing ever leaves the Mac.
final class SelectionStub: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable {
        case ok(String, delay: TimeInterval = 0)
        case unauthorized(String)
        case html
        case refuse
        case hang
        case redirect(String)
    }

    struct Seen: Sendable { let url: URL; let token: String? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var behaviors: [String: Behavior] = [:]
    nonisolated(unsafe) private static var httpsRefused: Set<String> = []
    nonisolated(unsafe) private static var seen: [Seen] = []

    /// Registers hosts for one test and removes them again when it ends.
    final class Scope {
        private var hosts: [String] = []
        let session: URLSession

        init() {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SelectionStub.self]
            session = URLSession(configuration: configuration, delegate: PlexTransportSessionDelegate(), delegateQueue: nil)
        }

        deinit {
            session.invalidateAndCancel()
            SelectionStub.lock.withLock {
                for host in hosts {
                    SelectionStub.behaviors[host] = nil
                    SelectionStub.httpsRefused.remove(host)
                }
            }
        }

        func host(_ prefix: String, _ behavior: Behavior) -> String {
            let host = "\(prefix)-\(UUID().uuidString.prefix(8).lowercased()).invalid"
            answer(host: host, behavior)
            return host
        }

        func answer(host: String, _ behavior: Behavior) {
            hosts.append(host)
            SelectionStub.lock.withLock { SelectionStub.behaviors[host] = behavior }
        }

        func refuse(host: String) { answer(host: host, .refuse) }
        func hang(host: String) { answer(host: host, .hang) }
        func refuseHTTPS(host: String) {
            SelectionStub.lock.withLock { _ = SelectionStub.httpsRefused.insert(host) }
        }
    }

    static func requests(host: String) -> [Seen] {
        lock.withLock { seen.filter { $0.url.host == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var pending: DispatchWorkItem?

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let (behavior, refusesHTTPS) = Self.lock.withLock { () -> (Behavior?, Bool) in
            Self.seen.append(Seen(url: url, token: request.value(forHTTPHeaderField: "X-Plex-Token")))
            return (Self.behaviors[host], Self.httpsRefused.contains(host))
        }
        if refusesHTTPS, url.scheme == "https" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch behavior {
        case .none, .refuse:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .hang:
            return
        case let .redirect(target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target])!
            var next = URLRequest(url: URL(string: target)!)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .html:
            respond(url, 200, "<html>captive portal</html>")
        case let .unauthorized(id):
            if url.path == "/identity" {
                respond(url, 200, #"{"MediaContainer":{"machineIdentifier":"\#(id)"}}"#)
            } else {
                respond(url, 401, "")
            }
        case let .ok(id, delay):
            let body = url.path == "/identity"
                ? #"{"MediaContainer":{"machineIdentifier":"\#(id)"}}"#
                : #"{"MediaContainer":{"size":0}}"#
            guard delay > 0 else { return respond(url, 200, body) }
            let work = DispatchWorkItem { [weak self] in self?.respond(url, 200, body) }
            pending = work
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func respond(_ url: URL, _ status: Int, _ body: String) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        pending?.cancel()
    }
}
