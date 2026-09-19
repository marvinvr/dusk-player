import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension PlexService {
    var basePlexHeaders: [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": "Dusk",
            "X-Plex-Version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ]
    }

    /// Every Plex header except the token. `ServerPool` is handed this once so a
    /// connection probe is byte-for-byte what a real request would be.
    var plexRequestHeaders: [String: String] {
        var headers = basePlexHeaders

        #if os(tvOS)
        headers["X-Plex-Platform"] = "tvOS"
        headers["X-Plex-Device-Name"] = "Apple TV"
        #elseif canImport(UIKit)
        headers["X-Plex-Platform"] = "iOS"
        headers["X-Plex-Device-Name"] = UIDevice.current.name
        #endif

        return headers
    }

    func plexTVRequest<T: Decodable>(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil,
        formBody: [String: String]? = nil,
        jsonBody: Data? = nil,
        accountToken: String? = nil,
        timeoutInterval: TimeInterval? = nil,
        retriesFreshAuthentication: Bool = true
    ) async throws -> T {
        let data = try await rawPlexTVRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            formBody: formBody,
            jsonBody: jsonBody,
            accountToken: accountToken,
            timeoutInterval: timeoutInterval,
            retriesFreshAuthentication: retriesFreshAuthentication
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
        retriesFreshAuthentication: Bool = true
    ) async throws -> Data {
        guard let url = buildURL(base: Self.plexTVBase, path: path, queryItems: queryItems) else {
            throw PlexServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        applyHeaders(to: &request, token: accountToken ?? activeAccountToken)

        if let formBody {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = formBody.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = components.query?.data(using: .utf8)
        } else if let jsonBody {
            // plex.tv's account-settings endpoint only accepts a JSON body.
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }

        return try await executeRequest(
            request,
            retriesFreshAuthentication: retriesFreshAuthentication
        )
    }

    /// Sends a request to one server.
    ///
    /// - Parameters:
    ///   - timeoutInterval: Overrides the session's 15s request timeout for this
    ///     call only. Use it for server work that legitimately takes longer than
    ///     a metadata read, such as asking the server to fetch a subtitle file
    ///     from its provider. Leave it nil everywhere else so the global default
    ///     keeps screens responsive.
    ///   - serverID: Which server to talk to. nil means the primary one, which
    ///     is what every not-yet-routed call site still gets.
    ///
    /// Recovery is per server on purpose: a 401 or a dead endpoint marks *that*
    /// server and re-races *its* connections. It never clears the session, so
    /// one stale share can no longer sign the user out of every other server.
    /// Recovery is also coalesced and rate-limited per server — see
    /// `recoverServer(serverID:)`.
    func rawServerRequest(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil,
        timeoutInterval: TimeInterval? = nil,
        serverID: String? = nil
    ) async throws -> Data {
        let targetID = try resolveServerID(serverID)

        // A server the user switched off is not a server that is merely down:
        // never reconnect it behind their back, whoever is asking.
        guard pool.state(for: targetID) != .disabled else {
            throw PlexServiceError.noServerConnected
        }

        if pool.connection(for: targetID) == nil {
            try await refreshServerAuthorization(serverID: targetID)
        }

        do {
            return try await sendRawServerRequest(
                method: method,
                path: path,
                queryItems: queryItems,
                timeoutInterval: timeoutInterval,
                serverID: targetID
            )
        } catch let error as PlexServiceError where error == .unauthorized {
            plexAuthLogger.notice("Server request unauthorized for \(path, privacy: .public); attempting token refresh")
            pool.markUnauthorized(serverID: targetID)
            try await refreshServerAuthorization(serverID: targetID)
            do {
                return try await sendRawServerRequest(
                    method: method,
                    path: path,
                    queryItems: queryItems,
                    timeoutInterval: timeoutInterval,
                    serverID: targetID
                )
            } catch let retryError as PlexServiceError where retryError == .unauthorized {
                // Leave the rest of the pool alone; only this server is out.
                pool.markUnauthorized(serverID: targetID)
                throw retryError
            }
        } catch let error as PlexServiceError where shouldRefreshServerEndpoint(after: error) {
            plexAuthLogger.notice("Server request failed for \(path, privacy: .public); refreshing Plex endpoint")
            try await recoverServer(serverID: targetID)
            return try await sendRawServerRequest(
                method: method,
                path: path,
                queryItems: queryItems,
                timeoutInterval: timeoutInterval,
                serverID: targetID
            )
        }
    }

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
            throw PlexServiceError.noServerConnected
        }
        return primaryID
    }

    private func sendRawServerRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?,
        timeoutInterval: TimeInterval? = nil,
        serverID: String
    ) async throws -> Data {
        guard let connection = pool.connection(for: serverID) else {
            switch pool.state(for: serverID) {
            case .unauthorized:
                throw isAuthenticationFresh ? PlexServiceError.authenticationPending : PlexServiceError.unauthorized
            default:
                throw PlexServiceError.noServerConnected
            }
        }

        guard let url = buildURL(base: connection.baseURL.absoluteString, path: path, queryItems: queryItems) else {
            throw PlexServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        applyHeaders(to: &request, token: connection.token)

        return try await executeRequest(request)
    }

    private func shouldRefreshServerEndpoint(after error: PlexServiceError) -> Bool {
        switch error {
        case .networkError(_):
            return activeAccountToken != nil
        case .httpError(let statusCode):
            return activeAccountToken != nil
                && [404, 408, 421, 502, 503, 504].contains(statusCode)
        default:
            return false
        }
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

    func fetchHubs(
        path: String,
        queryItems: [URLQueryItem]? = nil,
        serverID: String? = nil
    ) async throws -> [PlexHub] {
        let targetID = try resolveServerID(serverID)
        let data = try await rawServerRequest(path: path, queryItems: queryItems, serverID: targetID)
        let response = try decodeJSON(HubResponse.self, from: data, serverID: targetID)
        return response.MediaContainer.Hub ?? []
    }

    func applyHeaders(to request: inout URLRequest, token: String?) {
        var headers = plexRequestHeaders

        if let token {
            headers["X-Plex-Token"] = token
        }

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    func executeRequest(
        _ request: URLRequest,
        retriesFreshAuthentication: Bool = true
    ) async throws -> Data {
        let operation: () async throws -> Data = {
            let data: Data
            let response: URLResponse

            do {
                (data, response) = try await self.session.data(for: request)
            } catch {
                throw PlexServiceError.networkError(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw PlexServiceError.networkError("Invalid response")
            }

            switch http.statusCode {
            case 200...299:
                return data
            case 401:
                throw PlexServiceError.unauthorized
            default:
                throw PlexServiceError.httpError(statusCode: http.statusCode)
            }
        }

        if retriesFreshAuthentication {
            return try await retryAfterFreshAuthentication(operation)
        }
        return try await operation()
    }

    /// Decodes a server payload with the server stamped onto the decoder, so
    /// every model — including nested ones — records which server it came from.
    /// Pass `serverID: nil` only for account-level (plex.tv) payloads.
    func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data, serverID: String? = nil) throws -> T {
        do {
            return try pool.decoder(for: serverID).decode(type, from: data)
        } catch {
            throw PlexServiceError.decodingError(String(describing: error))
        }
    }

    func buildURL(base: String, path: String, queryItems: [URLQueryItem]? = nil) -> URL? {
        let base = base.hasSuffix("/") ? String(base.dropLast()) : base
        let path = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: base + path) else { return nil }
        if let queryItems, !queryItems.isEmpty {
            let queryNames = Set(queryItems.map(\.name))
            let existingItems = (components.queryItems ?? []).filter { !queryNames.contains($0.name) }
            components.queryItems = existingItems + queryItems
        }
        return components.url
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
/// `/library/metadata/{ratingKey}/subtitles`. Some servers answer `size: 0`
/// with no `Stream` key, so the array stays optional.
struct StreamResponse<T: Decodable>: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let size: Int?
        let Stream: [T]?
    }
}

struct HubResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Hub: [PlexHub]?
    }
}

struct HubItemsResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Metadata: [PlexItem]?
        let Directory: [PlexItem]?
    }
}
