import Foundation
import OSLog

extension PlexService {
    func discoverServers() async throws -> [PlexServer] {
        guard authToken != nil else { throw PlexServiceError.notAuthenticated }

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
            applyHeaders(to: &request, token: authToken)
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

    func connect(to server: PlexServer) async throws {
        try await retryAfterFreshAuthentication {
            let server = try await connectableServer(from: server)
            let candidates = connectionCandidates(for: server)
            let token = try serverAccessToken(for: server)
            var lastFailure = "Could not connect to \(server.name)"
            var receivedUnauthorized = false

            for candidate in candidates {
                var request = URLRequest(url: candidate.probeURL)
                request.httpMethod = "GET"
                request.timeoutInterval = candidate.connection.local ? 20 : 8
                applyHeaders(to: &request, token: token)

                do {
                    let (_, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        lastFailure = "Invalid response from \(server.name)"
                        continue
                    }

                    if http.statusCode == 401 {
                        receivedUnauthorized = true
                        lastFailure = "HTTP 401 from \(server.name)"
                        continue
                    }

                    guard (200...299).contains(http.statusCode) else {
                        lastFailure = "HTTP \(http.statusCode) from \(server.name)"
                        continue
                    }

                    try await validateServerAuthorization(
                        baseURL: candidate.baseURL,
                        token: token,
                        timeout: request.timeoutInterval
                    )

                    setServer(server, baseURL: candidate.baseURL, accessToken: token)
                    return
                } catch {
                    lastFailure = error.localizedDescription
                }
            }

            if receivedUnauthorized {
                plexAuthLogger.notice("Server connect received 401 for \(server.name, privacy: .public) during bootstrap=\(self.isAuthenticationFresh, privacy: .public)")
                throw isAuthenticationFresh
                    ? AuthenticationBootstrapError.waitingForPropagation
                    : PlexServiceError.unauthorized
            }

            throw PlexServiceError.networkError(lastFailure)
        }
    }

    func refreshConnectedServerConnection() async throws {
        guard authToken != nil else { throw PlexServiceError.notAuthenticated }
        guard isConnected || connectedServer != nil else { throw PlexServiceError.noServerConnected }

        let currentServerID = connectedServer?.clientIdentifier.nilIfEmpty
            ?? UserDefaults.standard.string(forKey: Self.defaultsServerIDKey)?.nilIfEmpty
        let refreshedServers = try await discoverServers()

        let refreshedServer: PlexServer?
        if let currentServerID {
            refreshedServer = refreshedServers.first { $0.clientIdentifier == currentServerID }
        } else if refreshedServers.count == 1 {
            refreshedServer = refreshedServers[0]
        } else {
            refreshedServer = nil
        }

        guard let refreshedServer else {
            if currentServerID != nil {
                clearServer()
            }
            throw PlexServiceError.noServerConnected
        }

        plexAuthLogger.notice("Refreshing Plex server endpoint for \(refreshedServer.name, privacy: .public)")
        try await connect(to: refreshedServer)
    }

    func connectionCandidates(for server: PlexServer) -> [ConnectionCandidate] {
        var candidates: [ConnectionCandidate] = []
        var seen = Set<String>()

        for connection in server.sortedConnections where !connection.isKnownUnreachableAddress {
            if connection.local, let httpFallbackURI = connection.httpFallbackURI {
                appendConnectionCandidate(
                    uri: httpFallbackURI,
                    connection: connection,
                    seen: &seen,
                    into: &candidates
                )
            }

            appendConnectionCandidate(
                uri: connection.uri,
                connection: connection,
                seen: &seen,
                into: &candidates
            )

            if !connection.local, let httpFallbackURI = connection.httpFallbackURI {
                appendConnectionCandidate(
                    uri: httpFallbackURI,
                    connection: connection,
                    seen: &seen,
                    into: &candidates
                )
            }
        }

        return candidates
    }

    func appendConnectionCandidate(
        uri: String,
        connection: PlexConnection,
        seen: inout Set<String>,
        into candidates: inout [ConnectionCandidate]
    ) {
        guard let baseURL = URL(string: uri),
              seen.insert(baseURL.absoluteString).inserted,
              let probeURL = buildURL(base: baseURL.absoluteString, path: "/identity") else {
            return
        }

        candidates.append(
            ConnectionCandidate(
                baseURL: baseURL,
                probeURL: probeURL,
                connection: connection
            )
        )
    }

    private func connectableServer(from server: PlexServer) async throws -> PlexServer {
        if isAuthenticationFresh {
            let refreshedServers = try await discoverServers()

            if let refreshedServer = refreshedServers.first(where: { $0.clientIdentifier == server.clientIdentifier }) {
                guard refreshedServer.usableAccessToken != nil else {
                    throw AuthenticationBootstrapError.waitingForPropagation
                }

                return refreshedServer
            }
        }

        guard server.usableAccessToken != nil else {
            throw PlexServiceError.networkError("Missing server access token for \(server.name)")
        }

        return server
    }

    func refreshConnectedServerAuthorization() async throws {
        guard let connectedServer else {
            throw PlexServiceError.noServerConnected
        }

        plexAuthLogger.notice("Refreshing server authorization for \(connectedServer.name, privacy: .public)")

        try await refreshConnectedServerConnection()
        plexAuthLogger.notice("Refreshed server authorization for \(connectedServer.name, privacy: .public)")
    }

    private func validateServerAuthorization(
        baseURL: URL,
        token: String,
        timeout: TimeInterval
    ) async throws {
        guard let validationURL = buildURL(base: baseURL.absoluteString, path: "/library/sections") else {
            throw PlexServiceError.invalidURL
        }

        var request = URLRequest(url: validationURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        applyHeaders(to: &request, token: token)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlexServiceError.networkError("Invalid validation response")
        }

        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw PlexServiceError.unauthorized
        default:
            throw PlexServiceError.httpError(statusCode: http.statusCode)
        }
    }

    private func serverAccessToken(for server: PlexServer) throws -> String {
        if let token = server.usableAccessToken {
            return token
        }

        if isAuthenticationFresh {
            throw AuthenticationBootstrapError.waitingForPropagation
        }

        throw PlexServiceError.unauthorized
    }
}

struct ConnectionCandidate {
    let baseURL: URL
    let probeURL: URL
    let connection: PlexConnection
}
