import Darwin
import Foundation
import Testing
@testable import Dusk

@Suite("Seerr URL normalisation")
struct SeerrServerURLTests {
    @Test func ipAndPortDefaultToHTTP() throws {
        let urls = try SeerrServerURL.candidates(from: "  192.168.1.10:5055  ")
        #expect(urls.map(\.absoluteString) == ["http://192.168.1.10:5055"])
    }

    @Test func bareIPDefaultsToHTTP() throws {
        let urls = try SeerrServerURL.candidates(from: "10.0.0.200")
        #expect(urls.map(\.absoluteString) == ["http://10.0.0.200"])
    }

    @Test func explicitSchemesKeepThePort() throws {
        #expect(try absolute("http://192.168.1.10:5055") == "http://192.168.1.10:5055")
        #expect(try absolute("https://192.168.1.10:5055") == "https://192.168.1.10:5055")
        #expect(try absolute("HTTP://192.168.1.10:5055/") == "http://192.168.1.10:5055")
    }

    @Test func trailingSlashAndAPISuffixAreRemoved() throws {
        #expect(try absolute("http://192.168.1.10:5055/") == "http://192.168.1.10:5055")
        #expect(try absolute("http://192.168.1.10:5055/api/v1") == "http://192.168.1.10:5055")
        #expect(try absolute("http://192.168.1.10:5055/api/v1/") == "http://192.168.1.10:5055")
        #expect(try absolute("http://192.168.1.10:5055/API/V1/") == "http://192.168.1.10:5055")
    }

    @Test func reverseProxyBasePathIsKept() throws {
        #expect(try absolute("http://192.168.1.10:5055/seerr") == "http://192.168.1.10:5055/seerr")
        #expect(try absolute("http://192.168.1.10:5055/seerr/") == "http://192.168.1.10:5055/seerr")
        #expect(try absolute("http://192.168.1.10:5055/seerr/api/v1") == "http://192.168.1.10:5055/seerr")
        #expect(try absolute("http://192.168.1.10/seerr/api/v1/?x=1#frag") == "http://192.168.1.10/seerr")
    }

    @Test func schemelessBasePathKeepsThePort() throws {
        #expect(try absolute("192.168.1.10:5055/seerr/") == "http://192.168.1.10:5055/seerr")
    }

    @Test func publicHostnamesTryHTTPSThenHTTP() throws {
        let urls = try SeerrServerURL.candidates(from: "Example.COM")
        #expect(urls.map(\.absoluteString) == ["https://example.com", "http://example.com"])
        #expect(try absolute("https://requests.example.com:8443/seerr/api/v1/") == "https://requests.example.com:8443/seerr")
    }

    @Test func localNamesDefaultToHTTP() throws {
        #expect(try absolute("seerr.local:5055") == "http://seerr.local:5055")
        #expect(try absolute("localhost:5055") == "http://localhost:5055")
        #expect(try absolute("overseerr") == "http://overseerr")
        #expect(try absolute("seerr.lan") == "http://seerr.lan")
        #expect(try absolute("seerr.home") == "http://seerr.home")
        #expect(try absolute("seerr.internal") == "http://seerr.internal")
    }

    @Test func ipv6KeepsBracketsAndPort() throws {
        #expect(try absolute("[2001:db8::1]:5055") == "http://[2001:db8::1]:5055")
        #expect(try absolute("http://[2001:DB8::1]:5055/seerr/api/v1/") == "http://[2001:db8::1]:5055/seerr")
        #expect(try absolute("::1") == "http://[::1]")
        #expect(try absolute("http://[::1]:5077") == "http://[::1]:5077")
    }

