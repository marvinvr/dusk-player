import Foundation
import OSLog

/// Where one server stands right now.
enum ServerConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case connected(PlexServerConnection)
    /// The server answered, but rejected our token.
    case unauthorized
    /// Nothing reachable. Carries the last failure reason for the UI.
    case offline(String)
    /// Turned off in Server Priority; deliberately not connected.
    case disabled

    var connection: PlexServerConnection? {
        guard case let .connected(connection) = self else { return nil }
        return connection
    }

    var isConnected: Bool { connection != nil }
}

/// Every Plex server this account can use, and the live session with each one.
///
/// The pool replaces "the one connected server": servers connect in parallel and
/// each commits its own state as soon as it resolves, so one unreachable server
/// can never hold up the others. Everything that needs to reach a server asks
/// the pool for that server's `PlexServerConnection`.
///
/// Credentials and the remembered good endpoint are per server
/// (`PlexServerAuthToken.<id>` in Keychain, `PlexLastGoodConnectionURI.<id>` in
/// UserDefaults); the legacy single-server values are migrated once.
@MainActor
@Observable
final class ServerPool {
    /// Maximum servers probed at once. Each probe already fans out across its
    /// own candidate endpoints, so a wider pool mostly buys contention.
    nonisolated static let maximumConcurrentConnects = 4

    private(set) var states: [String: ServerConnectionState] = [:]
    /// Tokenless server snapshots, keyed by machine identifier.
    private(set) var servers: [String: PlexServer] = [:]
    /// Known machine identifiers in priority order.
    private(set) var order: [String] = []

    /// Bumped by `clear()`, i.e. whenever the session identity changes
    /// (sign-out, Plex Home switch). A probe that started under an older
    /// generation is discarded when it lands, so the previous member's servers
    /// can never be written back into a pool that belongs to someone else.
    private(set) var generation: Int = 0

    @ObservationIgnored private var session: URLSession = .shared
    @ObservationIgnored private var baseHeaders: [String: String] = [:]
    @ObservationIgnored private var decoders: [String: JSONDecoder] = [:]
    @ObservationIgnored private let plainDecoder = JSONDecoder()
    /// The order and on/off switch the pool checks against, remembered from the
    /// first call that passes one. `commit` re-reads it because a server can be
    /// turned off while its probe is still in flight.
    @ObservationIgnored private var priorityStore: ServerPriorityStore?

    /// Injected by `PlexService` at init. The headers carry no credential; the
    /// per-server token is added when a request is built.
    func configure(session: URLSession, baseHeaders: [String: String]) {
        self.session = session
        self.baseHeaders = baseHeaders
    }

    // MARK: - Reading

    /// Connected servers in priority order.
    var connections: [PlexServerConnection] {
        orderedIdentifiers.compactMap { states[$0]?.connection }
    }

    /// The server that wins when nothing else picks one: the highest-priority
    /// connected server. Only "primary" concepts that are genuinely account-wide
    /// (Seerr's linked server, Live TV) may rely on this.
    var primary: PlexServerConnection? { connections.first }

    var hasMultipleEnabledServers: Bool {
        states.values.filter { $0 != .disabled }.count > 1
    }

    /// True while at least one enabled server is still resolving.
    var isConnecting: Bool {
        states.values.contains(.connecting)
    }

    func state(for serverID: String) -> ServerConnectionState {
        states[serverID] ?? .idle
    }

    /// The live session for a server, or the primary one when `serverID` is nil.
    func connection(for serverID: String?) -> PlexServerConnection? {
        guard let serverID = serverID?.nilIfEmpty else { return primary }
        return states[serverID]?.connection
    }

    func server(for serverID: String) -> PlexServer? {
        servers[serverID]
    }

    /// Every server the pool has a record of this launch, connected or not.
    var knownServerIDs: Set<String> {
        Set(states.keys).union(servers.keys)
    }

