import Foundation

/// A live session with one Plex server: where to reach it and with which token.
///
/// Everything that talks to a server routes through one of these, so a request,
/// an image URL, or a playback decision can never silently land on a different
/// server than the item it belongs to.
struct PlexServerConnection: Sendable, Hashable, Identifiable {
    var id: String { serverID }

    /// The server's `clientIdentifier` (machine identifier).
    let serverID: String
    let name: String
    /// True when the signed-in account owns this server, as opposed to it being
    /// shared with them. Drives the Plex Pass remote-streaming check.
    let owned: Bool
    /// Owner name for a shared server ("Shared by X"); nil for owned servers.
    let sourceTitle: String?
    let baseURL: URL
    /// Server-scoped access token. Per server, never the account token.
    let token: String
    /// The connection the probe won on, when it is known. Restored sessions can
    /// come back without one; callers must treat nil as "locality unknown".
    let connection: PlexConnection?

    /// True only when we positively know the session runs over the LAN.
    var isLocal: Bool {
        guard let connection else { return false }
        return connection.local && !connection.relay
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
        return !connection.local
    }
}
