import Foundation
import OSLog

@MainActor
@Observable
final class MediaService {
    // MARK: - Account
    //
    // The Plex account's state forwarders (`primaryAccountToken`, `homeUsers`,
    // …) live with the Plex facade glue (`Providers/Plex/Facade/MediaService+PlexAccount.swift`).

    /// Compatibility name for the account token used by existing service code.
    /// New account operations should choose `primaryAccountToken` or
    /// `activeAccountToken` explicitly.
    var authToken: String? { activeAccountToken }

    var isAuthenticated: Bool { primaryAccountToken != nil || accountSession?.isSignedIn == true }
    var activeProfileID: String? {
        if let accountSession { return accountSession.activeProfileID }
        if needsHomeUserSelection, activeHomeUser == nil {
            return nil
        }
        return activeHomeUser?.stableProfileID
            ?? currentUser?.uuid?.nilIfEmpty
            ?? (activeAccountToken == primaryAccountToken ? primaryProfileID : nil)
    }
    /// The storage scope of the active profile; nil while there is none.
    var profileScope: ProfileScope? { activeProfileID.map(ProfileScope.init(id:)) }
    /// What `ContentView` shows: one value instead of `isAuthenticated`,
    /// `homeBootstrapCompleted` and `needsHomeUserSelection`.
    var sessionState: SessionState {
        if let accountSession {
            if !accountSession.isSignedIn { return .signedOut }
            return accountSession.needsProfileSelection ? .needsProfile : .ready
        }
        if !isAuthenticated { return .signedOut }
        if !homeBootstrapCompleted { return .bootstrapping }
        if needsHomeUserSelection { return .needsProfile }
        return .ready
    }
    var isSessionReady: Bool {
        if let accountSession {
            return accountSession.isSignedIn
                && accountSession.activeProfileID != nil
                && !accountSession.needsProfileSelection
        }
        return isAuthenticated
            && homeBootstrapCompleted
            && activeProfileID != nil
            && !needsHomeUserSelection
    }
    var shouldAdoptLegacyProfileData: Bool {
        accountSession == nil
            && homeBootstrapCompleted
            && primaryProfileID != nil
            && activeAccountToken == primaryAccountToken
            && (activeHomeUser == nil || activeHomeUser?.stableProfileID == primaryProfileID)
    }

    /// Cached account library order (plex.tv `experience` setting) plus the
    /// connected server's sections. See `MediaService+LibraryOrder`.
    let libraryOrder = LibraryOrderStore()

    /// The account's video playlists on every connected server. See
    /// `MediaService+Playlists`.
    let playlists = PlaylistStore()

    /// The playlists pinned to Home for each profile. See `PinnedPlaylistStore`.
    let pinnedPlaylists = PinnedPlaylistStore()

    /// The account's Plex Watchlist (plex.tv). See `MediaService+Watchlist`.
    let watchlist = WatchlistStore()

    /// Every server this account can use and the live session with each one.
    /// Everything that talks to a server resolves through here.
    let pool = ServerPool()

    /// The user's server order and per-server on/off switch.
    let serverPriority = ServerPriorityStore()

    /// Which items on different servers are the same content. Filled by the
    /// merge layers, read by playback to fall back to another server.
    let alternates = ContentAlternatesIndex()

    /// Per-server recovery bookkeeping. Owned by `MediaService+Servers`
    /// (`recoverServer(serverID:)`) — nothing else may touch these.
    @ObservationIgnored var serverRecoveryTasks: [String: Task<ServerSession, Error>] = [:]
    @ObservationIgnored var serverRecoveryCooldowns: [String: Date] = [:]

    @ObservationIgnored var streamSelectionWriteTask: Task<Void, Error>?

    /// The Plex account's provider. It owns the account's credentials and
    /// Plex Home state, its account requests and server discovery, and the
    /// request core its servers' facets send through.
    let accountProvider: any MediaAccountProvider
    /// The provider factories. The pool builds each session's server provider
    /// with them.
    let providers: ProviderRegistry
    /// The signed-in accounts, read in place from each provider's credentials.
    let accounts: AccountStore
    /// Which provider each server id belongs to. Empty: every server is Plex.
    let serverRegistry: ServerRegistry
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    /// How long requests to a server keep failing fast after its recovery
    /// failed. Long enough that a screenful of requests cannot re-run discovery
    /// over and over, short enough that a server coming back is picked up on the
    /// next screen refresh.
    static let serverRecoveryCooldown: TimeInterval = 30