    @Test func rejectsEmptyUserInfoAndBadSchemes() {
        #expect(throws: SeerrServiceError.invalidServerURL) {
            try SeerrServerURL.candidates(from: "  ")
        }
        #expect(throws: SeerrServiceError.invalidServerURL) {
            try SeerrServerURL.candidates(from: "ftp://192.168.1.10:5055")
        }
        #expect(throws: SeerrServiceError.invalidServerURL) {
            try SeerrServerURL.candidates(from: "http://user:pass@192.168.1.10:5055")
        }
        #expect(throws: SeerrServiceError.invalidServerURL) {
            try SeerrServerURL.candidates(from: "999.1.1.1")
        }
    }

    @Test func endpointJoinsBasePathWithoutADoubleSlash() throws {
        let base = try SeerrServerURL.normalizedBaseURL(from: "http://192.168.1.10:5055/seerr/")
        let endpoint = SeerrServerURL.endpointURL(base: base, path: "/api/v1/settings/public")
        #expect(endpoint?.absoluteString == "http://192.168.1.10:5055/seerr/api/v1/settings/public")

        let root = try SeerrServerURL.normalizedBaseURL(from: "http://192.168.1.10:5055")
        let rootEndpoint = SeerrServerURL.endpointURL(base: root, path: "api/v1/settings/public")
        #expect(rootEndpoint?.absoluteString == "http://192.168.1.10:5055/api/v1/settings/public")
    }

    @Test func queryEncodingMatchesSeerr() throws {
        let base = try SeerrServerURL.normalizedBaseURL(from: "http://192.168.1.10:5055")
        let endpoint = SeerrServerURL.endpointURL(
            base: base,
            path: "api/v1/search",
            queryItems: [URLQueryItem(name: "query", value: "you've got mail")]
        )
        #expect(endpoint?.absoluteString == "http://192.168.1.10:5055/api/v1/search?query=you%27ve%20got%20mail")
    }

    @Test func redirectPolicy() throws {
        let http = try SeerrServerURL.normalizedBaseURL(from: "http://192.168.1.10:5055/seerr")
        let https = try SeerrServerURL.normalizedBaseURL(from: "https://192.168.1.10:5055/seerr/api/v1/settings/public")
        let login = try SeerrServerURL.normalizedBaseURL(from: "https://192.168.1.10:5055/seerr/login")
        let other = try SeerrServerURL.normalizedBaseURL(from: "https://evil.example/seerr")
        let downgrade = try SeerrServerURL.normalizedBaseURL(from: "http://192.168.1.10:5055/seerr")

        #expect(SeerrServerURL.redirectDecision(from: http, to: https) == .follow)
        #expect(SeerrServerURL.redirectDecision(from: https, to: downgrade) == .rejectCrossOrigin)
        #expect(SeerrServerURL.redirectDecision(from: http, to: login) == .rejectLogin)
        #expect(SeerrServerURL.redirectDecision(from: http, to: other) == .rejectCrossOrigin)
        #expect(SeerrServerURL.isLoginLocation("/login"))
        #expect(SeerrServerURL.isLoginLocation("https://192.168.1.10:5055/seerr/login?next=/"))
        #expect(!SeerrServerURL.isLoginLocation("/api/v1/settings/public"))
    }

    @Test func adoptedRedirectDropsTheAPIPathAndKeepsTheBase() throws {
        let original = try SeerrServerURL.normalizedBaseURL(from: "http://192.168.1.10:5081/seerr")
        let final = URL(string: "https://192.168.1.10:5078/seerr/api/v1/settings/public")!
        let adopted = SeerrServerURL.adoptingRedirect(
            from: original,
            responseURL: final,
            requestedPath: SeerrServerURL.publicSettingsPath
        )
        #expect(adopted.absoluteString == "https://192.168.1.10:5078/seerr")
    }

    @Test func setCookieParserKeepsTheSessionOnAnIPHost() {
        let header = "connect.sid=s%3Aabc.def; Path=/; HttpOnly; SameSite=Lax, XSRF-TOKEN=tokenvalue; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT"
        let cookies = SeerrServerURL.parseSetCookieHeader(header)
        #expect(cookies.contains { $0.name == "connect.sid" && $0.value == "s%3Aabc.def" && !$0.remove })
        #expect(cookies.contains { $0.name == "XSRF-TOKEN" && $0.value == "tokenvalue" })
    }

    @Test func localNetworkPermissionMatchesPrivateHostsOnly() {
        #expect(SeerrServerURL.requiresLocalNetworkPermission(host: "10.0.0.200"))
        #expect(SeerrServerURL.requiresLocalNetworkPermission(host: "192.168.1.10"))
        #expect(SeerrServerURL.requiresLocalNetworkPermission(host: "seerr.local"))
        #expect(!SeerrServerURL.requiresLocalNetworkPermission(host: "127.0.0.1"))
        #expect(!SeerrServerURL.requiresLocalNetworkPermission(host: "localhost"))
        #expect(!SeerrServerURL.requiresLocalNetworkPermission(host: "requests.example.com"))
        #expect(!SeerrServerURL.requiresLocalNetworkPermission(host: "8.8.8.8"))
    }

    @Test func freshSeerrAcceptsPlexLoginBeforeSetup() throws {
        let settings = try JSONDecoder().decode(
            SeerrPublicSettings.self,
            from: Data(#"{"initialized":false,"applicationTitle":"Seerr","mediaServerLogin":true,"mediaServerType":4,"partialRequestsEnabled":true,"enableSpecialEpisodes":false}"#.utf8)
        )
        #expect(settings.acceptsPlexLogin)
        #expect(!settings.initialized)
    }

    @Test func jellyfinSeerrDoesNotAcceptPlexLogin() throws {
        let settings = try JSONDecoder().decode(
            SeerrPublicSettings.self,
            from: Data(#"{"initialized":true,"mediaServerLogin":true,"mediaServerType":2}"#.utf8)
        )
        #expect(!settings.acceptsPlexLogin)
    }

    @Test func missingInitializedIsNotSeerr() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SeerrPublicSettings.self, from: Data(#"{"applicationTitle":"Nope"}"#.utf8))
        }
    }

    @Test func transportErrorsAreSpecific() {
        #expect(SeerrServiceError.classifyTransport(URLError(.timedOut)) == .unreachable)
        #expect(SeerrServiceError.classifyTransport(URLError(.cannotFindHost)) == .unreachable)
        #expect(SeerrServiceError.classifyTransport(URLError(.secureConnectionFailed)) == .tlsHandshakeFailed)

        let refused = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNREFUSED)
        )
        let cannotConnect = URLError(
            .cannotConnectToHost,
            userInfo: [NSUnderlyingErrorKey: refused]
        )
        #expect(SeerrServiceError.classifyTransport(cannotConnect) == .wrongPort)
        #expect(SeerrServiceError.classifyTransport(URLError(.cannotConnectToHost)) == .wrongPort)
    }

    private func absolute(_ raw: String) throws -> String {
        try SeerrServerURL.normalizedBaseURL(from: raw).absoluteString
    }
}

