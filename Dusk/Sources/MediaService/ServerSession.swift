import Foundation

/// A live session with one server: where to reach it, with which token, and the
/// provider that speaks to it.
///
/// Everything that talks to a server routes through one of these, so a request,
/// an image URL, or a playback decision can never silently land on a different
/// server than the item it belongs to.
struct ServerSession: Sendable, Hashable, Identifiable {
    var id: String { serverID }

    /// The server's `clientIdentifier` (machine identifier).
    let serverID: String
    let name: String
    /// True when the signed-in account owns this server, as opposed to it being
    /// shared with them.
    let owned: Bool
    /// Owner name for a shared server ("Shared by X"); nil for owned servers.
    let sourceTitle: String?
    let baseURL: URL
    /// Server-scoped access token. Per server, never the account token.
    let token: String
    /// The connection the probe won on, when it is known. Restored sessions can
    /// come back without one; callers must treat nil as "locality unknown".
    let connection: ServerEndpoint?
    /// False for a session restored from the last launch (the fast path) until
    /// a quick `/identity` check on it passes; see
    /// `MediaService.validateRestoredEndpoint`. Probed sessions are verified.
    var isVerified = true
    /// The server's provider, built by the pool when it records the session.
    /// Nothing routes through it yet (wave 4 does); nil only for a session
    /// built outside the pool, such as in a test. Not part of `==`/`hash`, so
    /// a re-recorded session compares exactly as it did before providers.
    var provider: (any MediaServerProvider)? = nil

    /// True only when we positively know the session runs over the LAN.
    var isLocal: Bool {
        connection?.isOnLocalNetwork == true
    }

    /// True only when we positively know the session runs over Plex's relay.
    var isRelay: Bool {
        connection?.relay == true
    }

    /// True only when we positively know the session leaves the local network.
    /// Unknown locality deliberately reads as "not remote" so a restored
    /// session is never wrongly treated as being away from home.
    var isRemote: Bool {
        guard let connection else { return false }
        return !connection.isOnLocalNetwork
    }

    static func == (lhs: ServerSession, rhs: ServerSession) -> Bool {
        lhs.serverID == rhs.serverID
            && lhs.name == rhs.name
            && lhs.owned == rhs.owned
            && lhs.sourceTitle == rhs.sourceTitle
            && lhs.baseURL == rhs.baseURL
            && lhs.token == rhs.token
            && lhs.connection == rhs.connection
            && lhs.isVerified == rhs.isVerified
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(serverID)
        hasher.combine(name)
        hasher.combine(owned)
        hasher.combine(sourceTitle)
        hasher.combine(baseURL)
        hasher.combine(token)
        hasher.combine(connection)
        hasher.combine(isVerified)
    }
}
