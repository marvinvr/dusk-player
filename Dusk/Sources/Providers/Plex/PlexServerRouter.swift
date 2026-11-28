import Foundation
import OSLog

/// Plex's routed send (docs/jellyfin/04-architecture.md §8): the request core
/// every Plex facet sends through. It picks the server, re-authorizes a missing
/// session, validates a restored endpoint, refreshes the token on a 401 and
/// re-selects a failing connection, asking the pool for each step through
/// `SessionRecovering`. One attempt is `PlexClient.send`.
///
/// One per Plex account (`PlexAccountProvider.router`); every server provider
/// of that account hands it to its facets as their transport. `recovering` is
/// set by `MediaService` when it is built; without it nothing is sent.
@MainActor
final class PlexServerRouter {
    let client: PlexClient
    weak var account: PlexAccountProvider?
    weak var recovering: (any SessionRecovering)?
    /// The plain decoder account payloads have always been read with.
    let decoder = JSONDecoder()

    private var endpointValidationTasks: [String: Task<Bool, Never>] = [:]

    static let restoredEndpointValidationTimeout: TimeInterval = 3

    init(client: PlexClient) {
        self.client = client
    }

    private func pool() throws -> any SessionRecovering {
        guard let recovering else { throw MediaServiceError.noServerConnected }
        return recovering
    }

    /// The token account-scoped calls go out with (the active Home member's).
    var activeAccountToken: String? { account?.state.activeAccountToken }
    private var isAuthenticationFresh: Bool { account?.isAuthenticationFresh ?? false }

    // MARK: - Server requests

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
    /// `MediaService.recoverServer(serverID:)`.
    func rawServerRequest(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil,
        timeoutInterval: TimeInterval? = nil,
        serverID: String? = nil
    ) async throws -> Data {
        let pool = try pool()
        let targetID = try pool.resolveServerID(serverID)

        // A server the user switched off is not a server that is merely down:
        // never reconnect it behind their back, whoever is asking.
        guard pool.connectionState(for: targetID) != .disabled else {
            throw MediaServiceError.noServerConnected
        }

        if pool.session(for: targetID) == nil {
            try await pool.refreshServerAuthorization(serverID: targetID)
        }
        // Before anything is sent to it, the restored-endpoint check included.
        if let session = pool.session(for: targetID) {
            try Self.requirePlex(session)
        }
        // A session whose endpoint no request can be built on can never
        // answer. Re-select instead of failing with "Invalid URL." until the
        // next full pass.
        if let baseURL = pool.session(for: targetID)?.baseURL,
           !PlexTransportSecurity.allowsToken(in: baseURL) {
            plexConnectionLogger.notice("Server endpoint is unusable; re-selecting connection")
            try await pool.recoverServer(serverID: targetID, reason: "Unusable endpoint")
        }
        // The fast path: last launch's endpoint is used straight away, but only
        // after one quick check that it still is this server. A dead restored
        // endpoint (left home, VPN off) would otherwise hold every first
        // request for its full timeout before failing over.
        if let restored = pool.session(for: targetID), !restored.isVerified,
           await !validateRestoredEndpoint(restored) {
            try Task.checkCancellation()
            if pool.session(for: targetID)?.baseURL == restored.baseURL {
                try await pool.recoverServer(serverID: targetID, reason: "Restored endpoint failed validation")
            }
        }
        let endpoint = pool.session(for: targetID)?.baseURL

        do {
            return try await sendRawServerRequest(
                method: method,
                path: path,
                queryItems: queryItems,
                timeoutInterval: timeoutInterval,
                serverID: targetID
            )
        } catch let error as MediaServiceError where error == .unauthorized {
            plexAuthLogger.notice("Server request unauthorized for \(path, privacy: .public); attempting token refresh")
            pool.markUnauthorized(serverID: targetID)
            try await pool.refreshServerAuthorization(serverID: targetID)
            do {
                return try await sendRawServerRequest(
                    method: method,
                    path: path,
                    queryItems: queryItems,
                    timeoutInterval: timeoutInterval,
                    serverID: targetID
                )
            } catch let retryError as MediaServiceError where retryError == .unauthorized {
                // Leave the rest of the pool alone; only this server is out.
                pool.markUnauthorized(serverID: targetID)
                throw retryError
            }
        } catch let error as MediaServiceError where shouldRefreshServerEndpoint(after: error) {
            // A cancelled request is not a broken endpoint. URLSession reports
            // cancellation as an ordinary transport failure, so without this a
            // superseded screen load would re-probe every server it still had
            // in flight — and a probe that then fails marks the server offline,
            // which drops its content out of every merged screen.
            try Task.checkCancellation()
            // Another request (or the network-change pass) already moved this
            // server to a different endpoint while this one was failing: just
            // use it, there is nothing to re-select.
            if let current = pool.session(for: targetID), let endpoint, current.baseURL != endpoint {
                return try await sendRawServerRequest(
                    method: method, path: path, queryItems: queryItems,
                    timeoutInterval: timeoutInterval, serverID: targetID
                )
            }
            plexConnectionLogger.notice("Server request failed for \(path, privacy: .public) (\(error.localizedDescription, privacy: .public)); re-selecting connection")
            let recovered = try await pool.recoverServer(
                serverID: targetID, reason: "Request failed: \(error.localizedDescription)"
            )
            // Timed out on an address that still answers its probe: the query
            // was slow, the connection is fine. Plex keeps working on the
            // abandoned query, so sending it again only queues a second copy
            // behind the first, which then fails the same way twice as late.
            if error == .requestTimedOut, recovered.baseURL == endpoint {
                throw error
            }
            return try await sendRawServerRequest(
                method: method,
                path: path,
                queryItems: queryItems,
                timeoutInterval: timeoutInterval,
                serverID: targetID
            )
        }
    }

