import Foundation
import Testing
@testable import Dusk

/// J-01: the Jellyfin account layer. Address normalisation, the stored
/// records, permissions from `Policy`, the pool's probe, the sign-in flow's
/// address race, profiles, and the facade's session state with a Jellyfin
/// primary account. Every request goes to a stub; nothing reaches a server.
@Suite("Jellyfin accounts", .serialized)
@MainActor
struct JellyfinAccountTests {
    nonisolated private static let serverID = "99d23e4060434e129f9ae072bf97d30d"
    nonisolated private static let userID = "1b0f0a8a3c3b4f7e9a6f1e2d3c4b5a69"

    // MARK: Address

    @Test func bareHostTriesHTTPSThenTheDefaultPorts() {
        #expect(JellyfinAddress.candidates(for: "jellyfin.example.com").map(\.absoluteString) == [
            "https://jellyfin.example.com",
            "http://jellyfin.example.com:8096",
            "https://jellyfin.example.com:8920",
        ])
    }

    @Test func typedSchemeIsTakenAsItIs() {
        #expect(JellyfinAddress.candidates(for: " http://jellyfin-demo ").map(\.absoluteString) == ["http://jellyfin-demo"])
        #expect(JellyfinAddress.candidates(for: "HTTPS://media.example.com:8443/").map(\.absoluteString)
            == ["https://media.example.com:8443"])
    }

    @Test func hostWithPortTriesHTTPSThenHTTPOnThatPort() {
        #expect(JellyfinAddress.candidates(for: "192.168.1.20:8096").map(\.absoluteString) == [
            "https://192.168.1.20:8096",
            "http://192.168.1.20:8096",
        ])
    }

    @Test func reverseProxyPathIsKeptAndWebPageIsDropped() {
        #expect(JellyfinAddress.candidates(for: "https://example.com/jellyfin/").map(\.absoluteString)
            == ["https://example.com/jellyfin"])
        #expect(JellyfinAddress.candidates(for: "https://example.com/jellyfin/web/index.html").map(\.absoluteString)
            == ["https://example.com/jellyfin"])
        #expect(JellyfinAddress.candidates(for: "https://example.com/webmedia").map(\.absoluteString)
            == ["https://example.com/webmedia"])
    }

    @Test func nonsenseGivesNoCandidates() {
        #expect(JellyfinAddress.candidates(for: "").isEmpty)
        #expect(JellyfinAddress.candidates(for: "two words").isEmpty)
        #expect(JellyfinAddress.candidates(for: "ftp://example.com").isEmpty)
        #expect(JellyfinAddress.candidates(for: "https://user:pw@example.com").isEmpty)
    }

    @Test func localAddressIsKeptOnlyWhenItIsAnotherEndpoint() throws {
        let base = try #require(URL(string: "http://jellyfin-demo"))
        #expect(JellyfinAddress.localAddress("http://172.19.0.31:8096", distinctFrom: base)?.absoluteString
            == "http://172.19.0.31:8096")
        #expect(JellyfinAddress.localAddress("http://jellyfin-demo:80", distinctFrom: base) == nil)
        #expect(JellyfinAddress.localAddress("", distinctFrom: base) == nil)
        #expect(JellyfinAddress.localAddress(nil, distinctFrom: base) == nil)
    }

    // MARK: Records and permissions

    @Test func accountIDIsTheStorageScopeWithNormalisedIDs() {
        #expect(JellyfinAccountRecord.accountID(serverID: "99D23E40-6043-4E12-9F9A-E072BF97D30D", userID: Self.userID)
            == "jellyfin-\(Self.serverID)-\(Self.userID)")
    }

    @Test func persistedNamesAreFixed() {
        #expect(JellyfinAccountStore.defaultsAccountsKey == "JellyfinAccounts")
        #expect(JellyfinAccountStore.defaultsActiveAccountKey == "JellyfinActiveAccountID")
        #expect(JellyfinAccountStore.tokenKey(accountID: "jellyfin-a-b") == "JellyfinAccessToken.jellyfin-a-b")
    }

    @Test func recordsRoundTripThroughTheStore() throws {
        let suite = "JellyfinAccountTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(JellyfinAccountStore.loadRecords(defaults: defaults).isEmpty)
        let record = Self.record()
        JellyfinAccountStore.saveRecords([record], defaults: defaults)
        JellyfinAccountStore.saveActiveAccountID(record.id, defaults: defaults)
        #expect(JellyfinAccountStore.loadRecords(defaults: defaults) == [record])
        #expect(JellyfinAccountStore.activeAccountID(defaults: defaults) == record.id)

        JellyfinAccountStore.saveRecords([], defaults: defaults)
        JellyfinAccountStore.saveActiveAccountID(nil, defaults: defaults)
        #expect(defaults.object(forKey: JellyfinAccountStore.defaultsAccountsKey) == nil)
        #expect(JellyfinAccountStore.activeAccountID(defaults: defaults) == nil)
    }

    @Test func policyMapsOntoPermissions() throws {
        let noDownloads = try Self.policy(#"{"IsAdministrator":false,"EnableContentDownloading":false,"EnableSubtitleManagement":false,"EnableMediaPlayback":true,"EnableUserPreferenceAccess":true}"#)
        #expect(noDownloads.permissions == ServerPermissions(
            canManageHomeRows: true, canInstallSubtitles: false, canDownload: false,
            canPlay: true, canEditPlaylists: true, ownerLabel: nil
        ))

        let admin = try Self.policy(#"{"IsAdministrator":true,"EnableContentDownloading":true,"EnableSubtitleManagement":false,"EnableUserPreferenceAccess":false}"#)
        #expect(admin.permissions.canInstallSubtitles)
        #expect(!admin.permissions.canManageHomeRows)

        // A user without a policy in the answer gets the server defaults.
        #expect(JellyfinPolicySnapshot(nil) == .serverDefaults)
        #expect(JellyfinPolicySnapshot.serverDefaults.permissions.canDownload)
    }

    @Test func poolServerCarriesBothEndpointsAndTheToken() {
        let server = JellyfinAccountProvider.accountServer(for: Self.record(), token: "token-1")
        #expect(server.clientIdentifier == Self.serverID)
        #expect(server.usableAccessToken == "token-1")
        #expect(server.sourceTitle == nil)
        #expect(server.connections.map(\.uri) == ["http://jellyfin-demo", "http://172.19.0.31:8096"])
        #expect(server.connections.map(\.local) == [false, true])
        let candidates = ServerPool.connectionCandidates(for: server).map(\.baseURL.absoluteString)
        #expect(candidates.contains("http://jellyfin-demo"))
        #expect(candidates.contains("http://172.19.0.31:8096"))
    }

    // MARK: Probe

    @Test func probeIsIdentityGatedAndChecksTheToken() async throws {
        let base = try #require(URL(string: "http://jellyfin.probe"))
        let identity = JellyfinClientIdentity(device: "Test", deviceID: "d1", version: "2.0")
        let credentials = JellyfinCredentials(accessToken: "t", userID: Self.userID)

        let reachable = await JellyfinAccountProvider.probe(
            base, serverID: Self.serverID, identity: identity, credentials: credentials,
            transport: JellyfinRoutingTransport(routes: [
                "/System/Info/Public": (200, Self.publicInfo(id: Self.serverID)),
                "/Users/Me": (200, Self.user(id: Self.userID)),
            ])
        )
        #expect(reachable.isReachable)

        let other = await JellyfinAccountProvider.probe(
            base, serverID: Self.serverID, identity: identity, credentials: credentials,
            transport: JellyfinRoutingTransport(routes: [
                "/System/Info/Public": (200, Self.publicInfo(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
            ])
        )
        #expect(other == .wrongServer("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))

        let revoked = await JellyfinAccountProvider.probe(
            base, serverID: Self.serverID, identity: identity, credentials: credentials,
            transport: JellyfinRoutingTransport(routes: [
                "/System/Info/Public": (200, Self.publicInfo(id: Self.serverID)),
                "/Users/Me": (401, ""),
            ])
        )
        #expect(revoked == .unauthorized)
    }

    // MARK: Sign-in flow

    @Test func addressRaceTakesTheMostPreferredJellyfinAnswer() async throws {
        let host = "race-\(UUID().uuidString.prefix(8).lowercased()).test"
        // https://host does not answer; http://host:8096 is Jellyfin.
        JellyfinStubURLProtocol.register(host: host) { request in
            guard request.url?.scheme == "http", request.url?.port == 8096 else { return nil }
            switch request.url?.path {
            case "/System/Info/Public": return (200, Self.publicInfo(id: Self.serverID))
            case "/QuickConnect/Enabled": return (200, "true")
            default: return (404, "")
            }
        }
        defer { JellyfinStubURLProtocol.unregister(host: host) }
        let account = JellyfinAccountProvider(sessions: JellyfinSessions(urlProtocolClasses: [JellyfinStubURLProtocol.self]))
        let flow = JellyfinSignInFlow(account: account)

        let server = try await flow.connect(to: host)
        #expect(server.baseURL.absoluteString == "http://\(host):8096")
        #expect(server.quickConnectEnabled)
        #expect(server.info.id == Self.serverID)
        #expect(!server.deviceID.isEmpty)
    }

    @Test func addressThatIsNotJellyfinSaysSo() async throws {
        let host = "plex-\(UUID().uuidString.prefix(8).lowercased()).test"
        JellyfinStubURLProtocol.register(host: host) { request in
            request.url?.scheme == "https" && request.url?.port == nil ? (200, #"{"Id":"x","ProductName":"Emby Server"}"#) : nil
        }
        defer { JellyfinStubURLProtocol.unregister(host: host) }
        let account = JellyfinAccountProvider(sessions: JellyfinSessions(urlProtocolClasses: [JellyfinStubURLProtocol.self]))

        await #expect(throws: JellyfinSignInFlow.Failure.notJellyfin) {
            _ = try await JellyfinSignInFlow(account: account).connect(to: host)
        }
        await #expect(throws: JellyfinSignInFlow.Failure.invalidAddress) {
            _ = try await JellyfinSignInFlow(account: account).connect(to: "  ")
        }
    }

    @Test func wrongPasswordIsTheSignInError() async throws {
        let host = "auth-\(UUID().uuidString.prefix(8).lowercased()).test"
        JellyfinStubURLProtocol.register(host: host) { request in
            switch request.url?.path {
            case "/System/Info/Public": return (200, Self.publicInfo(id: Self.serverID))
            case "/QuickConnect/Enabled": return (200, "false")
            case "/Users/AuthenticateByName": return (401, "")
            default: return (404, "")
            }
        }
        defer { JellyfinStubURLProtocol.unregister(host: host) }
        let account = JellyfinAccountProvider(sessions: JellyfinSessions(urlProtocolClasses: [JellyfinStubURLProtocol.self]))
        let flow = JellyfinSignInFlow(account: account)
        let server = try await flow.connect(to: "http://\(host)")

        await #expect(throws: JellyfinSignInFlow.Failure.wrongCredentials) {
            _ = try await flow.signIn(to: server, username: "duskcompare", password: "wrong")
        }
    }

    @Test func passwordSignInBuildsTheRecordWithItsOwnDeviceID() async throws {
        let host = "ok-\(UUID().uuidString.prefix(8).lowercased()).test"
        let auth = #"{"AccessToken":"tok-1","ServerId":"\#(Self.serverID)","User":{"Id":"\#(Self.userID)","Name":"duskcompare","Policy":{"IsAdministrator":false,"EnableContentDownloading":false}}}"#
        JellyfinStubURLProtocol.register(host: host) { request in
            switch request.url?.path {
            case "/System/Info/Public": return (200, Self.publicInfo(id: Self.serverID))
            case "/QuickConnect/Enabled": return (200, "true")
            case "/Users/AuthenticateByName": return (200, auth)
            case "/Sessions/Capabilities/Full": return (204, "")
            default: return (404, "")
            }
        }
        defer { JellyfinStubURLProtocol.unregister(host: host) }
        let account = JellyfinAccountProvider(sessions: JellyfinSessions(urlProtocolClasses: [JellyfinStubURLProtocol.self]))
        let flow = JellyfinSignInFlow(account: account)
        let server = try await flow.connect(to: "http://\(host)")
        let result = try await flow.signIn(to: server, username: "duskcompare", password: "pw")

        #expect(result.accessToken == "tok-1")
        #expect(result.record.id == "jellyfin-\(Self.serverID)-\(Self.userID)")
        #expect(result.record.deviceID == server.deviceID)
        #expect(result.record.localAddress?.absoluteString == "http://172.19.0.31:8096")
        #expect(!result.record.policy.permissions.canDownload)
        let stored = flow.storedAccount(for: result)
        #expect(stored.kind == .jellyfin)
        #expect(stored.deviceID == server.deviceID)

        // A second attempt never reuses the first one's device id (one token per id).
        let again = try await flow.connect(to: "http://\(host)")
        #expect(again.deviceID != server.deviceID)
    }

    // MARK: Profiles

    @Test func profilesAreSavedUsersThenUnsavedLoginScreenUsers() {
        let account = JellyfinAccountProvider(sessions: JellyfinSessions(urlProtocolClasses: [JellyfinStubURLProtocol.self]))
        let active = Self.record()
        account.state.records = [active]
        account.state.tokens = [active.id: "t"]
        account.state.activeAccountID = active.id
        account.state.publicUsers = [
            JellyfinPublicUser(id: Self.userID, name: "duskcompare", hasPassword: true, hasPrimaryImage: false),
            JellyfinPublicUser(id: "406e80605b154eb38d29e34a87ffc2ce", name: "Dusk Family", hasPassword: true, hasPrimaryImage: false),
        ]

        let profiles = JellyfinProfiles(account: account)
        #expect(profiles.all.map(\.displayName) == ["duskcompare", "Dusk Family"])
        #expect(profiles.all.map(\.isProtected) == [false, true])
        #expect(profiles.canSwitch)
        #expect(profiles.current?.id == active.id)
        #expect(account.activeProfileID == active.id)
        #expect(account.profileSecret == .password)

        account.state.publicUsers = []
        #expect(!profiles.canSwitch)
    }

    @Test func registryFindsTheProviderThroughTheAccountThatHoldsTheServer() {
        let account = JellyfinAccountProvider(sessions: JellyfinSessions(urlProtocolClasses: [JellyfinStubURLProtocol.self]))
        let registry = ProviderRegistry([JellyfinProviderFactory(account: account)])
        #expect(registry.kind(for: Self.serverID, registry: ServerRegistry()) == .plex)

        let record = Self.record()
        account.state.records = [record]
        account.state.tokens = [record.id: "t"]
        account.state.activeAccountID = record.id
        #expect(registry.kind(for: Self.serverID, registry: ServerRegistry()) == .jellyfin)
        // Anything else, and every id persisted before Jellyfin, stays Plex.
        #expect(registry.kind(for: "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9", registry: ServerRegistry()) == .plex)
        #expect(registry.kind(for: nil, registry: ServerRegistry()) == .plex)
    }

    // MARK: Facade

    /// A Plex install (no Jellyfin keys) is untouched: no account session.
    /// With a Jellyfin user added, the facade's session state, profile scope,
    /// nil-id routing and Plex Home gates follow that user; sign-out clears it.
    @Test func facadeFollowsAJellyfinPrimaryAndPlexStaysAsItWas() async throws {
        let service = MediaService(urlProtocolClasses: [FakeNetworkRecorder.self])
        defer {
            service.session.invalidateAndCancel()
            service.probeSession.invalidateAndCancel()
            service.bootstrapSession.invalidateAndCancel()
        }
        let flow = try #require(service.jellyfinSignInFlow)
        // The test host may hold a Plex sign-in or a saved Jellyfin user from
        // another run; this test only owns a clean install.
        guard service.primaryAccountToken == nil, flow.account.state.records.isEmpty else { return }

        #expect(service.accountSession == nil)
        #expect(service.sessionState == .signedOut)
        #expect(service.serverProvider(for: nil).descriptor.kind == .plex)

        let record = Self.record()
        service.completeJellyfinSignIn(JellyfinSignInFlow.Result(record: record, accessToken: "tok"))

        #expect(service.accountSession != nil)
        #expect(service.isAuthenticated)
        #expect(service.sessionState == .ready)
        #expect(service.isSessionReady)
        #expect(service.activeProfileID == record.id)
        #expect(service.homeBootstrapCompleted)
        #expect(!service.needsHomeUserSelection)
        #expect(service.profileSecret == .password)
        #expect(service.serverProvider(for: nil).descriptor.kind == .jellyfin)
        #expect(service.serverProvider(for: record.serverID).descriptor.id == record.serverID)
        #expect(service.accounts.primary?.kind == .jellyfin)

        await flow.account.signOutAll()
        service.tearDownServerSessions(forgetServers: true)
        #expect(service.accountSession == nil)
        #expect(service.sessionState == .signedOut)
        #expect(JellyfinAccountStore.loadRecords().isEmpty)
        #expect(JellyfinAccountStore.token(accountID: record.id) == nil)
    }

    // MARK: Fixtures

    nonisolated static func record() -> JellyfinAccountRecord {
        JellyfinAccountRecord(
            serverID: serverID,
            serverName: "Demo",
            serverVersion: "12.4.0",
            userID: userID,
            userName: "duskcompare",
            baseURL: URL(string: "http://jellyfin-demo")!,
            localAddress: URL(string: "http://172.19.0.31:8096"),
            deviceID: "device-a",
            policy: .serverDefaults,
            hasPrimaryImage: false
        )
    }

    nonisolated static func publicInfo(id: String) -> String {
        #"{"LocalAddress":"http://172.19.0.31:8096","ServerName":"Demo","Version":"12.4.0","ProductName":"Jellyfin Server","Id":"\#(id)","StartupWizardCompleted":true}"#
    }

    nonisolated static func user(id: String) -> String {
        #"{"Id":"\#(id)","Name":"duskcompare"}"#
    }

    nonisolated static func policy(_ json: String) throws -> JellyfinPolicySnapshot {
        JellyfinPolicySnapshot(try JSONDecoder().decode(JellyfinUserPolicyDTO.self, from: Data(json.utf8)))
    }
}

/// Answers by path, `404` for anything else.
struct JellyfinRoutingTransport: JellyfinTransport {
    let routes: [String: (Int, String)]

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (status, body) = routes[request.url?.path ?? ""] ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

/// Serves `JellyfinSessions(urlProtocolClasses:)` from per-host handlers; a
/// host without one, or a handler answering nil, cannot be connected to.
final class JellyfinStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    static func unregister(host: String) {
        lock.withLock { handlers[host] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handlers[request.url?.host ?? ""] }
        guard let url = request.url, let (status, body) = handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