    /// - Parameters:
    ///   - urlProtocolClasses: Tests only: serves every session's requests.
    ///   - serverRegistry: Tests only: server ids that belong to another
    ///     provider. The default (empty) makes every server Plex.
    ///   - additionalProviderFactories: Tests only: registered after the
    ///     standard factories, so Plex stays first (`DuskTests/Fakes`).
    init(
        urlProtocolClasses: [AnyClass]? = nil,
        serverRegistry: ServerRegistry = ServerRegistry(),
        additionalProviderFactories: [any ProviderFactory] = []
    ) {
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.serverRegistry = serverRegistry

        let clientIdentifier: String
        if let stored = UserDefaults.standard.string(forKey: Self.defaultsClientIDKey) {
            clientIdentifier = stored
        } else {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: Self.defaultsClientIDKey)
            clientIdentifier = id
        }
        let standard = ProviderSetup.standard(clientIdentifier: clientIdentifier, urlProtocolClasses: urlProtocolClasses)
        let providers = ProviderRegistry(standard.registry.factories + additionalProviderFactories)
        self.accountProvider = standard.account
        self.providers = providers
        self.accounts = AccountStore(registry: providers)

        #if DEBUG
        let readsStoredSignIn = !ScreenshotMode.startsSignedOut
        #else
        let readsStoredSignIn = true
        #endif
        accountProvider.restoreCredentials(readsStoredSignIn: readsStoredSignIn)
        // The account's routed send asks this service's pool for every step.
        accountProvider.attach(recovering: self)
        // Before the pool restores last launch's sessions: a restored server
        // finds its provider through the accounts that hold it.
        for account in standard.additionalAccounts {
            account.restoreCredentials(readsStoredSignIn: readsStoredSignIn)
            account.attach(recovering: self)
        }

