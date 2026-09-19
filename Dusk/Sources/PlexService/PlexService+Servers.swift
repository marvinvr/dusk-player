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

extension PlexService {
    var serverSessionToken: ServerSessionToken {
        ServerSessionToken(profileID: activeProfileID, generation: pool.generation)
    }

    func discoverServers() async throws -> [PlexServer] {
        guard !needsHomeUserSelection, let activeAccountToken else {
            throw PlexServiceError.notAuthenticated
        }

        return try await retryAfterFreshAuthentication {
            guard let url = buildURL(
                base: Self.plexTVBase,
                path: "/api/v2/resources",
                queryItems: [
                    URLQueryItem(name: "includeHttps", value: "1"),
                    URLQueryItem(name: "includeRelay", value: "1"),
                ]
            ) else { throw PlexServiceError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyHeaders(to: &request, token: activeAccountToken)
            let data = try await executeRequest(request)

            guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw PlexServiceError.decodingError("Expected JSON array from resources endpoint")
            }

            let servers = jsonArray.compactMap { json -> PlexServer? in
                guard let provides = json["provides"] as? String, provides.contains("server") else {
                    return nil
                }
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

    /// Connects every enabled server in parallel: discover, fold the result into
    /// the stored priority order, then let the pool race each server's
    /// connections on its own. Never fails because one server is unreachable —
    /// it throws only when the account itself cannot be used.
    ///
    /// This is the only entry point that connects the account; feature screens
    /// go through `ServerConnectionCoordinator` instead.
    @discardableResult
    func connectAllServers() async throws -> [PlexServerConnection] {
        guard !needsHomeUserSelection, activeAccountToken != nil else {
            throw PlexServiceError.notAuthenticated
        }

        let session = serverSessionToken
        // An account-wide pass means "try again now", so it lifts the per-server
        // recovery cooldowns instead of letting them fail requests fast.
        serverRecoveryCooldowns = [:]

        let discovered = try await discoverServers()

        // The profile changed (or the session was torn down) while plex.tv was
        // answering: reconciling or connecting now would hand the new identity
        // the previous member's servers and tokens.
        guard session == serverSessionToken else {
            plexAuthLogger.notice("Discarding a connect pass that belongs to a previous Plex session")
            return []
        }

        serverPriority.reconcile(discovered: discovered)

        await pool.connectAll(discovered, priority: serverPriority)

        // The library-order cache is keyed on the connected servers in priority
        // order, so it invalidates itself when that set or its order changes;
        // nothing has to be dropped here.
        if pool.primary != nil {
            // Best-effort: learn the account's remote-streaming entitlement in
            // the background so the player can warn instantly later.
            Task { await self.loadAccountEntitlementIfNeeded() }
        }

        return pool.connections
    }

    /// Re-discovers one server and re-races its connections. Used when a request
    /// to that server fails in a way a fresh endpoint could fix. Only that
    /// server's state changes; every other session keeps running.
    @discardableResult
    func reconnectServer(serverID: String) async throws -> PlexServerConnection {
        guard activeAccountToken != nil else { throw PlexServiceError.notAuthenticated }

        let session = serverSessionToken

        return try await retryAfterFreshAuthentication {
            let refreshedServers = try await discoverServers()

            // Same rule as a full pass: a session that has since been replaced
            // must not get this server (and its token) grafted onto it.
            guard session == serverSessionToken else {
                throw PlexServiceError.noServerConnected
            }

            guard let server = refreshedServers.first(where: { $0.clientIdentifier == serverID }) else {
                pool.markOffline(serverID: serverID, reason: "This server is no longer shared with your account.")
                throw PlexServiceError.noServerConnected
            }

            plexAuthLogger.notice("Refreshing Plex server endpoint for \(server.name, privacy: .public)")

            guard let connection = await pool.connect(to: server, priority: serverPriority) else {
                throw connectionFailure(for: server)
            }
            serverRecoveryCooldowns[serverID] = nil
            return connection
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
    func recoverServer(serverID: String) async throws -> PlexServerConnection {
        if let existing = serverRecoveryTasks[serverID] {
            return try await existing.value
        }

        if let coolingDownUntil = serverRecoveryCooldowns[serverID], coolingDownUntil > .now {
            throw recentRecoveryFailure(for: serverID)
        }

        let task = Task { @MainActor [weak self] () throws -> PlexServerConnection in
            guard let self else { throw PlexServiceError.noServerConnected }
            return try await self.reconnectServer(serverID: serverID)
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
            return PlexServiceError.unauthorized
        case let .offline(reason):
            return PlexServiceError.networkError(reason)
        default:
            return PlexServiceError.networkError(
                "Could not connect to \(pool.displayName(for: serverID))"
            )
        }
    }

    /// Re-authorizes a single server. A 401 from one server says nothing about
    /// the others, so this never touches the rest of the pool.
    func refreshServerAuthorization(serverID: String) async throws {
        guard !needsHomeUserSelection, activeAccountToken != nil else {
            throw PlexServiceError.unauthorized
        }
        try await recoverServer(serverID: serverID)
    }

    /// Turns a pool failure state into the error the call site expects.
    private func connectionFailure(for server: PlexServer) -> Error {
        switch pool.state(for: server.clientIdentifier) {
        case .unauthorized:
            plexAuthLogger.notice("Server connect received 401 for \(server.name, privacy: .public) during bootstrap=\(self.isAuthenticationFresh, privacy: .public)")
            return isAuthenticationFresh
                ? AuthenticationBootstrapError.waitingForPropagation
                : PlexServiceError.unauthorized
        case let .offline(reason):
            return PlexServiceError.networkError(reason)
        default:
            return PlexServiceError.networkError("Could not connect to \(server.name)")
        }
    }
}
