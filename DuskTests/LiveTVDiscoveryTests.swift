import Foundation
import Testing
@testable import Dusk

/// Live TV must show whenever a connected server has a DVR. 1.7.2 (4) hid the
/// tab for the whole session after one slow or failed `/media/providers`.
@MainActor
@Suite("Live TV discovery", .timeLimit(.minutes(1)))
struct LiveTVDiscoveryTests {
    // MARK: - Classifying a pass

    @Test func dvrOnAnyServerWinsOverServersThatFailed() {
        let result = LiveTVDiscovery(
            serverIDs: ["a", "b"],
            results: ["a": .failure(PlexServiceError.requestTimedOut), "b": .success(provider(on: "b"))]
        )
        guard case .found(let found) = result else {
            Issue.record("Expected the DVR on b, got \(result)")
            return
        }
        #expect(found.serverID == "b")
    }

    @Test func highestPriorityDVRWins() {
        let result = LiveTVDiscovery(
            serverIDs: ["a", "b"],
            results: ["a": .success(provider(on: "a")), "b": .success(provider(on: "b"))]
        )
        guard case .found(let found) = result else {
            Issue.record("Expected a DVR, got \(result)")
            return
        }
        #expect(found.serverID == "a")
    }

    @Test func aFailedServerIsNotAServerWithoutLiveTV() {
        for error in [
            PlexServiceError.requestTimedOut,
            .httpError(statusCode: 500),
            .httpError(statusCode: 503),
            .noServerConnected,
            .authenticationPending,
            .networkError("cancelled"),
        ] {
            let result = LiveTVDiscovery(
                serverIDs: ["a", "b"],
                results: ["a": .success(nil), "b": .failure(error)]
            )
            guard case .inconclusive = result else {
                Issue.record("\(error) must be retried, got \(result)")
                continue
            }
        }
        let unanswered = LiveTVDiscovery(serverIDs: ["a", "b"], results: ["a": .success(nil)])
        guard case .inconclusive = unanswered else {
            Issue.record("A server with no answer must be retried, got \(unanswered)")
            return
        }
    }

    @Test func definitiveAnswersEndDiscovery() {
        for error in [
            PlexServiceError.unauthorized,
            .httpError(statusCode: 401),
            .httpError(statusCode: 403),
            .httpError(statusCode: 404),
            .decodingError("bad"),
        ] {
            let result = LiveTVDiscovery(
                serverIDs: ["a", "b"],
                results: ["a": .success(nil), "b": .failure(error)]
            )
            guard case .none = result else {
                Issue.record("\(error) means no Live TV there, got \(result)")
                continue
            }
        }
    }

    // MARK: - Through PlexService and the view model

    @Test func slowFirstProvidersAnswerStillShowsLiveTV() async throws {
        let stub = StubServers()
        let dvr = stub.server()
        stub.reply(dvr, "/media/providers", [.error(.timedOut), .json(Fixture.providersWithDVR)])
        let (service, viewModel) = makeViewModel(stub, servers: [dvr])
        defer { stub.tearDown(service) }

        await viewModel.discover()

        #expect(viewModel.isAvailable)
        #expect(viewModel.provider?.serverID == dvr.id)
        #expect(stub.requests(dvr, "/media/providers").count == 2)
    }

    @Test func transientServerErrorStillShowsLiveTV() async throws {
        let stub = StubServers()
        let dvr = stub.server()
        stub.reply(dvr, "/media/providers", [.status(500), .status(503), .json(Fixture.providersWithDVR)])
        let (service, viewModel) = makeViewModel(stub, servers: [dvr])
        defer { stub.tearDown(service) }

        await viewModel.discover()

        #expect(viewModel.isAvailable)
        #expect(stub.requests(dvr, "/media/providers").count == 3)
    }

    @Test func dvrOnSecondServerWhileFirstHasNone() async throws {
        let stub = StubServers()
        let libraries = stub.server()
        let dvr = stub.server()
        stub.reply(libraries, "/media/providers", [.json(Fixture.providersWithoutDVR)])
        stub.reply(dvr, "/media/providers", [.status(500), .json(Fixture.providersWithDVR)])
        let (service, viewModel) = makeViewModel(stub, servers: [libraries, dvr])
        defer { stub.tearDown(service) }

        await viewModel.discover()

        #expect(viewModel.isAvailable)
        #expect(viewModel.provider?.serverID == dvr.id)
    }