@Suite("Seerr live connection", .timeLimit(.minutes(3)))
struct SeerrLiveConnectionTests {
    private let seerrPort = 5077
    private let proxyPort = 5079
    private let tlsPort = 5078
    private let upgradePort = 5081

    @Test func urlVariantsReachTheLANServer() async throws {
        guard let host = await liveHost() else { return }
        print("Seerr live probe \(host):\(seerrPort)")

        let variants = [
            "\(host):\(seerrPort)",
            "\(host):\(seerrPort)/",
            "http://\(host):\(seerrPort)",
            "http://\(host):\(seerrPort)/",
            "HTTP://\(host):\(seerrPort)/api/v1",
            "http://\(host):\(seerrPort)/api/v1/",
            "localhost:\(seerrPort)",
            "http://127.0.0.1:\(seerrPort)",
        ]
        let session = makeSession()
        defer { session.session.invalidateAndCancel() }
        let permission = await SeerrLocalNetworkGate.status(for: host)
        for raw in variants {
            let resolved = try await SeerrProbe.resolve(
                rawURL: raw,
                session: session.session,
                delegate: session.delegate
            )
            #expect(resolved.settings.initialized == false)
            #expect(resolved.settings.mediaServerType == SeerrPublicSettings.mediaServerNotConfigured)
            #expect(resolved.settings.acceptsPlexLogin)
            #expect(resolved.baseURL.port == seerrPort)
            #expect(resolved.baseURL.scheme == "http")
        }
        if permission == .denied {
            let resolved = try await SeerrProbe.resolve(
                rawURL: "http://\(host):\(seerrPort)",
                session: session.session,
                delegate: session.delegate
            )
            #expect(resolved.settings.acceptsPlexLogin)
        }

        if await responds("http://[::1]:\(seerrPort)/api/v1/settings/public") {
            let resolved = try await SeerrProbe.resolve(
                rawURL: "[::1]:\(seerrPort)",
                session: session.session,
                delegate: session.delegate
            )
            #expect(resolved.settings.acceptsPlexLogin)
        }
    }