        pool.configure(
            probeSession: probeSession,
            baseHeaders: plexRequestHeaders,
            providers: providers,
            serverRegistry: serverRegistry
        )
        // `-DuskScreenshotSignedOut` never touches the Keychain: the stored
        // server tokens are real sign-ins too.
        if readsStoredSignIn {
            migrateLegacySingleServerState()
            restorePersistedSessions()
        }
    }

    /// Seeds the pool from the sessions persisted by the previous launch, so a
    /// cold start already has every enabled server usable before plex.tv
    /// discovery answers. `ServerConnectionCoordinator`'s pass then verifies and
    /// refreshes them; a restored endpoint that has since moved simply fails
    /// over on its next request.
    private func restorePersistedSessions() {
        for server in ServerPool.storedSnapshots()
        where !server.clientIdentifier.isEmpty && serverPriority.isEnabled(server.clientIdentifier) {
            let serverID = server.clientIdentifier
            guard let token = ServerPool.storedToken(serverID: serverID) else { continue }
            guard let baseURL = ServerPool.restorableBaseURL(serverID: serverID) else { continue }

            pool.adopt(
                server: server,
                baseURL: baseURL,
                token: token,
                connection: Self.connection(in: server, matching: baseURL),
                priority: serverPriority,
                verified: false
            )
        }
    }

    /// Moves the pre-multi-server session (`PlexServerURL`, `PlexServerData`,
    /// `PlexLastGoodConnectionURI`, Keychain `PlexServerAuthToken`) onto the
    /// per-server keys and retires the originals. Nothing writes them any more,
    /// so this is a one-time upgrade step; `PlexServerID` is deliberately left
    /// in place because `ServerPriorityStore` still seeds its order from it.
    private func migrateLegacySingleServerState() {
        let defaults = UserDefaults.standard
        let legacyToken = KeychainHelper.load(key: Self.keychainServerTokenKey)
            .flatMap { String(data: $0, encoding: .utf8) }?
            .nilIfEmpty
        let legacyLastGoodURI = defaults
            .string(forKey: Self.defaultsLastGoodConnectionURIKey)?
            .nilIfEmpty
        let legacyBaseURL = defaults
            .string(forKey: Self.defaultsServerURLKey)
            .flatMap(URL.init(string:))
        let legacyServer = defaults
            .data(forKey: Self.defaultsServerDataKey)
            .flatMap { try? decoder.decode(AccountServer.self, from: $0) }

        if let legacyServer, !legacyServer.clientIdentifier.isEmpty {
            ServerPool.migrateLegacyState(
                serverID: legacyServer.clientIdentifier,
                // Older releases persisted the server token inside the snapshot.
                token: legacyToken ?? legacyServer.usableAccessToken,
                lastGoodURI: legacyLastGoodURI,
                baseURL: legacyBaseURL,
                snapshot: legacyServer.withoutAccessToken
            )
        }

        defaults.removeObject(forKey: Self.defaultsServerURLKey)
        defaults.removeObject(forKey: Self.defaultsServerDataKey)
        defaults.removeObject(forKey: Self.defaultsLastGoodConnectionURIKey)
        KeychainHelper.delete(key: Self.keychainServerTokenKey)
    }

    /// Matches a restored base URL back onto the stored server's connection
    /// list by host, so a session restored without a probe still knows whether
    /// it is local, remote, or relayed.
    private static func connection(in server: AccountServer, matching baseURL: URL) -> ServerEndpoint? {
        guard let host = baseURL.host else { return nil }
        return server.connections.first { connection in
            for uri in [connection.uri, connection.httpFallbackURI].compactMap({ $0 }) {
                guard let url = URL(string: uri), url.host == host else { continue }
                if let basePort = baseURL.port, let connectionPort = url.port, basePort != connectionPort {
                    continue
                }
                return true
            }
            return false
        }
    }

    // MARK: - Teardown

    /// Tears down *every* server session. Sign-out and Plex Home switches only:
    /// a single failing request must never clear the pool, because that would
    /// sign the user out of the servers that are working fine.
    ///
    /// - Parameter forgetServers: Sign-out. Also drops the stored priority order
    ///   and every per-server credential and remembered endpoint, including
    ///   those of servers that never connected this launch.
    func tearDownServerSessions(forgetServers: Bool = false) {
        libraryOrder.invalidate()
        playlists.reset()
        watchlist.reset()
        // Rating keys only mean something for the account that fetched them.
        alternates.reset()
        for task in serverRecoveryTasks.values {
            task.cancel()
        }
        serverRecoveryTasks = [:]
        serverRecoveryCooldowns = [:]
        // Server tokens belong to the identity that fetched them, so a Home
        // switch invalidates every one of them just as a sign-out does — and the
        // pool only knows the servers it has seen this launch, so the stored
        // order and snapshots have to be swept too.
        let known = Set(serverPriority.entries.map(\.machineIdentifier))
            .union(ServerPool.storedSnapshots().map(\.clientIdentifier))
            .union(pool.knownServerIDs)
        for serverID in known {
            ServerPool.forget(serverID: serverID)
        }
        pool.clear()
        // Siri's titles belong to this identity's libraries too.
        SiriTitleCatalog.shared.clear()
        #if os(tvOS)
        // The Top Shelf mirrors this identity's Continue Watching.
        TopShelfPublisher.shared.clear()
        #endif
        if forgetServers {
            UserDefaults.standard.removeObject(forKey: Self.defaultsServerIDKey)
            serverPriority.reset()
        }
    }
}

/// The pool side of every provider's routed send (04 §8). Declared here so the
/// conformance sits with the class.
extension MediaService: SessionRecovering {
    func session(for serverID: String?) -> ServerSession? {
        pool.connection(for: serverID)
    }

    func connectionState(for serverID: String) -> ServerConnectionState {
        pool.state(for: serverID)
    }

    func markUnauthorized(serverID: String) {
        pool.markUnauthorized(serverID: serverID)
    }

    func markVerified(serverID: String, baseURL: URL) {
        pool.markVerified(serverID: serverID, baseURL: baseURL)
    }

    func serverDecoder(for serverID: String?) -> JSONDecoder {
        pool.decoder(for: serverID)
    }

    func knownServer(for serverID: String) -> AccountServer? {
        pool.server(for: serverID)
    }
}