    @Test func noDVRAnywhereEndsWithoutRetrying() async throws {
        let stub = StubServers()
        let first = stub.server()
        let second = stub.server()
        stub.reply(first, "/media/providers", [.json(Fixture.providersWithoutDVR)])
        stub.reply(second, "/media/providers", [.status(403)])
        let (service, viewModel) = makeViewModel(stub, servers: [first, second])
        defer { stub.tearDown(service) }

        await viewModel.discover()

        #expect(!viewModel.isAvailable)
        #expect(stub.requests(first, "/media/providers").count == 1)
        #expect(stub.requests(second, "/media/providers").count == 1)
    }

    @Test func aFoundDVRSurvivesLaterFailures() async throws {
        let stub = StubServers()
        let dvr = stub.server()
        stub.reply(dvr, "/media/providers", [.json(Fixture.providersWithDVR), .status(500)])
        let (service, viewModel) = makeViewModel(stub, servers: [dvr])
        defer { stub.tearDown(service) }

        await viewModel.discover()
        await viewModel.discover()

        #expect(viewModel.isAvailable)
        #expect(stub.requests(dvr, "/media/providers").count == 1)
    }

    @Test func homeShelfDiscoversTheDVRItself() async throws {
        let stub = StubServers()
        let dvr = stub.server()
        stub.reply(dvr, "/media/providers", [.json(Fixture.providersWithDVR)])
        stub.reply(dvr, "/tv.plex.providers.epg.cloud:9/lineups/dvr/channels", [.json(Fixture.channels)])
        stub.reply(dvr, "/tv.plex.providers.epg.cloud:9/watchnow/all", [.json(Fixture.emptyMetadata)])
        let (service, viewModel) = makeViewModel(stub, servers: [dvr])
        defer { stub.tearDown(service) }

        await viewModel.loadNowPlaying(force: true)

        #expect(viewModel.isAvailable)
        #expect(viewModel.nowPlayingLineup?.channels.count == 1)
    }

    @Test func discoveryHasItsOwnTimeoutBudget() async throws {
        let stub = StubServers()
        let dvr = stub.server()
        stub.reply(dvr, "/media/providers", [.json(Fixture.providersWithDVR)])
        let (service, viewModel) = makeViewModel(stub, servers: [dvr])
        defer { stub.tearDown(service) }

        await viewModel.discover()

        // Above the shared session's budget, so it runs on `slowQuerySession`
        // (its own connections) and cannot queue behind Home's slow reads.
        let request = try #require(stub.requests(dvr, "/media/providers").first)
        #expect(request.timeoutInterval == PlexService.liveTVDiscoveryTimeout)
        #expect(PlexService.liveTVDiscoveryTimeout > PlexService.requestResourceTimeout)
    }

    @Test func anUnreachableServerDoesNotHoldLiveTVBack() async throws {
        let stub = StubServers()
        let unreachable = stub.server()
        let dvr = stub.server()
        stub.reply(unreachable, "/media/providers", [.hang])
        stub.reply(dvr, "/media/providers", [.json(Fixture.providersWithDVR)])
        // Higher priority than the DVR server, so discovery waits out its grace.
        let (service, viewModel) = makeViewModel(stub, servers: [unreachable, dvr])
        defer { stub.tearDown(service) }

        let elapsed = await ContinuousClock().measure {
            await viewModel.discover()
        }

        #expect(viewModel.provider?.serverID == dvr.id)
        #expect(elapsed < .seconds(10))
    }

    // MARK: - Helpers

    private func provider(on serverID: String) -> PlexLiveTVProvider {
        PlexLiveTVProvider(
            identifier: "tv.plex.providers.epg.cloud:9",
            providerIdentifier: "tv.plex.providers.epg.cloud",
            title: "Live TV & DVR",
            dvrID: 9,
            gridKey: "/tv.plex.providers.epg.cloud:9/grid"
        ).on(serverID: serverID)
    }

    private func makeViewModel(
        _ stub: StubServers,
        servers: [StubServers.Server]
    ) -> (PlexService, LiveTVViewModel) {
        let service = PlexService(urlProtocolClasses: [StubURLProtocol.self])
        // The test host restores its own last-launch sessions; only the stub
        // servers may take part.
        for serverID in service.pool.connections.map(\.serverID) {
            service.pool.markOffline(serverID: serverID, reason: "Not part of this test")
        }
        for server in servers {
            service.pool.adopt(
                server: server.plexServer,
                baseURL: server.baseURL,
                token: "token-\(server.id)",
                connection: nil
            )
        }
        return (service, LiveTVViewModel(plexService: service, discoveryRetryDelay: .milliseconds(10)))
    }
}

