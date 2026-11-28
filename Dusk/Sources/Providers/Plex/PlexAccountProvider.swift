import Foundation
import OSLog

/// The signed-in plex.tv account (docs/jellyfin/04-architecture.md §3, §7).
///
/// Owns the account's credentials and Plex Home state (`state`), the plex.tv
/// request core with its fresh-sign-in retry, and server discovery. The facade
/// (`MediaService+Auth`, `+Home`, `+Servers`) still orchestrates sign-in,
/// Home switches and the connect pass on top of it, and forwards its long-lived
/// account properties (`primaryAccountToken`, `homeUsers`, …) here, so every
/// caller reads exactly what it read before.
///
/// One per `MediaService`, alive while signed out too: the sign-in flow and a
/// later sign-in reuse it. `restoreAccount(from:)` hands back this instance.
final class PlexAccountProvider: MediaAccountProvider {
    let client: PlexClient
    /// The account's mutable state. Main-actor bound, observable: views read it
    /// through the facade.
    let state: PlexAccountState
    /// The routed send every facet of this account's servers uses.
    let router: PlexServerRouter
    let account = AccountDescriptor(id: PlexAccountProvider.accountID, kind: .plex, displayName: "Plex")

    /// The one Plex account an install can hold.
    static let accountID = "plex"

    // Persisted names. Never change them (04 §19): they are existing users'
    // sign-in.
    /// Kept at the legacy name so existing users' linked-account credential
    /// migrates without requiring another sign-in.
    static let keychainTokenKey = "PlexAuthToken"
    static let keychainActiveHomeTokenKey = "PlexActiveHomeUserToken"
    static let defaultsActiveHomeUserDataKey = "PlexActiveHomeUserData"
    static let defaultsAutomaticHomeSignInKey = "PlexAutomaticallySignInHomeUser"
    static let defaultsHomeMigrationCompletedKey = "PlexHomeMigrationCompleted"
    static let defaultsPrimaryProfileIDKey = "PlexPrimaryProfileID"

    static let authenticationPropagationRetryWindow: TimeInterval = 20
    static let authenticationPropagationRetryAttempts = 20

    @MainActor static var plexTVBase: String {
        #if DEBUG
        if let override = ScreenshotMode.plexTVBase { return override }
        #endif
        return "https://plex.tv"
    }

    @MainActor
    init(client: PlexClient) {
        self.client = client
        self.state = PlexAccountState()
        self.router = PlexServerRouter(client: client)
        router.account = self
    }

    // MARK: - Stored account

    /// The signed-in account as a `StoredAccount`, read in place from the
    /// Keychain credential `restoreCredentials` loaded. Empty while signed out.
    @MainActor var storedAccounts: [StoredAccount] {
        guard state.primaryAccountToken != nil else { return [] }
        return [StoredAccount(
            id: Self.accountID,
            kind: .plex,
            displayName: account.displayName,
            credentialRef: Self.keychainTokenKey,
            deviceID: nil
        )]
    }

    /// Loads the account's credentials and remembered Home member from the
    /// Keychain and UserDefaults, as the previous launch left them. Runs once,
    /// from `MediaService.init`, before anything reads `state`.
    ///
    /// - Parameter readsStoredSignIn: false only for `-DuskScreenshotSignedOut`,
    ///   which must never touch a real sign-in.
    @MainActor
    func restoreCredentials(readsStoredSignIn: Bool) {
        if readsStoredSignIn,
           let data = KeychainHelper.load(key: Self.keychainTokenKey),
           let token = String(data: data, encoding: .utf8) {
            state.primaryAccountToken = token.nilIfEmpty
        }
        #if DEBUG
        // Screenshot mode signs in to the mock server's demo account and never
        // touches a real Plex sign-in stored in the Keychain.
        if ScreenshotMode.isActive {
            state.primaryAccountToken = ScreenshotMode.accountToken
        }
        #endif

        if let profileData = UserDefaults.standard.data(forKey: Self.defaultsActiveHomeUserDataKey),
           let profile = try? JSONDecoder().decode(PlexHomeUser.self, from: profileData) {
            state.activeHomeUser = profile
        }

        let shouldAutomaticallySignIn: Bool
        if UserDefaults.standard.object(forKey: Self.defaultsAutomaticHomeSignInKey) == nil {
            shouldAutomaticallySignIn = true
        } else {
            shouldAutomaticallySignIn = UserDefaults.standard.bool(
                forKey: Self.defaultsAutomaticHomeSignInKey
            )
        }
        state.automaticHomeSignIn = shouldAutomaticallySignIn
        // When this was a stored property on the facade, its `didSet`
        // (`MediaService.automaticHomeSignInDidChange`) ran for this assignment
        // too, at this exact point: the choice is written back every launch
        // and, when off, the remembered member token is dropped. Kept as is.
        persistAutomaticHomeSignIn()

        state.primaryProfileID = UserDefaults.standard
            .string(forKey: Self.defaultsPrimaryProfileIDKey)?
            .nilIfEmpty

        if readsStoredSignIn,
           shouldAutomaticallySignIn,
           state.activeHomeUser != nil,
           let data = KeychainHelper.load(key: Self.keychainActiveHomeTokenKey),
           let token = String(data: data, encoding: .utf8)?.nilIfEmpty {
            state.activeAccountToken = token
            state.hasRememberedHomeUserToken = true
        } else {
            state.activeAccountToken = state.primaryAccountToken
        }
    }

