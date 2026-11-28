import Foundation

/// The pool's side of a provider's routed request (docs/jellyfin/04-architecture.md
/// §8): which server a nil id means, each server's live session and state,
/// and the healing a failing request asks for. Self-healing stays in the pool;
/// a provider's request core calls in here between attempts and re-reads the
/// session after every await.
///
/// `MediaService` implements it over `ServerPool` and its per-server recovery
/// (`+Servers`).
@MainActor
protocol SessionRecovering: AnyObject {
    /// The id itself, or the highest-priority known server for nil.
    func resolveServerID(_ serverID: String?) throws -> String
    /// The server's live session; the primary one for nil.
    func session(for serverID: String?) -> ServerSession?
    func connectionState(for serverID: String) -> ServerConnectionState
    /// Re-authorizes one server: a missing session, or after a 401.
    func refreshServerAuthorization(serverID: String) async throws
    /// Re-races one server's connections. Coalesced per server, with a
    /// cooldown after a failure.
    @discardableResult
    func recoverServer(serverID: String, reason: String) async throws -> ServerSession
    func markUnauthorized(serverID: String)
    func markVerified(serverID: String, baseURL: URL)
    /// The decoder that stamps `serverID` (nil: the primary server) on every
    /// model it decodes.
    func serverDecoder(for serverID: String?) -> JSONDecoder
    /// A server the signed-in account lists, connected or not.
    func knownServer(for serverID: String) -> PlexServer?
}
