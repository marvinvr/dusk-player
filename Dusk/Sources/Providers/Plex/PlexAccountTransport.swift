import Foundation

/// How the Plex account facets (`PlexAccountPreferences`, `PlexWatchlist`)
/// reach plex.tv: the facade's routed requests, which add the active
/// profile's token and refresh it on a 401 (`MediaService+Networking`).
/// `PlexClient` sends single attempts only, so until it carries that routing
/// itself (04 §8 `SessionRecovering`) the facade hands itself in, as it does
/// for the server facets (`PlexUserDataTransport`).
@MainActor
protocol PlexAccountTransport: AnyObject, Sendable {
    /// The token account-scoped calls go out with (the active Home member's).
    var activeAccountToken: String? { get }
    /// The decoder account payloads have always been read with.
    var decoder: JSONDecoder { get }

    func plexTVRequest<T: Decodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?,
        formBody: [String: String]?,
        jsonBody: Data?,
        accountToken: String?,
        timeoutInterval: TimeInterval?,
        retriesFreshAuthentication: Bool,
        bootstrap: Bool
    ) async throws -> T

    func rawPlexTVRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?,
        formBody: [String: String]?,
        jsonBody: Data?,
        accountToken: String?,
        timeoutInterval: TimeInterval?,
        retriesFreshAuthentication: Bool,
        bootstrap: Bool
    ) async throws -> Data

    /// Sends a request built by the facet (a host other than plex.tv, or a
    /// header of its own).
    func executeRequest(
        _ request: URLRequest,
        retriesFreshAuthentication: Bool,
        using session: URLSession?
    ) async throws -> Data

    func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data, serverID: String?) throws -> T

    /// A connected server, for building the account's record of one of its
    /// libraries. nil when the server is not in the pool.
    func accountServer(for serverID: String) -> PlexServer?
}