    /// Persists `state.automaticHomeSignIn`: the choice itself, plus the
    /// active member's token while it is on (dropped while it is off).
    @MainActor
    func persistAutomaticHomeSignIn() {
        let enabled = state.automaticHomeSignIn
        UserDefaults.standard.set(enabled, forKey: Self.defaultsAutomaticHomeSignInKey)

        guard enabled else {
            state.hasRememberedHomeUserToken = false
            KeychainHelper.delete(key: Self.keychainActiveHomeTokenKey)
            return
        }

        guard state.activeHomeUser != nil, let activeAccountToken = state.activeAccountToken else { return }
        state.hasRememberedHomeUserToken = true
        KeychainHelper.save(
            key: Self.keychainActiveHomeTokenKey,
            data: Data(activeAccountToken.utf8)
        )
    }

    // MARK: - MediaAccountProvider

    func servers() async throws -> [ServerCandidateSet] {
        try await discoverServerCandidateSets()
    }

    func probe(_ candidate: ConnectionCandidate, in set: ServerCandidateSet) async -> ProbeResult {
        guard let credential = set.credential else { return .unauthorized }
        let (headers, session) = await probeContext()
        return await ConnectionSelector.probe(
            candidate,
            serverID: set.seed.serverID,
            headers: headers.merging(["X-Plex-Token": credential]) { _, new in new },
            session: session
        )
    }

    /// Plex sign-out is local: plex.tv has no session to end, so this only
    /// forgets the account credential. The facade's `signOut()` also tears
    /// down every server session and the Home state.
    func signOut() async {
        await clearCredential()
    }

    @MainActor
    private func probeContext() -> ([String: String], URLSession) {
        var headers = client.plexRequestHeaders
        headers.removeValue(forKey: "X-Plex-Token")
        return (headers, client.probeSession)
    }

    @MainActor
    private func discoverServerCandidateSets() async throws -> [ServerCandidateSet] {
        let servers = try await discoverServers()
        let restricted = state.activeHomeUser?.isRestricted == true
        return servers.map { server in
            let serverID = server.clientIdentifier
            return ServerCandidateSet(
                seed: Self.seed(for: server, restrictedProfile: restricted),
                credential: server.usableAccessToken ?? ServerPool.storedToken(serverID: serverID),
                candidates: ServerPool.connectionCandidates(
                    for: server,
                    lastKnownGood: ServerPool.storedBaseURL(serverID: serverID)
                )
            )
        }
    }

    static func seed(for server: PlexServer, restrictedProfile: Bool) -> ServerSessionSeed {
        ServerSessionSeed(
            serverID: server.clientIdentifier,
            name: server.name,
            version: server.productVersion,
            owned: server.owned,
            sourceTitle: server.sourceTitle,
            restrictedProfile: restrictedProfile
        )
    }

    // MARK: - Credential

    /// Stores (or, for nil, deletes) the linked account's credential.
    @MainActor
    func saveCredential(_ token: String?) {
        if let token {
            KeychainHelper.save(key: Self.keychainTokenKey, data: Data(token.utf8))
        } else {
            KeychainHelper.delete(key: Self.keychainTokenKey)
        }
    }

    @MainActor
    func clearCredential() {
        state.primaryAccountToken = nil
        state.activeAccountToken = nil
        state.authTokenUpdatedAt = nil
        state.currentUser = nil
        KeychainHelper.delete(key: Self.keychainTokenKey)
    }