    /// `/identity` + `/library/sections` on a restored session's endpoint, capped
    /// at a few seconds whatever the locality. Coalesced per server; marks the
    /// session verified when it passes.
    func validateRestoredEndpoint(_ connection: ServerSession) async -> Bool {
        let serverID = connection.serverID
        if let running = endpointValidationTasks[serverID] {
            return await running.value
        }
        let candidate = ConnectionCandidate(
            baseURL: connection.baseURL,
            connection: connection.connection ?? ServerEndpoint.synthesized(for: connection.baseURL),
            source: .lastKnownGood
        )
        var headers = client.plexRequestHeaders
        headers["X-Plex-Token"] = connection.token
        let session = client.probeSession
        let task = Task { () -> Bool in
            let outcome = await ConnectionSelector.probe(
                candidate, serverID: serverID, headers: headers, session: session,
                timeout: Self.restoredEndpointValidationTimeout
            )
            return outcome.isReachable
        }
        endpointValidationTasks[serverID] = task
        let passed = await task.value
        endpointValidationTasks[serverID] = nil
        if passed {
            recovering?.markVerified(serverID: serverID, baseURL: connection.baseURL)
        } else {
            plexConnectionLogger.notice("Restored endpoint \(connection.baseURL.absoluteString, privacy: .public) failed validation; re-selecting")
        }
        return passed
    }