private enum Fixture {
    static let providersWithoutDVR = Data("""
    {"MediaContainer":{"size":1,"MediaProvider":[
      {"identifier":"com.plexapp.plugins.library","title":"Library","types":"video,audio,photo","protocols":"stream,download",
       "Feature":[{"type":"content","key":"/library/sections"},{"type":"manage"}]}
    ]}}
    """.utf8)

    // Shape of a real PMS answer (plex-demo, PMS 1.43.5), with a cloud guide.
    static let providersWithDVR = Data("""
    {"MediaContainer":{"size":2,"MediaProvider":[
      {"identifier":"com.plexapp.plugins.library","title":"Library","types":"video,audio,photo","protocols":"stream,download",
       "Feature":[{"type":"content","key":"/library/sections"},{"type":"manage"}]},
      {"id":10,"parentID":9,"identifier":"tv.plex.providers.epg.cloud:9","providerIdentifier":"tv.plex.providers.epg.cloud",
       "title":"Live TV & DVR","types":"video","protocols":"livetv","epgSource":"Plex","friendlyName":"Home",
       "Feature":[{"type":"content","key":"/tv.plex.providers.epg.cloud:9/sections"},
                  {"type":"grid","key":"/tv.plex.providers.epg.cloud:9/grid"},{"type":"subscribe"}]}
    ]}}
    """.utf8)

    static let channels = Data("""
    {"MediaContainer":{"size":1,"Channel":[
      {"id":"5001","gridKey":"5001","vcn":"3.1","title":"Test One","callSign":"TEST1","isHd":"1"}
    ]}}
    """.utf8)

    static let emptyMetadata = Data(#"{"MediaContainer":{"size":0}}"#.utf8)
}

/// Fake Plex servers, one host each, so suites running in parallel never share
/// replies.
@MainActor
private final class StubServers {
    struct Server {
        let id: String
        let baseURL: URL

        var plexServer: PlexServer {
            let json = """
            {"name":"\(id)","clientIdentifier":"\(id)","provides":"server","owned":true,"presence":true,"connections":[]}
            """
            return try! JSONDecoder().decode(PlexServer.self, from: Data(json.utf8))
        }
    }

    private var hosts: [String] = []

    func server() -> Server {
        let id = "livetv-test-\(UUID().uuidString.lowercased())"
        let host = "\(id).invalid"
        hosts.append(host)
        return Server(id: id, baseURL: URL(string: "http://\(host):32400")!)
    }

    /// Replies are used in order; the last one repeats.
    func reply(_ server: Server, _ path: String, _ replies: [StubURLProtocol.Reply]) {
        StubURLProtocol.set(replies, host: server.baseURL.host!, path: path)
    }

    func requests(_ server: Server, _ path: String) -> [URLRequest] {
        StubURLProtocol.requests(host: server.baseURL.host!).filter { $0.url?.path == path }
    }

    func tearDown(_ service: PlexService) {
        for host in hosts {
            StubURLProtocol.remove(host: host)
            ServerPool.forget(serverID: host.replacingOccurrences(of: ".invalid", with: ""))
        }
        service.session.invalidateAndCancel()
        service.slowQuerySession.invalidateAndCancel()
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case json(Data)
        case status(Int)
        case error(URLError.Code)
        /// Never answers, like a server that stopped responding.
        case hang
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var log: [String: [URLRequest]] = [:]

    static func set(_ replies: [Reply], host: String, path: String) {
        lock.withLock { self.replies["\(host)\(path)"] = replies }
    }

    static func requests(host: String) -> [URLRequest] {
        lock.withLock { log[host] ?? [] }
    }

    static func remove(host: String) {
        lock.withLock {
            log[host] = nil
            replies = replies.filter { !$0.key.hasPrefix(host) }
        }
    }

    private static func next(for request: URLRequest) -> Reply {
        let host = request.url?.host ?? ""
        let key = host + (request.url?.path ?? "")
        return lock.withLock {
            log[host, default: []].append(request)
            guard var queue = replies[key], let reply = queue.first else { return .status(404) }
            if queue.count > 1 {
                queue.removeFirst()
                replies[key] = queue
            }
            return reply
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasPrefix("livetv-test-") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.next(for: request) {
        case .json(let data):
            respond(status: 200, data: data)
        case .status(let status):
            respond(status: status, data: Data())
        case .error(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, data: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
