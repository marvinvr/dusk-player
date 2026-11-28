import Foundation
import OSLog

/// Identity of the current server session: the Plex Home profile plus the pool's
/// generation, which changes on every sign-out and Home switch.
///
/// Discovery is slow enough that a profile switch routinely happens while a pass
/// is in flight. Every pass captures this before its first await and abandons
/// itself when it no longer matches, so the previous member's servers can never
/// be re-registered — with their tokens written back to the Keychain — into the
/// session that replaced them.
struct ServerSessionToken: Equatable {
    let profileID: String?
    let generation: Int
}

extension MediaService {

    var serverSessionToken: ServerSessionToken {
        ServerSessionToken(profileID: activeProfileID, generation: pool.generation)
    }

    /// The account's servers from plex.tv, through its provider.
    func discoverServers() async throws -> [AccountServer] {
        try await plexAccount.discoverServers()
    }

    /// Connects every enabled server in parallel: discover, fold the result into
    /// the stored priority order, then let the pool race each server's
    /// connections on its own. Never fails because one server is unreachable —
    /// it throws only when the account itself cannot be used.
    ///
    /// This is the only entry point that connects the account; feature screens
    /// go through `ServerConnectionCoordinator` instead.
    @discardableResult
    func connectAllServers(trigger: String = "Connect") async throws -> [ServerSession] {
        if let accountSession {
            return try await connectAccountSessionServers(accountSession, trigger: trigger)
        }
        guard !needsHomeUserSelection, activeAccountToken != nil else {
            throw MediaServiceError.notAuthenticated
        }

        let session = serverSessionToken
        // An account-wide pass means "try again now", so it lifts the per-server
        // recovery cooldowns instead of letting them fail requests fast.
        serverRecoveryCooldowns = [:]

        let discovered: [AccountServer]
        do {
            discovered = try await discoverServers()
        } catch let error as MediaServiceError where Self.isTransportFailure(error) {
            // plex.tv is unreachable, which says nothing about the servers
            // themselves (a LAN-only network). Validate and select from the
            // stored snapshots instead of leaving restored sessions unchecked;
            // only a pass that finds nothing at all reports the error.
            let snapshots = ServerPool.storedSnapshots()
            guard session == serverSessionToken,
                  snapshots.contains(where: { serverPriority.isEnabled($0.clientIdentifier) }) else { throw error }
            plexConnectionLogger.notice("plex.tv unreachable (\(error.localizedDescription, privacy: .public)); selecting from stored snapshots")
            // Keep disabled snapshots too: connectAll persists the full known
            // list, skips disabled servers and probes the rest in parallel.
            await pool.connectAll(
                snapshots, priority: serverPriority,
                trigger: "\(trigger) (plex.tv unreachable)", using: bootstrapSession
            )
            guard !pool.connections.isEmpty else { throw error }
            return pool.connections
        }

        // The profile changed (or the session was torn down) while plex.tv was
        // answering: reconciling or connecting now would hand the new identity
        // the previous member's servers and tokens.
        guard session == serverSessionToken else {
            plexAuthLogger.notice("Discarding a connect pass that belongs to a previous Plex session")
            return []
        }

        serverPriority.reconcile(discovered: discovered)

        await pool.connectAll(discovered, priority: serverPriority, trigger: trigger, using: bootstrapSession)

        // The library-order cache is keyed on the connected servers in priority
        // order, so it invalidates itself when that set or its order changes;
        // nothing has to be dropped here.
        return pool.connections
    }

    /// Re-discovers one server and re-races its connections. Used when a request
    /// to that server fails in a way a fresh endpoint could fix. Only that
    /// server's state changes; every other session keeps running.
    ///
    /// When plex.tv cannot be reached (a LAN-only network, plex.tv down) the
    /// last known server snapshot is selected from instead: its connections,
    /// plus the endpoint that worked last, are usually all a LAN needs.
    @discardableResult
    func reconnectServer(serverID: String, reason: String = "Reconnect") async throws -> ServerSession {
        if let accountSession {
            guard let server = accountSession.accountServers().first(where: { $0.clientIdentifier == serverID }) else {
                throw MediaServiceError.noServerConnected
            }
            plexConnectionLogger.notice("Re-selecting connection for \(server.name, privacy: .public): \(reason, privacy: .public)")
            guard let connection = await pool.connect(to: server, priority: serverPriority, trigger: reason) else {
                throw connectionFailure(for: server)
            }
            serverRecoveryCooldowns[serverID] = nil
            return connection
        }
        guard activeAccountToken != nil else { throw MediaServiceError.notAuthenticated }

        let session = serverSessionToken

        return try await retryAfterFreshAuthentication {
            let server: AccountServer
            do {
                let refreshedServers = try await discoverServers()
                // Same rule as a full pass: a session that has since been replaced
                // must not get this server (and its token) grafted onto it.
                guard session == serverSessionToken else {
                    throw MediaServiceError.noServerConnected
                }
                guard let found = refreshedServers.first(where: { $0.clientIdentifier == serverID }) else {
                    pool.markOffline(serverID: serverID, reason: "This server is no longer shared with your account.")
                    throw MediaServiceError.noServerConnected
                }
                server = found
            } catch let error as MediaServiceError where Self.isTransportFailure(error) {
                guard session == serverSessionToken, let snapshot = pool.server(for: serverID) else { throw error }
                plexConnectionLogger.notice("plex.tv unreachable (\(error.localizedDescription, privacy: .public)); selecting from the stored snapshot")
                server = snapshot
            }

            plexConnectionLogger.notice("Re-selecting connection for \(server.name, privacy: .public): \(reason, privacy: .public)")

            guard let connection = await pool.connect(to: server, priority: serverPriority, trigger: reason) else {
                throw connectionFailure(for: server)
            }
            serverRecoveryCooldowns[serverID] = nil
            return connection
        }
    }

