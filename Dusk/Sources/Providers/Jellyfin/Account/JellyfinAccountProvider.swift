import Foundation
import OSLog

let jellyfinAccountLogger = Logger(subsystem: "app.dusk", category: "JellyfinAccount")

/// The Jellyfin users signed in on this device and which one is active.
/// Main-actor bound and observable: the facade's session state reads it.
@MainActor
@Observable
final class JellyfinAccountState {
    /// Every saved user, in the order they were added.
    var records: [JellyfinAccountRecord] = []
    var activeAccountID: String?
    /// Tokens by account id, loaded from the Keychain at launch.
    @ObservationIgnored var tokens: [String: String] = [:]
    /// The profile picker was asked for (Switch User).
    var profileSelectionRequested = false
    /// `/Users/Public` of the active server, for the picker. Often empty.
    var publicUsers: [JellyfinPublicUser] = []

    var activeRecord: JellyfinAccountRecord? {
        guard let activeAccountID else { return nil }
        return records.first { $0.id == activeAccountID }
    }
}

/// A user the server lists on its login screen.
struct JellyfinPublicUser: Sendable, Hashable {
    let id: String
    let name: String
    let hasPassword: Bool
    let hasPrimaryImage: Bool
}

/// Jellyfin's `MediaAccountProvider` (docs/jellyfin/04-architecture.md §3, §7):
/// every Jellyfin user saved on this device, the active one's session
/// (`AccountSession`) and its one server.
///
/// A Jellyfin account is one user on one server with its own token and
/// `DeviceId`. Switch User moves between saved users of the active server
/// without logging any of them out; a user that is not saved yet signs in with
/// a password and joins the list. One instance per `MediaService`, alive while
/// signed out too, like the Plex account.
final class JellyfinAccountProvider: MediaAccountProvider {
    let state: JellyfinAccountState
    let sessions: JellyfinSessions
    let account = AccountDescriptor(id: "jellyfin", kind: .jellyfin, displayName: "Jellyfin")
    @MainActor private weak var recovering: (any SessionRecovering)?

    @MainActor
    init(sessions: JellyfinSessions = .standard) {
        self.state = JellyfinAccountState()
        self.sessions = sessions
    }

    // MARK: - Stored accounts

    /// The active user first (it is the primary account), then the others.
    @MainActor var storedAccounts: [StoredAccount] {
        guard let active = state.activeRecord, state.tokens[active.id] != nil else { return [] }
        let others = state.records.filter { $0.id != active.id && state.tokens[$0.id] != nil }
        return ([active] + others).map(Self.storedAccount(for:))
    }

    nonisolated static func storedAccount(for record: JellyfinAccountRecord) -> StoredAccount {
        StoredAccount(
            id: record.id,
            kind: .jellyfin,
            displayName: record.userName,
            credentialRef: JellyfinAccountStore.tokenKey(accountID: record.id),
            deviceID: record.deviceID
        )
    }

    @MainActor
    func record(forServer serverID: String) -> JellyfinAccountRecord? {
        let id = JellyfinID.normalized(serverID)
        if let active = state.activeRecord, active.serverID == id { return active }
        return state.records.first { $0.serverID == id }
    }

    @MainActor
    func token(for record: JellyfinAccountRecord) -> String? {
        state.tokens[record.id]
    }