    private func sendRawServerRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?,
        timeoutInterval: TimeInterval? = nil,
        serverID: String
    ) async throws -> Data {
        let pool = try pool()
        guard let connection = pool.session(for: serverID) else {
            switch pool.connectionState(for: serverID) {
            case .unauthorized:
                throw isAuthenticationFresh ? MediaServiceError.authenticationPending : MediaServiceError.unauthorized
            default:
                throw MediaServiceError.noServerConnected
            }
        }
        try Self.requirePlex(connection)

        guard let url = client.buildURL(base: connection.baseURL.absoluteString, path: path, queryItems: queryItems) else {
            throw MediaServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        client.applyHeaders(to: &request, token: connection.token)

        let needsSlowQuerySession = (timeoutInterval ?? 0) > PlexClient.requestResourceTimeout
        return try await executeRequest(request, using: needsSlowQuerySession ? client.slowQuerySession : nil)
    }

    /// A Plex request never goes to another provider's server: its path means
    /// nothing there, and its token header would carry that server's
    /// credential under Plex's name. A route that has not moved behind a
    /// facet yet fails instead.
    static func requirePlex(_ connection: ServerSession) throws {
        if let kind = connection.provider?.descriptor.kind, kind != .plex {
            throw MediaServiceError.noServerConnected
        }
    }

    /// Connection-type failures: refused, unreachable, DNS, TLS, timeouts
    /// (all `networkError`), a URL that cannot be built on the endpoint
    /// (`invalidURL`), and gateway-ish HTTP statuses from a proxy in front of a
    /// server that went away.
    private func shouldRefreshServerEndpoint(after error: MediaServiceError) -> Bool {
        switch error {
        case .networkError(_), .invalidURL:
            return activeAccountToken != nil
        case .httpError(let statusCode):
            return activeAccountToken != nil
                && [404, 408, 421, 502, 503, 504].contains(statusCode)
        default:
            return false
        }
    }

    // MARK: - Sending and decoding

    /// One request through `client`, retried once when a 401 arrives right
    /// after a fresh sign-in (`PlexAccountProvider.retryAfterFreshAuthentication`).
    func executeRequest(
        _ request: URLRequest,
        retriesFreshAuthentication: Bool = true,
        using session: URLSession? = nil
    ) async throws -> Data {
        try client.validate(request)
        let operation: () async throws -> Data = {
            try await self.client.send(request, using: session)
        }

        if retriesFreshAuthentication, let account {
            return try await account.retryAfterFreshAuthentication(operation)
        }
        return try await operation()
    }

    /// Decodes a server payload with the server stamped onto the decoder, so
    /// every model — including nested ones — records which server it came from.
    /// `serverID: nil` stamps the primary server, as the pool's decoder does.
    func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data, serverID: String? = nil) throws -> T {
        try client.decode(type, from: data, using: try pool().serverDecoder(for: serverID))
    }

    // MARK: - Scrub previews

    /// Re-authorizes the server first when it has no session, and refreshes
    /// the token once on a 401. Nothing else: no endpoint re-selection, which
    /// a missing index (404) must never trigger.
    func scrubPreviewData(path: String, accept: String, serverID: String) async throws -> Data {
        let pool = try pool()
        if pool.session(for: serverID) == nil {
            try await pool.refreshServerAuthorization(serverID: serverID)
        }
        if let session = pool.session(for: serverID) {
            try Self.requirePlex(session)
        }

        do {
            return try await sendScrubPreviewData(path: path, accept: accept, serverID: serverID)
        } catch let error as MediaServiceError where error == .unauthorized {
            try await pool.refreshServerAuthorization(serverID: serverID)
            return try await sendScrubPreviewData(path: path, accept: accept, serverID: serverID)
        }
    }

    private func sendScrubPreviewData(path: String, accept: String, serverID: String) async throws -> Data {
        let pool = try pool()
        guard let connection = pool.session(for: serverID) else {
            switch pool.connectionState(for: serverID) {
            case .unauthorized:
                throw isAuthenticationFresh ? MediaServiceError.authenticationPending : MediaServiceError.unauthorized
            default:
                throw MediaServiceError.noServerConnected
            }
        }
        try Self.requirePlex(connection)

        guard let url = client.buildURL(base: connection.baseURL.absoluteString, path: path) else {
            throw MediaServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        client.applyHeaders(to: &request, token: connection.token)
        request.setValue(accept, forHTTPHeaderField: "Accept")

        return try await executeRequest(request)
    }
}

// MARK: - Facet transports

extension PlexServerRouter: PlexServerTransport, PlexMarkersTransport {}

extension PlexServerRouter: PlexPlaybackRouting {
    func plexPlaybackSession(for serverID: String?) -> ServerSession? {
        recovering?.session(for: serverID)
    }

    func resolveServerID(_ serverID: String?) throws -> String {
        try pool().resolveServerID(serverID)
    }
}

extension PlexServerRouter: PlexLiveTVTransport {
    var clientIdentifier: String { client.clientIdentifier }

    func liveTVDirectPlayURL(sessionPath: String, sessionIdentifier: String, serverID: String) async -> URL? {
        await PlexPlayback(client: client, serverID: serverID, router: self).liveDirectPlayURL(
            sessionPath: sessionPath,
            sessionIdentifier: sessionIdentifier
        )
    }

    /// Reads only `url` and `outcome` of the playback facet's live stream.
    func liveTVTranscodeStream(
        sessionPath: String,
        sessionIdentifier: String,
        transcodeSessionID: String,
        serverID: String
    ) async throws -> PlexLiveTVStream {
        let stream = try await PlexPlayback(client: client, serverID: serverID, router: self).liveStream(
            sessionPath: sessionPath,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID
        )
        switch stream.outcome {
        case .transcodeAvailable:
            return .transcode(stream.url)
        case .directPlayOnly:
            return .directPlayOnly
        case .failed(let message):
            return .failed(message)
        }
    }

    func liveTVTokenizedURL(path: String, serverID: String) -> URL? {
        guard let connection = recovering?.session(for: serverID) else { return nil }
        return client.buildURL(
            base: connection.baseURL.absoluteString,
            path: path,
            queryItems: [URLQueryItem(name: "X-Plex-Token", value: connection.token)]
        )
    }
}

extension PlexServerRouter: PlexAccountTransport {
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
    ) async throws -> Data {
        guard let account else { throw MediaServiceError.notAuthenticated }
        return try await account.plexTVData(
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

    func accountServer(for serverID: String) -> AccountServer? {
        recovering?.knownServer(for: serverID)
    }
}