    /// The connect pass of an account that runs its own session: its
    /// servers come from the account (no discovery round trip), refreshed
    /// identity first, then the same priority fold and parallel race as Plex.
    private func connectAccountSessionServers(
        _ accountSession: any AccountSession,
        trigger: String
    ) async throws -> [ServerSession] {
        guard accountSession.activeProfileID != nil, !accountSession.needsProfileSelection else {
            throw MediaServiceError.notAuthenticated
        }
        let session = serverSessionToken
        serverRecoveryCooldowns = [:]
        // The user's permissions and name can change on the server; a
        // revoked token ends this user's session here (throws).
        do {
            try await accountSession.refresh()
        } catch MediaServiceError.unauthorized {
            // That user's sessions carried the revoked token.
            tearDownServerSessions()
            throw MediaServiceError.unauthorized
        }
        guard session == serverSessionToken else { return [] }

        let servers = accountSession.accountServers()
        serverPriority.reconcile(discovered: servers)
        await pool.connectAll(servers, priority: serverPriority, trigger: trigger, using: bootstrapSession)
        return pool.connections
    }

    private static func isTransportFailure(_ error: MediaServiceError) -> Bool {
        switch error {
        case .networkError, .httpError: true
        default: false
        }
    }

    /// Per-server recovery for the request layer: one reconnect at a time per
    /// server, joined by everyone who needs it, with a short cooldown after a
    /// failure.
    ///
    /// A screen makes a dozen requests at once. Without this, a single offline
    /// server turns every one of them into its own plex.tv discovery plus a full
    /// probe race, which is both slow and a good way to get rate-limited. During
    /// the cooldown requests to that server fail fast instead; an account-wide
    /// pass (`connectAllServers`) and the explicit Retry in Server Priority
    /// clear it, because those are the user asking for another attempt.
    @discardableResult
    func recoverServer(serverID: String, reason: String = "Request failed") async throws -> ServerSession {
        if let existing = serverRecoveryTasks[serverID] {
            return try await existing.value
        }

        if let coolingDownUntil = serverRecoveryCooldowns[serverID], coolingDownUntil > .now {
            throw recentRecoveryFailure(for: serverID)
        }

        let task = Task { @MainActor [weak self] () throws -> ServerSession in
            guard let self else { throw MediaServiceError.noServerConnected }
            return try await self.reconnectServer(serverID: serverID, reason: reason)
        }
        serverRecoveryTasks[serverID] = task

        do {
            let connection = try await task.value
            serverRecoveryTasks[serverID] = nil
            serverRecoveryCooldowns[serverID] = nil
            return connection
        } catch {
            serverRecoveryTasks[serverID] = nil
            serverRecoveryCooldowns[serverID] = .now.addingTimeInterval(Self.serverRecoveryCooldown)
            throw error
        }
    }

    /// The error a request gets while its server is on the recovery cooldown.
    /// It repeats why the server is unusable rather than inventing a new reason.
    private func recentRecoveryFailure(for serverID: String) -> Error {
        switch pool.state(for: serverID) {
        case .unauthorized:
            return MediaServiceError.unauthorized
        case let .offline(reason):
            return MediaServiceError.networkError(reason)
        default:
            return MediaServiceError.networkError(
                "Could not connect to \(pool.displayName(for: serverID))"
            )
        }
    }

    /// Re-authorizes a single server. A 401 from one server says nothing about
    /// the others, so this never touches the rest of the pool.
    func refreshServerAuthorization(serverID: String) async throws {
        guard accountSession != nil || (!needsHomeUserSelection && activeAccountToken != nil) else {
            throw MediaServiceError.unauthorized
        }
        try await recoverServer(serverID: serverID, reason: "Not connected / token refresh")
    }

    /// Turns a pool failure state into the error the call site expects.
    private func connectionFailure(for server: AccountServer) -> Error {
        switch pool.state(for: server.clientIdentifier) {
        case .unauthorized:
            plexAuthLogger.notice("Server connect received 401 for \(server.name, privacy: .public) during bootstrap=\(self.isAuthenticationFresh, privacy: .public)")
            return isAuthenticationFresh
                ? AuthenticationBootstrapError.waitingForPropagation
                : MediaServiceError.unauthorized
        case let .offline(reason):
            return MediaServiceError.networkError(reason)
        default:
            return MediaServiceError.networkError("Could not connect to \(server.name)")
        }
    }
}
