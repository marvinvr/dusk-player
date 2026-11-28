import Foundation
import OSLog

/// The facade's request entry points. Routing and self-healing are the
/// account's routed send (`PlexServerRouter`, 04 §8), which asks this service's
/// pool for each step (`SessionRecovering`); one attempt, the headers and the
/// URL/decode helpers are `PlexClient`'s. plex.tv requests go through the
/// account provider's single path (`PlexAccountProvider.plexTVData`).
extension MediaService {
    var clientIdentifier: String { client.clientIdentifier }
    var session: URLSession { client.session }
    var slowQuerySession: URLSession { client.slowQuerySession }
    var probeSession: URLSession { client.probeSession }
    var bootstrapSession: URLSession { client.bootstrapSession }
    var basePlexHeaders: [String: String] { client.basePlexHeaders }
    var plexRequestHeaders: [String: String] { client.plexRequestHeaders }

    func plexTVRequest<T: Decodable>(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil,
        formBody: [String: String]? = nil,
        jsonBody: Data? = nil,
        accountToken: String? = nil,
        timeoutInterval: TimeInterval? = nil,
        retriesFreshAuthentication: Bool = true,
        bootstrap: Bool = false
    ) async throws -> T {
        let data = try await rawPlexTVRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            formBody: formBody,
            jsonBody: jsonBody,
            accountToken: accountToken,
            timeoutInterval: timeoutInterval,
            retriesFreshAuthentication: retriesFreshAuthentication,
            bootstrap: bootstrap
        )
        return try decodeJSON(T.self, from: data)
    }

    /// - Parameter timeoutInterval: Overrides the session's 15s request timeout
    ///   for this call only. Use it for plex.tv requests that are a nicety rather
    ///   than a requirement, so a LAN-only session (the server answers, the
    ///   internet does not) cannot stall a screen behind them.
    func rawPlexTVRequest(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil,
        formBody: [String: String]? = nil,
        jsonBody: Data? = nil,
        accountToken: String? = nil,
        timeoutInterval: TimeInterval? = nil,
        retriesFreshAuthentication: Bool = true,
        bootstrap: Bool = false
    ) async throws -> Data {
        try await plexAccount.plexTVData(
            method: method,
            path: path,
            queryItems: queryItems,
            formBody: formBody,
            jsonBody: jsonBody,
            accountToken: accountToken,
            timeoutInterval: timeoutInterval,
            retriesFreshAuthentication: retriesFreshAuthentication,
            bootstrap: bootstrap
        )
    }

    /// Sends a request to one server through the routed send
    /// (`PlexServerRouter.rawServerRequest`): `serverID` nil is the primary
    /// server; a missing session is re-authorized, a 401 refreshes the token
    /// and a dead endpoint re-selects that server's connection.
    func rawServerRequest(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil,
        timeoutInterval: TimeInterval? = nil,
        serverID: String? = nil
    ) async throws -> Data {
        try await plexAccount.router.rawServerRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            timeoutInterval: timeoutInterval,
            serverID: serverID
        )
    }

    static let restoredEndpointValidationTimeout = PlexServerRouter.restoredEndpointValidationTimeout

    /// Resolves an explicit server, or the primary one when the caller has not
    /// been routed yet.
    func resolveServerID(_ serverID: String?) throws -> String {
        if let serverID = serverID?.nilIfEmpty {
            return serverID
        }
        // Falling back to the highest-priority *known* server (rather than only
        // a connected one) keeps the failure specific: the request then reports
        // "not authorized" instead of a generic "no server" when that is why the
        // session is missing.
        guard let primaryID = pool.primary?.serverID ?? pool.priorityOrderedIdentifiers.first else {
            throw MediaServiceError.noServerConnected
        }
        return primaryID
    }

    /// The provider every facet route of `serverID` goes to (04 §5.2): the
    /// server's session's when it is connected, else one built for the id,
    /// whose first request heals the session as a request always has. It is
    /// looked up by id, never only through a live session, so a server
    /// without one still reconnects.
    ///
    /// nil (or empty) is the primary-tracking provider: its facets pass nil
    /// on, so each request resolves the highest-priority server when it is
    /// sent.
    func serverProvider(for serverID: String?) -> any MediaServerProvider {
        let id = serverID?.nilIfEmpty
        if let id, let provider = pool.provider(for: id) {
            return provider
        }
        let factory = providers.factory(for: serverRegistry.kind(for: id)) ?? providers.factories[0]
        return factory.makeServerProvider(
            ServerSessionSeed(serverID: id ?? "", name: "", version: nil, owned: false, sourceTitle: nil)
        )
    }

    func fetchMetadata<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]? = nil,
        serverID: String? = nil
    ) async throws -> [T] {
        let targetID = try resolveServerID(serverID)
        let data = try await rawServerRequest(path: path, queryItems: queryItems, serverID: targetID)
        let response = try decodeJSON(MetadataResponse<T>.self, from: data, serverID: targetID)
        return response.MediaContainer.Metadata ?? []
    }

    func fetchDirectories<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]? = nil,
        serverID: String? = nil
    ) async throws -> [T] {
        let targetID = try resolveServerID(serverID)
        let data = try await rawServerRequest(path: path, queryItems: queryItems, serverID: targetID)
        let response = try decodeJSON(DirectoryResponse<T>.self, from: data, serverID: targetID)
        return response.MediaContainer.Directory ?? []
    }

    func applyHeaders(to request: inout URLRequest, token: String?) {
        client.applyHeaders(to: &request, token: token)
    }

    /// One request through `client`, retried once when a 401 arrives right
    /// after a fresh sign-in (`retryAfterFreshAuthentication`).
    func executeRequest(
        _ request: URLRequest,
        retriesFreshAuthentication: Bool = true,
        using session: URLSession? = nil
    ) async throws -> Data {
        try await plexAccount.router.executeRequest(
            request,
            retriesFreshAuthentication: retriesFreshAuthentication,
            using: session
        )
    }

    /// Decodes a server payload with the server stamped onto the decoder, so
    /// every model — including nested ones — records which server it came from.
    /// Pass `serverID: nil` only for account-level (plex.tv) payloads.
    func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data, serverID: String? = nil) throws -> T {
        try client.decode(type, from: data, using: pool.decoder(for: serverID))
    }

    func buildURL(base: String, path: String, queryItems: [URLQueryItem]? = nil) -> URL? {
        client.buildURL(base: base, path: path, queryItems: queryItems)
    }
}

struct MetadataResponse<T: Decodable>: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Metadata: [T]?
    }
}

struct DirectoryResponse<T: Decodable>: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Directory: [T]?
    }
}

/// Envelope for endpoints that answer with a bare `Stream` array, such as
/// `/library/metadata/{itemID}/subtitles`. Some servers answer `size: 0`
/// with no `Stream` key, so the array stays optional.
struct StreamResponse<T: Decodable>: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let size: Int?
        let Stream: [T]?
    }
}
