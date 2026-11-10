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
        // Tailscale (#36 regression): CGNAT/tailnet IPs, MagicDNS names.
        "http://100.64.0.1", "http://100.115.114.92:10003", "http://100.127.255.254",
        "http://[fd7a:115c:a1e0::1]", "http://[::ffff:100.115.114.92]",
        "http://100-115-114-92.abc.plex.direct:10003",
        "http://storage:10003", "http://STORAGE", "http://my-nas",
        "http://storage.tail1234.ts.net:10003",
    ])
    func secureAndLocalDestinationsKeepTheirTokens(_ raw: String) throws {
        var request = URLRequest(url: try #require(URL(string: raw)))
        request.setValue("test-token", forHTTPHeaderField: "X-Plex-Token")
        try PlexTransportSecurity.validate(request)
        #expect(PlexTransportSecurity.authenticatedURL(request.url) == request.url)
    }

    /// Since the owner's HTTP clarification (after d4c46f5) plain HTTP is a
    /// normal transport: the token goes wherever the selected endpoint is.
    @Test(arguments: [
        "http://public.example:32400", "http://8.8.8.8", "http://[2001:db8::1]",
        "http://plex.mvr.example", "http://134744072",
    ])
    func publicHTTPDestinationsAreAllowedNow(_ raw: String) throws {
        var request = URLRequest(url: try #require(URL(string: raw)))
        request.setValue("test-token", forHTTPHeaderField: "X-Plex-Token")
        try PlexTransportSecurity.validate(request)
        #expect(PlexTransportSecurity.authenticatedURL(request.url) == request.url)
    }

    @Test(arguments: ["ftp://192.168.1.2", "file:///tmp/x", "plex://server"])
    func nonHTTPDestinationsRejectHeaderQueryAndBodyCredentials(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        var header = URLRequest(url: url)
        header.setValue("test-token", forHTTPHeaderField: "x-pLeX-tOkEn")
        #expect(throws: URLError.self) { try PlexTransportSecurity.validate(header) }
        var body = URLRequest(url: url)
        body.httpBody = Data(#"{"authToken":"test-token"}"#.utf8)
        #expect(throws: URLError.self) { try PlexTransportSecurity.validate(body) }
        #expect(PlexTransportSecurity.authenticatedURL(url) == nil)
    }

    @Test func publicArtworkWithoutCredentialsCanStillLoad() throws {
        try PlexTransportSecurity.validate(URLRequest(url: URL(string: "http://artwork.example/poster.jpg")!))
    }

    @Test func tailscaleConnectionsAreCandidates() throws {
        let server = try server([
            connection("http://172.17.0.2:32400", address: "172.17.0.2", local: true),
            connection("http://100.115.114.92:10003", address: "100.115.114.92"),
            connection("http://storage:10003", address: "storage"),
            connection("http://storage.tail1234.ts.net:10003", address: "storage.tail1234.ts.net"),
            connection("https://100-115-114-92.abc.plex.direct:10003", address: "100.115.114.92"),
        ])
        let candidates = ServerPool.connectionCandidates(for: server)
        let urls = candidates.map(\.baseURL.absoluteString)
        for expected in [
            "http://100.115.114.92:10003", "http://storage:10003", "http://storage.tail1234.ts.net:10003",
            "https://100-115-114-92.abc.plex.direct:10003",
        ] {
            #expect(urls.contains(expected), "\(expected)")
        }
        #expect(candidates.filter { $0.baseURL.host?.contains("100") == true || $0.baseURL.host?.contains("storage") == true }
            .allSatisfy { $0.locality == .tailnet })
    }

    @Test func identityParsingAcceptsJSONAndXMLOnly() {
        #expect(ConnectionSelector.identityMachineIdentifier(in: Data(#"{"MediaContainer":{"machineIdentifier":"abc"}}"#.utf8)) == "abc")
        #expect(ConnectionSelector.identityMachineIdentifier(in: Data(#"<MediaContainer size="0" machineIdentifier="abc" version="1"/>"#.utf8)) == "abc")
        #expect(ConnectionSelector.identityMachineIdentifier(in: Data("machineIdentifier=\"abc\"".utf8)) == nil)
        #expect(ConnectionSelector.identityMachineIdentifier(in: Data(#"{"MediaContainer":{}}"#.utf8)) == nil)
        #expect(ConnectionSelector.identityMachineIdentifier(in: Data("<html>hi</html>".utf8)) == nil)
        #expect(ConnectionSelector.identityMachineIdentifier(in: Data()) == nil)
    }

    @Test func plexDirectHTTPSConnectionsGetARawAddressHTTPFallback() {
        let tailnet = connection("https://100-115-114-92.abc.plex.direct:32400", address: "100.115.114.92")
        #expect(tailnet.httpFallbackURI == "http://100.115.114.92:32400")
        let named = connection("https://100-115-114-92.abc.plex.direct:32400", address: "plex.example.com")
        #expect(named.httpFallbackURI == "http://100.115.114.92:32400")
        let wan = connection("https://84-73-1-2.abc.plex.direct:32400", address: "84.73.1.2")
        #expect(wan.httpFallbackURI == "http://84.73.1.2:32400")
        let v6 = connection("https://fd00-0-0-0-0-0-0-1.abc.plex.direct:32400", address: "fd00::1")
        #expect(v6.httpFallbackURI == "http://[fd00:0:0:0:0:0:0:1]:32400")
        #expect(connection("https://plex.example.com:443", address: "plex.example.com").httpFallbackURI == nil)
        #expect(connection("https://10-0-0-999.abc.plex.direct", address: "x").httpFallbackURI == nil)
    }

    @Test func backgroundTransfersRejectNonHTTPRequestsBeforeCreatingATask() {
        let controller = DownloadTransferController { _ in }
        var request = URLRequest(url: URL(string: "ftp://public.example/video")!)
        request.setValue("test-token", forHTTPHeaderField: "X-Plex-Token")
        #expect(throws: URLError.self) {
            try controller.start(request: request, resumeData: nil, globalKey: "transport-test")
        }
    }

    @Test func publicHTTPEndpointsBuildAuthenticatedURLs() throws {
        let service = PlexService(urlProtocolClasses: [TransportStubProtocol.self])
        defer { service.session.invalidateAndCancel(); service.slowQuerySession.invalidateAndCancel() }
        let id = "transport-test-\(UUID())"
        defer { ServerPool.forget(serverID: id) }
        let server = try server([], id: id)
        let part = try JSONDecoder().decode(PlexMediaPart.self, from: Data(#"{"id":1,"key":"/video.mp4"}"#.utf8))
        for raw in ["http://public.example:32400", "http://192.168.1.2:32400", "https://public.example:32400"] {
            service.pool.adopt(server: server, baseURL: URL(string: raw)!, token: "test-token", connection: nil)
            #expect(service.directPlayURL(for: part, serverID: id) != nil)
            #expect(service.imageRequestURLString(for: "/poster", includeToken: true, serverID: id) != nil)
        }
    }

    @Test func redirectsKeepTheOriginalCredentialRequirementEvenAfterHeadersAreDropped() {
        var original = URLRequest(url: URL(string: "https://public.example/identity")!)
        original.setValue("test-token", forHTTPHeaderField: "X-Plex-Token")
        for raw in ["http://public.example/identity", "https://other.example/identity", "http://192.168.1.2"] {
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
        #expect(PlexTransportSecurity.allowsRedirect(URLRequest(url: URL(string: "https://public.example/web")!), original: original))
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