    // MARK: - Server discovery

    /// The account's Plex Media Servers from plex.tv `/api/v2/resources`, with
    /// their connections and server-scoped tokens.
    @MainActor
    func discoverServers() async throws -> [PlexServer] {
        guard !state.needsHomeUserSelection, let activeAccountToken = state.activeAccountToken else {
            throw PlexServiceError.notAuthenticated
        }

        return try await retryAfterFreshAuthentication {
            guard let url = client.buildURL(
                base: Self.plexTVBase,
                path: "/api/v2/resources",
                queryItems: [
                    URLQueryItem(name: "includeHttps", value: "1"),
                    URLQueryItem(name: "includeRelay", value: "1"),
                ]
            ) else { throw PlexServiceError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            client.applyHeaders(to: &request, token: activeAccountToken)
            guard state.bootstrapNetworkAvailable else {
                throw PlexServiceError.networkError(URLError(.notConnectedToInternet).localizedDescription)
            }
            let data = try await execute(request, using: client.bootstrapSession)

            guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw PlexServiceError.decodingError("Expected JSON array from resources endpoint")
            }

            let decoder = JSONDecoder()
            let servers = jsonArray.compactMap { json -> PlexServer? in
                guard Self.isMediaServerResource(json) else { return nil }
                guard let itemData = try? JSONSerialization.data(withJSONObject: json) else {
                    return nil
                }
                return try? decoder.decode(PlexServer.self, from: itemData)
            }

            if isAuthenticationFresh,
               !servers.isEmpty,
               servers.allSatisfy({ $0.usableAccessToken == nil }) {
                plexAuthLogger.notice("Server discovery returned servers without usable access tokens during bootstrap window")
                throw AuthenticationBootstrapError.waitingForPropagation
            }

            return servers
        }
    }

    /// Whether a plex.tv resource is a Plex Media Server. `provides` normally
    /// lists "server", but plex.tv can report a real server with a wrong
    /// `provides` (the owner's main server came back as `"controller"` with
    /// `product` still "Plex Media Server", 2026-11-10), which made Dusk drop
    /// it before any connection was tried while Plex's own apps kept working.
    /// The product name is enough; `/identity` still has to name the server
    /// before any connection to it is used.
    static func isMediaServerResource(_ json: [String: Any]) -> Bool {
        let provides = (json["provides"] as? String)?
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        if provides.contains("server") { return true }
        return (json["product"] as? String)?.caseInsensitiveCompare("Plex Media Server") == .orderedSame
    }

    // MARK: - plex.tv requests