    /// A decoder that stamps `serverID` onto every model it decodes. Cached per
    /// server because `JSONDecoder` is not cheap to build.
    func decoder(for serverID: String?) -> JSONDecoder {
        guard let serverID = (serverID?.nilIfEmpty ?? primary?.serverID) else {
            return plainDecoder
        }
        if let cached = decoders[serverID] {
            return cached
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = serverID
        decoders[serverID] = decoder
        return decoder
    }

    // MARK: - Connecting

    /// Connects every enabled server in parallel. Never throws: a server that
    /// cannot be reached simply ends up `.offline` while the others come up.
    func connectAll(_ discovered: [PlexServer], priority: ServerPriorityStore) async {
        let generation = self.generation
        register(discovered, priority: priority)
        // Only discovery sees the whole account, so this is the one place that
        // may rewrite the snapshot list the next cold launch restores from.
        // Disabled servers are kept: turning one back on must not cost a
        // round-trip to plex.tv before it can be used.
        Self.saveSnapshots(orderedIdentifiers.compactMap { servers[$0] })

        // A server the user turned off is ignored entirely, session included.
        for server in discovered where !priority.isEnabled(server.clientIdentifier) {
            markDisabled(serverID: server.clientIdentifier)
        }

        // Discovery saw the whole account, so a server the pool knows about but
        // that did not come back is not reachable for this identity any more —
        // including a session restored from the last launch, which would
        // otherwise keep reporting itself as connected.
        let discoveredIdentifiers = Set(discovered.map(\.clientIdentifier))
        for serverID in knownServerIDs where !discoveredIdentifiers.contains(serverID) {
            guard priority.isEnabled(serverID) else {
                markDisabled(serverID: serverID)
                continue
            }
            markOffline(
                serverID: serverID,
                reason: "\(displayName(for: serverID)) is not available on this account right now."
            )
        }

        let enabled = priority.enabledServers(from: discovered)
        guard !enabled.isEmpty else { return }

        for server in enabled where states[server.clientIdentifier]?.isConnected != true {
            // An already-connected server keeps showing as connected while it is
            // re-probed, so a refresh never blanks the UI.
            states[server.clientIdentifier] = .connecting
        }

        // Requests are built here, on the main actor, because they need the
        // session's headers; the probing itself is pure networking.
        var works: [ProbeWork] = []
        for server in enabled {
            switch makeWork(for: server) {
            case let .ready(work):
                works.append(work)
            case let .unavailable(state):
                states[server.clientIdentifier] = state
            }
        }
        guard !works.isEmpty else { return }

        for await (work, resolution) in Self.probeAll(works: works, session: session) {
            commit(resolution, work: work, generation: generation)
        }
    }

    /// Races `works` with a bounded number in flight and publishes each result
    /// the moment it lands, so every server commits its own state independently
    /// instead of waiting for the slowest one.
    private nonisolated static func probeAll(
        works: [ProbeWork],
        session: URLSession
    ) -> AsyncStream<(ProbeWork, ConnectionResolution)> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: (ProbeWork, ConnectionResolution).self) { group in
                    var next = 0

                    func addNext() {
                        guard next < works.count else { return }
                        let work = works[next]
                        next += 1
                        group.addTask {
                            (
                                work,
                                await ServerProbe.resolve(
                                    plans: work.plans,
                                    serverName: work.name,
                                    session: session
                                )
                            )
                        }
                    }

                    for _ in 0..<maximumConcurrentConnects {
                        addNext()
                    }

                    while let result = await group.next() {
                        continuation.yield(result)
                        addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Connects (or re-connects) a single server and commits its state.
    /// Returns the live connection, or nil with the failure recorded in `states`.
    @discardableResult
    func connect(to server: PlexServer, priority: ServerPriorityStore? = nil) async -> PlexServerConnection? {
        register([server], priority: priority)

        let serverID = server.clientIdentifier
        // A server the user turned off stays off, whatever asked for it: a
        // stray request must not be able to quietly bring it back.
        guard isEnabled(serverID) else {
            markDisabled(serverID: serverID)
            return nil
        }

        let generation = self.generation
        switch makeWork(for: server) {
        case let .unavailable(state):
            states[serverID] = state
            return nil
        case let .ready(work):
            if states[serverID]?.isConnected != true {
                states[serverID] = .connecting
            }
            let session = self.session
            let resolution = await ServerProbe.resolve(
                plans: work.plans,
                serverName: work.name,
                session: session
            )
            commit(resolution, work: work, generation: generation)
            return states[serverID]?.connection
        }
    }

    /// Whether the user's order has this server switched on. Unknown servers are
    /// enabled, exactly like `ServerPriorityStore.isEnabled`.
    func isEnabled(_ serverID: String) -> Bool {
        priorityStore?.isEnabled(serverID) ?? true
    }

    // MARK: - State transitions

    /// Records a session established elsewhere — currently only the cold-launch
    /// restore, which re-adopts last launch's endpoints before any probe runs.
    func adopt(
        server: PlexServer,
        baseURL: URL,
        token: String,
        connection: PlexConnection?,
        priority: ServerPriorityStore? = nil
    ) {
        register([server], priority: priority)
        let serverID = server.clientIdentifier
        states[serverID] = .connected(
            PlexServerConnection(
                serverID: serverID,
                name: server.name,
                owned: server.owned,
                sourceTitle: server.sourceTitle,
                baseURL: baseURL,
                token: token,
                connection: connection
            )
        )
        Self.saveToken(token, serverID: serverID)
        Self.rememberBaseURL(baseURL, serverID: serverID)
        if let uri = connection?.uri.nilIfEmpty {
            Self.rememberLastGoodConnection(uri, serverID: serverID)
        }
    }

    /// The server rejected our token. Per server on purpose: one stale share
    /// must never sign the account out of every other server.
    func markUnauthorized(serverID: String) {
        states[serverID] = .unauthorized
        Self.deleteToken(serverID: serverID)
    }

    func markOffline(serverID: String, reason: String) {
        states[serverID] = .offline(reason)
    }

    func markDisabled(serverID: String) {
        states[serverID] = .disabled
    }

    /// Forgets every session. Sign-out and Plex Home switches only — a failing
    /// request must never take the whole pool down.
    ///
    /// The generation is bumped so a probe that is still in flight cannot
    /// commit its result into the session that replaces this one. Credentials of
    /// servers this launch never saw are dropped by `PlexService`, which knows
    /// the stored priority order and snapshots; the pool only owns what it has
    /// seen itself.
    func clear(forgetCredentials: Bool = true) {
        if forgetCredentials {
            for serverID in knownServerIDs {
                Self.deleteToken(serverID: serverID)
            }
            UserDefaults.standard.removeObject(forKey: Self.defaultsSnapshotsKey)
        }
        generation &+= 1
        states = [:]
        servers = [:]
        order = []
        decoders = [:]
    }

    // MARK: - Persistence
    //
    // Everything a cold launch needs to be usable before plex.tv answers:
    // tokenless server snapshots (shared), plus a token, a base URL and the
    // last connection that worked per server.

    /// Tokenless snapshots of every server this account has seen, in priority
    /// order. Replaces the single-server `PlexServerData` blob.
    static let defaultsSnapshotsKey = "PlexServerSnapshots"

    static func lastGoodConnectionKey(serverID: String) -> String {
        "\(PlexService.defaultsLastGoodConnectionURIKey).\(serverID)"
    }

    static func baseURLKey(serverID: String) -> String {
        "\(PlexService.defaultsServerURLKey).\(serverID)"
    }

    static func tokenKey(serverID: String) -> String {
        "\(PlexService.keychainServerTokenKey).\(serverID)"
    }

    static func storedSnapshots() -> [PlexServer] {
        guard let data = UserDefaults.standard.data(forKey: defaultsSnapshotsKey),
              let servers = try? JSONDecoder().decode([PlexServer].self, from: data) else {
            return []
        }
        return servers
    }

    static func saveSnapshots(_ servers: [PlexServer]) {
        guard let data = try? JSONEncoder().encode(servers.map(\.withoutAccessToken)) else { return }
        UserDefaults.standard.set(data, forKey: defaultsSnapshotsKey)
    }

    /// The endpoint the last successful session actually used. Kept next to the
    /// last-good connection URI because the two can differ: an HTTPS connection
    /// whose HTTP fallback won reports the former and is reached over the latter.
    static func storedBaseURL(serverID: String) -> URL? {
        UserDefaults.standard
            .string(forKey: baseURLKey(serverID: serverID))?
            .nilIfEmpty
            .flatMap(URL.init(string:))
    }

    static func rememberBaseURL(_ baseURL: URL, serverID: String) {
        UserDefaults.standard.set(baseURL.absoluteString, forKey: baseURLKey(serverID: serverID))
    }

    static func lastGoodConnectionURI(serverID: String) -> String? {
        UserDefaults.standard.string(forKey: lastGoodConnectionKey(serverID: serverID))?.nilIfEmpty
    }

    static func rememberLastGoodConnection(_ uri: String, serverID: String) {
        UserDefaults.standard.set(uri, forKey: lastGoodConnectionKey(serverID: serverID))
    }

    static func storedToken(serverID: String) -> String? {
        guard let data = KeychainHelper.load(key: tokenKey(serverID: serverID)),
              let token = String(data: data, encoding: .utf8)?.nilIfEmpty else {
            return nil
        }
        return token
    }

    static func saveToken(_ token: String, serverID: String) {
        KeychainHelper.save(key: tokenKey(serverID: serverID), data: Data(token.utf8))
    }

    static func deleteToken(serverID: String) {
        KeychainHelper.delete(key: tokenKey(serverID: serverID))
    }

    /// Everything this server needs to be restored is gone. Sign-out only.
    static func forget(serverID: String) {
        deleteToken(serverID: serverID)
        UserDefaults.standard.removeObject(forKey: baseURLKey(serverID: serverID))
        UserDefaults.standard.removeObject(forKey: lastGoodConnectionKey(serverID: serverID))
    }

    /// Moves the pre-multi-server session onto the per-server keys, so an
    /// upgrading install stays signed in and still restores on a cold launch.
    /// Runs once: the caller deletes the legacy keys afterwards.
    static func migrateLegacyState(
        serverID: String,
        token: String?,
        lastGoodURI: String?,
        baseURL: URL?,
        snapshot: PlexServer
    ) {
        if storedToken(serverID: serverID) == nil, let token = token?.nilIfEmpty {
            saveToken(token, serverID: serverID)
        }
        if lastGoodConnectionURI(serverID: serverID) == nil, let lastGoodURI = lastGoodURI?.nilIfEmpty {
            rememberLastGoodConnection(lastGoodURI, serverID: serverID)
        }
        if storedBaseURL(serverID: serverID) == nil, let baseURL {
            rememberBaseURL(baseURL, serverID: serverID)
        }
        if !storedSnapshots().contains(where: { $0.clientIdentifier == serverID }) {
            saveSnapshots(storedSnapshots() + [snapshot])
        }
    }

    // MARK: - Candidates

    /// Candidate endpoints for one server, in priority order.
    static func connectionCandidates(for server: PlexServer) -> [ConnectionCandidate] {
        var candidates: [ConnectionCandidate] = []
        var seen = Set<String>()

        for connection in server.sortedConnections where !connection.isKnownUnreachableAddress {
            if connection.local, let httpFallbackURI = connection.httpFallbackURI {
                append(uri: httpFallbackURI, connection: connection, seen: &seen, into: &candidates)
            }

            append(uri: connection.uri, connection: connection, seen: &seen, into: &candidates)

            if !connection.local, let httpFallbackURI = connection.httpFallbackURI {
                append(uri: httpFallbackURI, connection: connection, seen: &seen, into: &candidates)
            }
        }

        return preferringLastGoodConnection(
            in: candidates,
            lastGoodURI: lastGoodConnectionURI(serverID: server.clientIdentifier)
        )
    }

    private static func append(
        uri: String,
        connection: PlexConnection,
        seen: inout Set<String>,
        into candidates: inout [ConnectionCandidate]
    ) {
        guard let baseURL = URL(string: uri),
              seen.insert(baseURL.absoluteString).inserted,
              let probeURL = identityURL(for: baseURL) else {
            return
        }

        candidates.append(
            ConnectionCandidate(baseURL: baseURL, probeURL: probeURL, connection: connection)
        )
    }

    private static func identityURL(for baseURL: URL) -> URL? {
        let base = baseURL.absoluteString
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URLComponents(string: trimmed + "/identity")?.url
    }

    /// Floats the last connection that successfully served this device to the
    /// front of its own priority tier ("remember which one works and stay on
    /// it") without ever promoting it across tiers — so a remembered remote
    /// connection never outranks a reachable LAN connection when we're home.
    private static func preferringLastGoodConnection(
        in candidates: [ConnectionCandidate],
        lastGoodURI: String?
    ) -> [ConnectionCandidate] {
        guard let lastGoodURI else { return candidates }

        return candidates.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            if left.connection.sortPriority != right.connection.sortPriority {
                return left.connection.sortPriority < right.connection.sortPriority
            }
            let leftIsLastGood = left.connection.uri == lastGoodURI
            let rightIsLastGood = right.connection.uri == lastGoodURI
            if leftIsLastGood != rightIsLastGood {
                return leftIsLastGood
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    // MARK: - Internals

    private struct ProbeWork: Sendable {
        let serverID: String
        let name: String
        /// The token this probe authenticated with. It travels with the work so
        /// two probes of the same server can never consume each other's token
        /// and turn a perfectly good session into `.unauthorized`.
        let token: String
        let plans: [ServerProbe.Plan]
    }

    private enum WorkResolution {
        case ready(ProbeWork)
        case unavailable(ServerConnectionState)
    }

    /// Files the snapshots away and re-sorts the known servers by priority.
    /// Never drops a server the pool already knows about: `connect(to:)` hands
    /// in a single server and must not wipe the rest of the ordering.
    private func register(_ discovered: [PlexServer], priority: ServerPriorityStore?) {
        if let priority {
            priorityStore = priority
        }

        for server in discovered where !server.clientIdentifier.isEmpty {
            servers[server.clientIdentifier] = server.withoutAccessToken
            if states[server.clientIdentifier] == nil {
                states[server.clientIdentifier] = .idle
            }
            if !order.contains(server.clientIdentifier) {
                order.append(server.clientIdentifier)
            }
        }

        guard let priority else { return }

        order = order.enumerated()
            .sorted { lhs, rhs in
                let leftRank = priority.rank(of: lhs.element)
                let rightRank = priority.rank(of: rhs.element)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// `order` plus anything the pool knows about that priority has not ranked.
    private var orderedIdentifiers: [String] {
        var identifiers = order.filter { states[$0] != nil }
        let known = Set(identifiers)
        for serverID in states.keys where !known.contains(serverID) {
            identifiers.append(serverID)
        }
        return identifiers
    }

    private func makeWork(for server: PlexServer) -> WorkResolution {
        let serverID = server.clientIdentifier
        guard !serverID.isEmpty else {
            return .unavailable(.offline("Server has no identifier"))
        }
        guard let token = server.usableAccessToken ?? Self.storedToken(serverID: serverID) else {
            return .unavailable(.unauthorized)
        }

        let candidates = Self.connectionCandidates(for: server)
        guard !candidates.isEmpty else {
            return .unavailable(.offline("No reachable connections for \(server.name)"))
        }

        var headers = baseHeaders
        headers["X-Plex-Token"] = token
        let plans = ServerProbe.makePlans(candidates: candidates, headers: headers)
        guard !plans.isEmpty else {
            return .unavailable(.offline("Could not connect to \(server.name)"))
        }

        return .ready(ProbeWork(serverID: serverID, name: server.name, token: token, plans: plans))
    }

    private func commit(_ resolution: ConnectionResolution, work: ProbeWork, generation: Int) {
        let serverID = work.serverID
        // A sign-out or Plex Home switch happened while this probe was running:
        // its result belongs to a session that no longer exists.
        guard generation == self.generation else { return }
        // The user can switch a server off mid-probe, and a disabled server is
        // ignored entirely — session included.
        guard isEnabled(serverID) else {
            states[serverID] = .disabled
            return
        }
        guard let server = servers[serverID] else { return }

        switch resolution {
        case let .connected(baseURL, connection):
            let token = work.token
            Self.rememberLastGoodConnection(connection.uri, serverID: serverID)
            Self.rememberBaseURL(baseURL, serverID: serverID)
            Self.saveToken(token, serverID: serverID)
            states[serverID] = .connected(
                PlexServerConnection(
                    serverID: serverID,
                    name: server.name,
                    owned: server.owned,
                    sourceTitle: server.sourceTitle,
                    baseURL: baseURL,
                    token: token,
                    connection: connection
                )
            )
        case .unauthorized:
            plexAuthLogger.notice(
                "Server \(server.name, privacy: .public) rejected its access token"
            )
            states[serverID] = .unauthorized
        case let .failed(reason):
            states[serverID] = .offline(reason)
        }
    }
}
