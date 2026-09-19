import Foundation

/// How the account's servers are doing as a whole.
///
/// Home, Libraries and Search all have to render the same handful of bad states
/// — nothing enabled, nothing reachable, some servers missing — so the
/// classification lives next to the pool instead of being re-derived in each of
/// them. `ServerPool.availability` is the only producer.
enum ServerAvailability: Equatable {
    /// Nothing has been discovered yet; the first connect pass is still ahead.
    case unknown
    /// Enabled servers are being probed and none has answered yet.
    case connecting
    /// At least one server is usable. `offlineServerNames` lists the enabled
    /// servers that are not, so a partial outage can be noted inline instead of
    /// replacing the content.
    case ready(offlineServerNames: [String])
    /// The account has servers, but every one of them is switched off in
    /// Server Priority. Only the user can resolve this, so it gets its own
    /// empty state.
    case allDisabled
    /// Every enabled server failed. Carries the first reason we have, which is
    /// usually the most useful one.
    case unreachable(reason: String?)

    /// True when content can be shown, even if some servers are missing.
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// True while the outcome is still open, so a screen should wait rather
    /// than claim there is nothing to show.
    var isPending: Bool {
        switch self {
        case .unknown, .connecting: true
        default: false
        }
    }

    /// The enabled servers that are currently unusable, in priority order.
    var offlineServerNames: [String] {
        if case let .ready(names) = self { return names }
        return []
    }
}

extension ServerPool {
    /// Known servers in priority order, including any the priority store has
    /// not ranked yet.
    var priorityOrderedIdentifiers: [String] {
        let ranked = order.filter { states[$0] != nil }
        let known = Set(ranked)
        return ranked + states.keys.filter { !known.contains($0) }.sorted()
    }

    /// The server's display name, or a neutral placeholder when the snapshot is
    /// gone (a server can be in the priority list without being discovered).
    func displayName(for serverID: String) -> String {
        servers[serverID]?.name ?? "Plex server"
    }

    var availability: ServerAvailability {
        guard !states.isEmpty else { return .unknown }

        var offlineNames: [String] = []
        var firstReason: String?
        var hasConnected = false
        var isStillProbing = false
        var enabledCount = 0

        for serverID in priorityOrderedIdentifiers {
            let state = states[serverID] ?? .idle
            guard state != .disabled else { continue }
            enabledCount += 1

            switch state {
            case .connected:
                hasConnected = true
            case .idle, .connecting:
                isStillProbing = true
            case .unauthorized:
                offlineNames.append(displayName(for: serverID))
                firstReason = firstReason
                    ?? "\(displayName(for: serverID)) did not accept this device."
            case let .offline(reason):
                offlineNames.append(displayName(for: serverID))
                firstReason = firstReason ?? reason
            case .disabled:
                break
            }
        }

        guard enabledCount > 0 else { return .allDisabled }
        if hasConnected { return .ready(offlineServerNames: offlineNames) }
        if isStillProbing { return .connecting }
        return .unreachable(reason: firstReason)
    }
}

/// A `.task(id:)` key for anything that merges content across servers.
///
/// It changes when a server connects or drops out, when the priority order or
/// an enabled flag changes, and when the Plex Home profile changes — exactly the
/// moments a merged screen (Home, Libraries, Search) has to reload. Screens
/// should key their load task on this instead of on a single server identifier.
struct ServerContentRevision: Hashable {
    let serverIDs: [String]
    let priorityRevision: Int
    let profileID: String?
}

extension PlexService {
    var serverContentRevision: ServerContentRevision {
        ServerContentRevision(
            serverIDs: pool.connections.map(\.serverID),
            priorityRevision: serverPriority.revision,
            profileID: activeProfileID
        )
    }
}

/// The words Dusk uses for one server's state and ownership.
///
/// Shared so the Server Priority list, an inline "server is offline" note, and
/// anything else that names a server all say the same thing.
enum ServerStatusText {
    static func label(for state: ServerConnectionState) -> String {
        switch state {
        case .idle:
            "Not connected"
        case .connecting:
            "Connecting…"
        case let .connected(connection):
            locality(of: connection)
        case .unauthorized:
            "Not authorized"
        case .offline:
            "Offline"
        case .disabled:
            "Disabled"
        }
    }

    /// Relay is checked first: a relayed session is also "not local", and the
    /// distinction matters because relay is the slow path.
    static func locality(of connection: PlexServerConnection) -> String {
        if connection.isRelay { return "Relay" }
        if connection.isLocal { return "Local" }
        if connection.isRemote { return "Remote" }
        // A restored session comes back without the winning connection, so its
        // locality is genuinely unknown until the next probe.
        return "Connected"
    }

    static func ownership(owned: Bool, sourceTitle: String?) -> String {
        guard !owned else { return "Your server" }
        guard let sourceTitle = sourceTitle?.nilIfEmpty else { return "Shared with you" }
        return "Shared by \(sourceTitle)"
    }

    static func ownership(of server: PlexServer) -> String {
        ownership(owned: server.owned, sourceTitle: server.sourceTitle)
    }
}