    /// Loads the saved users and their tokens. Screenshot mode and
    /// `-DuskScreenshotSignedOut` never read a real sign-in.
    @MainActor
    func restoreCredentials(readsStoredSignIn: Bool) {
        var reads = readsStoredSignIn
        #if DEBUG
        if ScreenshotMode.isActive { reads = false }
        #endif
        guard reads else { return }
        let records = JellyfinAccountStore.loadRecords()
        state.records = records
        state.tokens = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            JellyfinAccountStore.token(accountID: record.id).map { (record.id, $0) }
        })
        let active = JellyfinAccountStore.activeAccountID()
        state.activeAccountID = records.contains { $0.id == active && state.tokens[$0.id] != nil }
            ? active
            : records.first { state.tokens[$0.id] != nil }?.id
    }

    @MainActor
    func attach(recovering: any SessionRecovering) {
        self.recovering = recovering
    }

    // MARK: - Sign-in

    /// Saves a finished sign-in and makes it the active user.
    @MainActor
    func add(_ result: JellyfinSignInFlow.Result) {
        let record = result.record
        if let previous = state.records.first(where: { $0.id == record.id }), previous.deviceID != record.deviceID {
            // The old token is bound to the old device id; this sign-in replaced it.
            jellyfinAccountLogger.notice("Replacing a saved Jellyfin user's session")
        }
        state.records.removeAll { $0.id == record.id }
        state.records.append(record)
        state.tokens[record.id] = result.accessToken
        state.activeAccountID = record.id
        state.profileSelectionRequested = false
        JellyfinAccountStore.saveToken(result.accessToken, accountID: record.id)
        JellyfinAccountStore.saveRecords(state.records)
        JellyfinAccountStore.saveActiveAccountID(record.id)
    }

    // MARK: - MediaAccountProvider

    func servers() async throws -> [ServerCandidateSet] {
        await MainActor.run {
            accountServers().map { server in
                ServerCandidateSet(
                    seed: ServerSessionSeed(
                        serverID: server.clientIdentifier,
                        name: server.name,
                        version: server.productVersion,
                        owned: server.owned,
                        sourceTitle: nil
                    ),
                    credential: server.accessToken,
                    candidates: ServerPool.connectionCandidates(for: server)
                )
            }
        }
    }

    func probe(_ candidate: ConnectionCandidate, in set: ServerCandidateSet) async -> ProbeResult {
        guard let credential = set.credential,
              let probe = await connectionProbe(serverID: set.seed.serverID, credential: credential) else {
            return .unauthorized
        }
        return await probe(candidate)
    }

    func signOut() async {
        await signOutAll()
    }

    var profiles: any ProfileProviding { JellyfinProfiles(account: self) }
    var preferences: any AccountPreferencesProviding { JellyfinAccountPreferences() }
    var watchlist: (any WatchlistProviding)? { nil }
    @MainActor var seerrAuth: any SeerrAuthProviding { JellyfinSeerrAuth() }
    @MainActor var session: (any AccountSession)? { self }

    // MARK: - Probe

    /// `/System/Info/Public` must name `serverID` (the identity gate), then
    /// `/Users/Me` must accept the token.
    @MainActor
    func connectionProbe(serverID: String, credential: String) -> ConnectionProbe? {
        guard let record = record(forServer: serverID) else { return nil }
        let identity = JellyfinClientIdentity.dusk(deviceID: record.deviceID)
        let credentials = JellyfinCredentials(accessToken: credential, userID: record.userID)
        let transport = sessions.probeTransport
        let expected = record.serverID
        return { candidate in
            await Self.probe(candidate.baseURL, serverID: expected, identity: identity,
                             credentials: credentials, transport: transport)
        }
    }

    @inline(never)
    nonisolated static func probe(
        _ baseURL: URL,
        serverID: String,
        identity: JellyfinClientIdentity,
        credentials: JellyfinCredentials,
        transport: any JellyfinTransport
    ) async -> ConnectionProbeOutcome {
        let client = JellyfinClient(baseURL: baseURL, identity: identity, credentials: credentials, transport: transport)
        let clock = ContinuousClock()
        let started = clock.now
        let info: JellyfinPublicSystemInfoDTO
        switch await Result.capturing({ try await client.send(JellyfinAPI.publicSystemInfo()) }) {
        case let .success(value): info = value
        case let .failure(error): return outcome(for: error)
        }
        let elapsed = clock.now - started
        guard JellyfinID.same(info.id, serverID) else { return .wrongServer(info.id) }
        switch await Result.capturing({ try await client.send(JellyfinAPI.currentUser()) }) {
        case .success:
            return .reachable(latency: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        case let .failure(error):
            return outcome(for: error)
        }
    }

    nonisolated private static func outcome(for error: any Error) -> ConnectionProbeOutcome {
        if error is CancellationError { return .skipped }
        guard let error = error as? JellyfinError else {
            return .failed(error.localizedDescription, cause: AnalyticsErrorCause(error: error))
        }
        switch error {
        case .unauthorized, .notAuthenticated:
            return .unauthorized
        case let .transport(code, description):
            let urlError = URLError(URLError.Code(rawValue: code))
            return .failed(description, cause: AnalyticsErrorCause(error: urlError))
        case let .httpStatus(status):
            return .failed("HTTP \(status)", cause: .http(status))
        default:
            return .failed(error.localizedDescription, cause: AnalyticsErrorCause(error: error))
        }
    }

    // MARK: - AccountSession (conformance below)

    @MainActor var isSignedIn: Bool { !storedAccounts.isEmpty }

    @MainActor var activeProfileID: String? {
        guard let active = state.activeRecord, state.tokens[active.id] != nil else { return nil }
        return active.id
    }

    @MainActor var needsProfileSelection: Bool {
        state.profileSelectionRequested
    }

    @MainActor var profileSecret: ProfileSecretKind { .password }

    @MainActor
    func accountServers() -> [AccountServer] {
        guard let record = state.activeRecord, let token = state.tokens[record.id] else { return [] }
        return [Self.accountServer(for: record, token: token)]
    }

    /// The pool's form of the active user's server: the typed address and the
    /// server's LAN address as its two connections, the user's token as its
    /// credential.
    nonisolated static func accountServer(for record: JellyfinAccountRecord, token: String?) -> AccountServer {
        func endpoint(_ url: URL, local: Bool) -> ServerEndpoint {
            let scheme = url.scheme?.lowercased() ?? "https"
            return ServerEndpoint(
                protocol: scheme,
                address: url.host ?? "",
                port: url.port ?? (scheme == "https" ? 443 : 80),
                uri: url.absoluteString,
                local: local,
                relay: false,
                iPv6: url.host?.contains(":")
            )
        }
        var connections = [endpoint(record.baseURL, local: false)]
        if let local = record.localAddress {
            connections.append(endpoint(local, local: true))
        }
        return AccountServer(
            name: record.serverName,
            clientIdentifier: record.serverID,
            product: "Jellyfin Server",
            productVersion: record.serverVersion,
            platform: nil,
            platformVersion: nil,
            provides: "server",
            owned: true,
            presence: true,
            accessToken: token,
            sourceTitle: nil,
            connections: connections
        )
    }

    /// A client for the active user on `baseURL` (the pool's live endpoint
    /// when there is one).
    @MainActor
    func client(for record: JellyfinAccountRecord, baseURL: URL? = nil) -> JellyfinClient? {
        guard let token = state.tokens[record.id] else { return nil }
        return JellyfinClient(
            baseURL: baseURL ?? recovering?.session(for: record.serverID)?.baseURL ?? record.baseURL,
            identity: .dusk(deviceID: record.deviceID),
            credentials: JellyfinCredentials(accessToken: token, userID: record.userID),
            transport: sessions.sharedTransport
        )
    }

    @MainActor
    func refresh() async throws {
        guard let record = state.activeRecord, let client = client(for: record) else { return }
        do {
            let user = try await client.send(JellyfinAPI.currentUser())
            guard var current = state.records.first(where: { $0.id == record.id }) else { return }
            current.policy = JellyfinPolicySnapshot(user.policy)
            current.userName = user.name?.nilIfEmpty ?? current.userName
            current.hasPrimaryImage = user.primaryImageTag?.nilIfEmpty != nil
            replace(current)
            // Switch User lists the server's login-screen users too.
            await refreshPublicUsers()
        } catch JellyfinError.unauthorized {
            // The token was revoked (signed out from the dashboard, or this
            // device id signed in again elsewhere): this user needs a new sign-in.
            jellyfinAccountLogger.notice("A saved Jellyfin user's token was revoked")
            forget(record.id)
            throw MediaServiceError.unauthorized
        } catch let error as JellyfinError {
            if case .transport = error { return }
            throw error
        }
    }

    /// Re-reads `/Users/Public` for the picker. Failures leave the last list.
    @MainActor
    func refreshPublicUsers() async {
        guard let record = state.activeRecord else { return }
        let client = JellyfinClient(
            baseURL: recovering?.session(for: record.serverID)?.baseURL ?? record.baseURL,
            identity: .dusk(deviceID: record.deviceID),
            transport: sessions.probeTransport
        )
        guard let users = try? await client.send(JellyfinAPI.publicUsers()) else { return }
        state.publicUsers = users.compactMap { user in
            guard let name = user.name?.nilIfEmpty else { return nil }
            return JellyfinPublicUser(
                id: JellyfinID.normalized(user.id),
                name: name,
                hasPassword: user.hasPassword ?? true,
                hasPrimaryImage: user.primaryImageTag?.nilIfEmpty != nil
            )
        }
    }

    @MainActor
    func switchProfile(_ profile: Profile, secret: String?) async throws {
        if let saved = state.records.first(where: { $0.id == profile.id }), state.tokens[saved.id] != nil {
            activate(saved.id)
            return
        }
        guard let active = state.activeRecord,
              let user = state.publicUsers.first(where: { Self.accountID(for: $0, on: active) == profile.id }) else {
            throw JellyfinSignInFlow.Failure.userUnavailable
        }
        let deviceID = JellyfinClientIdentity.newDeviceID()
        let client = JellyfinClient(
            baseURL: recovering?.session(for: active.serverID)?.baseURL ?? active.baseURL,
            identity: .dusk(deviceID: deviceID),
            transport: sessions.probeTransport
        )
        let result: JellyfinAuthenticationResultDTO
        do {
            result = try await client.send(JellyfinAPI.authenticateByName(username: user.name, password: secret ?? ""))
        } catch JellyfinError.unauthorized {
            throw JellyfinSignInFlow.Failure.wrongPassword
        }
        let userID = JellyfinID.normalized(result.user.id)
        let record = JellyfinAccountRecord(
            serverID: active.serverID,
            serverName: active.serverName,
            serverVersion: active.serverVersion,
            userID: userID,
            userName: result.user.name?.nilIfEmpty ?? user.name,
            baseURL: active.baseURL,
            localAddress: active.localAddress,
            deviceID: deviceID,
            policy: JellyfinPolicySnapshot(result.user.policy),
            hasPrimaryImage: result.user.primaryImageTag?.nilIfEmpty != nil
        )
        let signedIn = client.signedIn(JellyfinCredentials(accessToken: result.accessToken, userID: userID))
        _ = try? await signedIn.send(JellyfinAPI.postCapabilities())
        add(JellyfinSignInFlow.Result(record: record, accessToken: result.accessToken))
    }

    @MainActor
    func requestProfileSelection() {
        state.profileSelectionRequested = true
        Task { await refreshPublicUsers() }
    }

    @MainActor
    func cancelProfileSelection() {
        guard state.activeRecord != nil else { return }
        state.profileSelectionRequested = false
    }

    /// Logs every saved user out on the server (`POST /Sessions/Logout`, best
    /// effort) and forgets them here.
    @MainActor
    func signOutAll() async {
        let clients = state.records.compactMap { record in
            client(for: record, baseURL: record.baseURL)
        }
        for id in state.records.map(\.id) {
            JellyfinAccountStore.deleteToken(accountID: id)
        }
        state.records = []
        state.tokens = [:]
        state.activeAccountID = nil
        state.profileSelectionRequested = false
        state.publicUsers = []
        JellyfinAccountStore.saveRecords([])
        JellyfinAccountStore.saveActiveAccountID(nil)
        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                let quick = JellyfinClient(
                    baseURL: client.baseURL, identity: client.identity,
                    credentials: client.credentials, transport: sessions.probeTransport
                )
                group.addTask { _ = try? await quick.send(JellyfinAPI.logout()) }
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func accountID(for user: JellyfinPublicUser, on server: JellyfinAccountRecord) -> String {
        JellyfinAccountRecord.accountID(serverID: server.serverID, userID: user.id)
    }

    @MainActor
    private func activate(_ id: String) {
        state.activeAccountID = id
        state.profileSelectionRequested = false
        JellyfinAccountStore.saveActiveAccountID(id)
    }

    @MainActor
    private func replace(_ record: JellyfinAccountRecord) {
        guard let index = state.records.firstIndex(where: { $0.id == record.id }) else { return }
        state.records[index] = record
        JellyfinAccountStore.saveRecords(state.records)
    }

    /// Drops one saved user whose token no longer works. Another saved user of
    /// the same server becomes the picker's choice.
    @MainActor
    private func forget(_ id: String) {
        state.records.removeAll { $0.id == id }
        state.tokens[id] = nil
        JellyfinAccountStore.deleteToken(accountID: id)
        JellyfinAccountStore.saveRecords(state.records)
        if state.activeAccountID == id {
            state.activeAccountID = nil
            JellyfinAccountStore.saveActiveAccountID(nil)
            if let next = state.records.first(where: { state.tokens[$0.id] != nil }) {
                state.activeAccountID = next.id
                state.profileSelectionRequested = true
                JellyfinAccountStore.saveActiveAccountID(next.id)
            }
        }
    }
}

/// In an extension, so the conformance does not make the whole class main-actor
/// isolated (its `MediaAccountProvider` members are not).
extension JellyfinAccountProvider: AccountSession {}
