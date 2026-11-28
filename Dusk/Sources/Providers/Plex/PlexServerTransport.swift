import Foundation

/// How a Plex server facet reaches its server for now: the facade's routed
/// request (`MediaService.rawServerRequest`), which picks the server,
/// re-authorizes a missing session, validates a restored endpoint, refreshes
/// the token on a 401 and re-selects a failing connection, plus the decoder
/// that stamps the server id.
///
/// `PlexClient` sends single attempts only and a provider is built without
/// the routing, so the facade builds the catalog, rating, home, playlists,
/// user-data and Live TV facets itself with itself as the transport. Once
/// recovery moves out of the facade (04 §8) the facets send through
/// `PlexClient` and the facade routes through `session.provider`.
@MainActor
protocol PlexServerTransport: AnyObject, Sendable {
    func rawServerRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?,
        timeoutInterval: TimeInterval?,
        serverID: String?
    ) async throws -> Data

    func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data, serverID: String?) throws -> T
}