    @Test func closedPortWrongSchemeAndLoginRedirectAreSpecific() async throws {
        guard let host = await liveHost() else { return }
        let session = makeSession()
        defer { session.session.invalidateAndCancel() }

        let closed = await failure(raw: "http://\(host):5076", session: session)
        #expect(closed == .wrongPort)

        let handshake = await failure(raw: "https://\(host):\(seerrPort)", session: session)
        #expect(handshake == .tlsHandshakeFailed)

        guard await responds("http://\(host):\(proxyPort)/login") else { return }
        for raw in ["http://\(host):\(proxyPort)/seerr", "http://\(host):\(proxyPort)/seerr/api/v1"] {
            let resolved = try await SeerrProbe.resolve(
                rawURL: raw,
                session: session.session,
                delegate: session.delegate
            )
            #expect(resolved.baseURL.path == "/seerr")
            #expect(resolved.settings.acceptsPlexLogin)
        }
        let login = await failure(raw: "http://\(host):\(proxyPort)", session: session)
        #expect(login == .redirectedToLogin)

        let authURL = URL(string: "http://\(host):\(seerrPort)/api/v1/auth/plex")!
        var auth = URLRequest(url: authURL)
        auth.httpMethod = "POST"
        auth.timeoutInterval = 10
        auth.setValue("application/json", forHTTPHeaderField: "Content-Type")
        auth.setValue("application/json", forHTTPHeaderField: "Accept")
        auth.httpBody = Data("{}".utf8)
        let (body, response) = try await session.session.data(for: auth)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 400)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("authToken"))
    }

    @Test func selfSignedCertificateCanBeTrusted() async throws {
        guard let host = await liveHost(),
              await responds("https://\(host):\(tlsPort)/api/v1/settings/public") else { return }
        let session = makeSession()
        defer { session.session.invalidateAndCancel() }
        let raw = "https://\(host):\(tlsPort)"
        let first = await failure(raw: raw, session: session)
        guard case let .tlsUntrusted(failedHost, port, fingerprint) = first else {
            Issue.record("Expected an untrusted certificate, got \(String(describing: first))")
            return
        }
        #expect(!fingerprint.isEmpty)
        #expect(port == tlsPort)
        #expect(failedHost == host || failedHost == "[\(host)]" || SeerrServerURL.normalizedHost(failedHost) == host)
        session.delegate.allow(
            key: SeerrServerURL.trustKey(host: failedHost, port: port),
            fingerprint: fingerprint
        )
        let resolved = try await SeerrProbe.resolve(
            rawURL: raw,
            session: session.session,
            delegate: session.delegate
        )
        #expect(resolved.settings.applicationTitle == "Seerr")
        #expect(resolved.baseURL.scheme == "https")

        guard await responds("http://\(host):\(upgradePort)/api/v1/settings/public") else { return }
        let upgraded = try await SeerrProbe.resolve(
            rawURL: "http://\(host):\(upgradePort)/api/v1",
            session: session.session,
            delegate: session.delegate
        )
        #expect(upgraded.baseURL.scheme == "https")
        #expect(upgraded.baseURL.port == tlsPort)
        #expect(upgraded.settings.applicationTitle == "Seerr")
    }

    private func failure(
        raw: String,
        session: (session: URLSession, delegate: SeerrURLSessionDelegate)
    ) async -> SeerrServiceError? {
        do {
            _ = try await SeerrProbe.resolve(
                rawURL: raw,
                session: session.session,
                delegate: session.delegate
            )
            return nil
        } catch let error as SeerrServiceError {
            return error
        } catch {
            return .classifyTransport(error)
        }
    }

    private func makeSession() -> (session: URLSession, delegate: SeerrURLSessionDelegate) {
        let delegate = SeerrURLSessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        return (session, delegate)
    }

    private func liveHost() async -> String? {
        for host in privateIPv4s() {
            if await responds("http://\(host):\(seerrPort)/api/v1/settings/public") {
                return host
            }
        }
        return nil
    }

    private func privateIPv4s() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var hosts: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            let family = current.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET), (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let size = socklen_t(current.pointee.ifa_addr.pointee.sa_len)
                if getnameinfo(current.pointee.ifa_addr, size, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if SeerrServerURL.requiresLocalNetworkPermission(host: ip),
                       !ip.hasPrefix("169.254."),
                       !hosts.contains(ip) {
                        hosts.append(ip)
                    }
                }
            }
            pointer = current.pointee.ifa_next
        }
        return hosts
    }

    private func responds(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch let error as URLError {
            switch error.code {
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .cancelled:
                return true
            default:
                return false
            }
        } catch {
            return false
        }
    }
}