    /// The one plex.tv request path (the facade's `rawPlexTVRequest` and the
    /// account facets forward here): headers, body encoding, offline guard,
    /// fresh-sign-in retry and sessions.
    ///
    /// - Parameter timeoutInterval: Overrides the session's 15s request timeout
    ///   for this call only. Use it for plex.tv requests that are a nicety rather
    ///   than a requirement, so a LAN-only session (the server answers, the
    ///   internet does not) cannot stall a screen behind them.
    @MainActor
    func plexTVData(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil,
        formBody: [String: String]? = nil,
        jsonBody: Data? = nil,
        accountToken: String? = nil,
        timeoutInterval: TimeInterval? = nil,
        retriesFreshAuthentication: Bool = true,
        bootstrap: Bool = false
    ) async throws -> Data {
        if bootstrap, !state.bootstrapNetworkAvailable {
            throw PlexServiceError.networkError(URLError(.notConnectedToInternet).localizedDescription)
        }
        guard let url = client.buildURL(base: Self.plexTVBase, path: path, queryItems: queryItems) else {
            throw PlexServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        client.applyHeaders(to: &request, token: accountToken ?? state.activeAccountToken)

        if let formBody {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = formBody.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = components.query?.data(using: .utf8)
        } else if let jsonBody {
            // plex.tv's account-settings endpoint only accepts a JSON body.
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }

        return try await execute(
            request,
            retriesFreshAuthentication: retriesFreshAuthentication,
            using: bootstrap ? client.bootstrapSession : nil
        )
    }

    /// `plexTVData` decoded. plex.tv payloads carry no server, so the decoder
    /// stamps none.
    @MainActor
    func plexTVRequest<T: Decodable>(
        method: String = "GET",
        path: String,
        formBody: [String: String]? = nil,
        accountToken: String? = nil,
        retriesFreshAuthentication: Bool = true,
        bootstrap: Bool = false
    ) async throws -> T {
        let data = try await plexTVData(
            method: method,
            path: path,
            formBody: formBody,
            accountToken: accountToken,
            retriesFreshAuthentication: retriesFreshAuthentication,
            bootstrap: bootstrap
        )
        return try client.decode(T.self, from: data, using: JSONDecoder())
    }

    /// One request through `client`, retried while a fresh sign-in propagates.
    @MainActor
    private func execute(
        _ request: URLRequest,
        retriesFreshAuthentication: Bool = true,
        using session: URLSession? = nil
    ) async throws -> Data {
        try client.validate(request)
        let operation: () async throws -> Data = {
            try await self.client.send(request, using: session)
        }

        if retriesFreshAuthentication {
            return try await retryAfterFreshAuthentication(operation)
        }
        return try await operation()
    }

    // MARK: - Fresh sign-in

    /// A token plex.tv issued moments ago can be rejected by plex.tv and by
    /// servers until it has propagated.
    @MainActor var isAuthenticationFresh: Bool {
        guard let authTokenUpdatedAt = state.authTokenUpdatedAt else { return false }
        return Date().timeIntervalSince(authTokenUpdatedAt) < Self.authenticationPropagationRetryWindow
    }

    @MainActor
    func retryAfterFreshAuthentication<T>(
        attempts: Int? = nil,
        delay: Duration = .seconds(1),
        _ operation: () async throws -> T
    ) async throws -> T {
        let requestedAttempts = attempts ?? Self.authenticationPropagationRetryAttempts
        let maxAttempts = isAuthenticationFresh ? max(requestedAttempts, 1) : 1
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                let shouldRetry = attempt < maxAttempts && shouldRetryAfterFreshAuthentication(error)

                if shouldRetry {
                    try? await Task.sleep(for: delay)
                    continue
                }

                if isAuthenticationFresh, shouldRetryAfterFreshAuthentication(error) {
                    plexAuthLogger.notice("Authentication bootstrap still pending after retries: \(error.localizedDescription, privacy: .public)")
                    throw PlexServiceError.authenticationPending
                }

                throw error
            }
        }

        throw lastError ?? PlexServiceError.authenticationPending
    }

    @MainActor
    func shouldRetryAfterFreshAuthentication(_ error: Error) -> Bool {
        guard isAuthenticationFresh else { return false }

        if error is AuthenticationBootstrapError {
            return true
        }

        guard let plexError = error as? PlexServiceError else {
            return false
        }

        switch plexError {
        case .unauthorized:
            return true
        default:
            return false
        }
    }
}

enum AuthenticationBootstrapError: Error {
    case waitingForPropagation
}

/// The Plex account's mutable state: the linked account's credential, the
/// active Home member's credential and the Home bootstrap flags. Read and
/// written through `MediaService`'s forwarding properties; the facade's
/// `+Auth` / `+Home` orchestration owns every transition and its persistence.
@MainActor
@Observable
final class PlexAccountState {
    /// Durable credential created by the normal Plex sign-in flow. This token
    /// belongs to the linked full account and is the only credential allowed to
    /// enumerate or switch Plex Home members.
    var primaryAccountToken: String?
    /// Credential used for account-scoped API calls in the current session.
    /// It equals `primaryAccountToken` outside Plex Home and becomes the token
    /// returned by the Home switch endpoint for another member.
    var activeAccountToken: String?
    var authTokenUpdatedAt: Date?
    var currentUser: PlexUser?
    var homeUsers: [PlexHomeUser] = []
    var activeHomeUser: PlexHomeUser?
    var homeBootstrapCompleted = false
    /// Cached identity is usable offline; Plex Home still needs online validation.
    var isUsingOfflineHomeSession = false
    var homeSelectionRequested = false
    var primaryProfileID: String?
    var hasRememberedHomeUserToken = false
    /// Plain storage: `MediaService.automaticHomeSignIn` persists every set
    /// (`PlexAccountProvider.persistAutomaticHomeSignIn`).
    var automaticHomeSignIn = true
    /// Whether the system reports a network route. Bootstrap requests fail
    /// fast without one instead of waiting out their timeouts.
    var bootstrapNetworkAvailable = true

    var hasPlexHome: Bool { homeUsers.count > 1 }

    var needsHomeUserSelection: Bool {
        homeBootstrapCompleted && hasPlexHome && homeSelectionRequested
    }
}
