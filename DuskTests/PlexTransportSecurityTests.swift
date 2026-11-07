import Foundation
import Testing
@testable import Dusk

@Suite("Plex credential transport", .serialized)
@MainActor
struct PlexTransportSecurityTests {
    @Test(arguments: [
        "http://10.0.0.5:32400", "http://172.16.0.1", "http://172.31.255.255",
        "http://192.168.1.2", "http://127.0.0.1", "http://169.254.1.2",
        "http://[::1]", "http://[0:0:0:0:0:0:0:1]", "http://[fd12::1]",
        "http://[fc00::1]", "http://[fe80::1]", "http://[::ffff:192.168.1.2]",
        "http://localhost", "http://plex.local",
        "http://192-168-1-2.abc.plex.direct:32400",
        "http://fd00-0-0-0-0-0-0-1.abc.plex.direct:32400",
        "https://public.example:32400",
    ])
    func secureAndLocalDestinationsKeepTheirTokens(_ raw: String) throws {
        var request = URLRequest(url: try #require(URL(string: raw)))
        request.setValue("test-token", forHTTPHeaderField: "X-Plex-Token")
        try PlexTransportSecurity.validate(request)
        #expect(PlexTransportSecurity.authenticatedURL(request.url) == request.url)
    }

    @Test(arguments: [
        "http://public.example:32400", "http://8.8.8.8", "http://172.32.0.1",
        "http://100.64.0.1", "http://[2001:db8::1]", "http://[::ffff:8.8.8.8]",
        "http://8-8-8-8.abc.plex.direct", "http://192-168-1-2.abc.plex.direct.evil.example",
        "http://10-0-0-999.abc.plex.direct", "http://10-0-0-1-extra.abc.plex.direct",
        "http://localhost.evil.example", "ftp://192.168.1.2",
    ])
    func unsafeDestinationsRejectHeaderQueryAndBodyCredentials(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        var header = URLRequest(url: url)
        header.setValue("test-token", forHTTPHeaderField: "x-pLeX-tOkEn")
        #expect(throws: URLError.self) { try PlexTransportSecurity.validate(header) }
        var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.percentEncodedQuery = "x%2DPlex%2DToken=test-token"
        let query = URLRequest(url: try #require(components.url))
        #expect(throws: URLError.self) { try PlexTransportSecurity.validate(query) }
        var body = URLRequest(url: url)
        body.httpBody = Data(#"{"authToken":"test-token"}"#.utf8)
        #expect(throws: URLError.self) { try PlexTransportSecurity.validate(body) }
        #expect(PlexTransportSecurity.authenticatedURL(url) == nil)
    }

    @Test func publicArtworkWithoutCredentialsCanStillLoad() throws {
        try PlexTransportSecurity.validate(URLRequest(url: URL(string: "http://artwork.example/poster.jpg")!))
    }

    @Test func onlyLocalConnectionsGenerateHTTPFallbacks() throws {
        let server = try server([
            connection("https://8-8-8-8.abc.plex.direct:32400", address: "8.8.8.8"),
            connection("http://public.example:32400", address: "public.example", local: true),
            connection("https://192-168-1-2.abc.plex.direct:32400", address: "192.168.1.2"),
            connection("https://172-20-0-3.abc.plex.direct:32400", address: "custom.example"),
        ])
        let urls = ServerPool.connectionCandidates(for: server).map(\.baseURL.absoluteString)
        #expect(urls.contains("https://8-8-8-8.abc.plex.direct:32400"))
        #expect(!urls.contains { $0.hasPrefix("http://8") || $0.hasPrefix("http://public") })
        #expect(urls.contains("http://192.168.1.2:32400"))
        #expect(urls.contains("http://172-20-0-3.abc.plex.direct:32400"))
        #expect(urls.allSatisfy { PlexTransportSecurity.allowsToken(in: URL(string: $0)!) })
    }

    @Test func localityMetadataCannotOverrideTheActualRequestHost() throws {
        let advertised = connection("http://public.example:32400", address: "192.168.1.2", local: true)
        let candidate = ConnectionCandidate(
            baseURL: URL(string: advertised.uri)!,
            probeURL: URL(string: advertised.uri + "/identity")!, connection: advertised
        )
        #expect(ServerProbe.makePlans(candidates: [candidate], headers: ["X-Plex-Token": "test-token"]).isEmpty)
        let local = connection("http://192.168.1.2:32400", address: "192.168.1.2")
        let localCandidate = ConnectionCandidate(
            baseURL: URL(string: local.uri)!, probeURL: URL(string: local.uri + "/identity")!, connection: local
        )
        let plans = ServerProbe.makePlans(candidates: [localCandidate], headers: ["X-Plex-Token": "test-token"])
        #expect(plans.count == 1)
        #expect(plans.first?.probeRequest.value(forHTTPHeaderField: "X-Plex-Token") == "test-token")
        #expect(plans.first?.validationRequest.value(forHTTPHeaderField: "X-Plex-Token") == "test-token")
    }

    @Test func handBuiltUnsafeProbePlansNeverReachTheNetwork() async {
        let service = PlexService(urlProtocolClasses: [TransportStubProtocol.self])
        defer { service.session.invalidateAndCancel(); service.slowQuerySession.invalidateAndCancel() }
        let url = URL(string: "http://public.example:32400")!
        var request = URLRequest(url: url)
        request.setValue("test-token", forHTTPHeaderField: "X-Plex-Token")
        let plan = ServerProbe.Plan(
            index: 0, baseURL: url, connection: connection(url.absoluteString, address: "192.168.1.2", local: true),
            probeRequest: request, validationRequest: request
        )
        let result = await ServerProbe.resolve(plans: [plan], serverName: "Test", session: service.session)
        guard case .failed = result else {
            Issue.record("Unsafe probe should fail before transmission")
            return
        }
    }

    @Test func executorAndArtworkRejectUnsafeRequestsBeforeTransmission() async throws {
        let service = PlexService(urlProtocolClasses: [TransportStubProtocol.self])
        defer { service.session.invalidateAndCancel(); service.slowQuerySession.invalidateAndCancel() }
        let url = URL(string: "http://public.example/poster?X-Plex-Token=test-token")!
        await #expect(throws: URLError.self) { try await service.executeRequest(URLRequest(url: url)) }
        await #expect(throws: URLError.self) { try await service.imageData(for: url) }
        var request = URLRequest(url: URL(string: "http://192.168.1.2/identity")!)
        service.applyHeaders(to: &request, token: "test-token")
        let data = try await service.executeRequest(request)
        #expect(String(decoding: data, as: UTF8.self) == "LAN works")
    }

    @Test func backgroundTransfersRejectUnsafeRequestsBeforeCreatingATask() {
        let controller = DownloadTransferController { _ in }
        let request = URLRequest(url: URL(string: "http://public.example/video?X-Plex-Token=test-token")!)
        #expect(throws: URLError.self) {
            try controller.start(request: request, resumeData: nil, globalKey: "transport-test")
        }
    }

    @Test func localProbeStillAuthenticatesBothRequests() async throws {
        let service = PlexService(urlProtocolClasses: [TransportStubProtocol.self])
        defer { service.session.invalidateAndCancel(); service.slowQuerySession.invalidateAndCancel() }
        let server = try server([connection("http://192.168.1.2:32400", address: "192.168.1.2")])
        let plans = ServerProbe.makePlans(
            candidates: ServerPool.connectionCandidates(for: server), headers: ["X-Plex-Token": "test-token"]
        )
        let result = await ServerProbe.resolve(plans: plans, serverName: "LAN", session: service.session)
        guard case .connected = result else {
            Issue.record("Private HTTP probe and authorization check should still succeed")
            return
        }
    }

    @Test func restoredPublicHTTPEndpointsCannotBuildAuthenticatedURLs() throws {
        let service = PlexService(urlProtocolClasses: [TransportStubProtocol.self])
        defer { service.session.invalidateAndCancel(); service.slowQuerySession.invalidateAndCancel() }
        let id = "transport-test-\(UUID())"
        let server = try server([], id: id)
        let part = try JSONDecoder().decode(PlexMediaPart.self, from: Data(#"{"id":1,"key":"/video.mp4"}"#.utf8))
        let subtitle = try JSONDecoder().decode(PlexStream.self, from: Data(#"{"id":2,"streamType":3,"key":"/subtitle.srt","codec":"srt"}"#.utf8))
        for raw in ["http://public.example:32400", "http://192.168.1.2:32400", "https://public.example:32400"] {
            let base = URL(string: raw)!
            service.pool.adopt(server: server, baseURL: base, token: "test-token", connection: nil)
            let allowed = PlexTransportSecurity.allowsToken(in: base)
            #expect((service.externalSubtitleURL(for: subtitle, serverID: id) != nil) == allowed)
            #expect((service.directPlayURL(for: part, serverID: id) != nil) == allowed)
            #expect((service.imageRequestURLString(for: "/poster", includeToken: true, serverID: id) != nil) == allowed)
            #expect((service.transcodedImageURL(for: "/poster", size: ImageRequestSize(width: 100, height: 100), serverID: id) != nil) == allowed)
            #expect((service.buildURL(base: raw, path: "/video/:/transcode/universal/start.m3u8", queryItems: [URLQueryItem(name: "X-Plex-Token", value: "test-token")]) != nil) == allowed)
        }
    }

    @Test func redirectsKeepTheOriginalCredentialRequirementEvenAfterHeadersAreDropped() {
        var original = URLRequest(url: URL(string: "https://public.example/identity")!)
        original.setValue("test-token", forHTTPHeaderField: "X-Plex-Token")
        for raw in ["http://public.example/identity", "http://8.8.8.8/identity"] {
            let redirect = URLRequest(url: URL(string: raw)!)
            #expect(!PlexTransportSecurity.allowsRedirect(redirect, original: original))
            let task = PlexTransportSecurity.session.dataTask(with: original)
            let response = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
            PlexTransportSessionDelegate().urlSession(
                PlexTransportSecurity.session, task: task, willPerformHTTPRedirection: response,
                newRequest: redirect
            ) { request in
                #expect(request == nil)
            }
            task.cancel()
        }
        #expect(PlexTransportSecurity.allowsRedirect(URLRequest(url: URL(string: "https://other.example")!), original: original))
        #expect(PlexTransportSecurity.allowsRedirect(URLRequest(url: URL(string: "http://192.168.1.2")!), original: original))
    }

    private func connection(_ uri: String, address: String, local: Bool = false) -> PlexConnection {
        let url = URL(string: uri)!
        return PlexConnection(protocol: url.scheme!, address: address, port: url.port ?? 32400,
                              uri: uri, local: local, relay: false, iPv6: address.contains(":"))
    }

    private func server(_ connections: [PlexConnection], id: String = UUID().uuidString) throws -> PlexServer {
        var object: [String: Any] = ["name": "Test", "clientIdentifier": id]
        object["connections"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(connections))
        return try JSONDecoder().decode(PlexServer.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

/// This protocol never opens a socket, including on a regression. Any unsafe
/// transmission is a test failure rather than an actual credential disclosure.
private final class TransportStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if (try? PlexTransportSecurity.validate(request)) == nil {
            Issue.record("A credential-bearing public HTTP request reached URLSession")
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("LAN works".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
