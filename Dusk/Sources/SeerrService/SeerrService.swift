import Foundation

@MainActor
@Observable
final class SeerrService {
    private static let defaultsBaseURLKey = "SeerrBaseURL"
    private static let defaultsServerIDKey = "SeerrPlexServerID"

    private let plexService: PlexService
    private let sessionDelegate: SeerrURLSessionDelegate
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private var storedSessions: [SeerrStoredSession]
    private(set) var configuredBaseURL: URL?
    private(set) var configuredPlexServerID: String?
    private(set) var currentUser: SeerrUser?
    private(set) var publicSettings: SeerrPublicSettings?
    private(set) var isConnecting = false
    private(set) var lastConnectionError: String?

    init(plexService: PlexService) {
        self.plexService = plexService
        self.sessionDelegate = SeerrURLSessionDelegate()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        self.session = URLSession(
            configuration: configuration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )

        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.storedSessions = SeerrCredentialStore.load()

        if let value = UserDefaults.standard.string(forKey: Self.defaultsBaseURLKey) {
            self.configuredBaseURL = URL(string: value)
        }
        self.configuredPlexServerID = UserDefaults.standard.string(
            forKey: Self.defaultsServerIDKey
        )
    }

    var isConfigured: Bool {
        configuredBaseURL != nil
    }

    var isConnected: Bool {
        currentStoredSession != nil
    }

    var isAvailableForCurrentContext: Bool {
        guard isConnected,
              configuredPlexServerID == plexService.currentServerIdentifier,
              plexService.activeProfileID != nil else {
            return false
        }
        return true
    }

    var connectionSubtitle: String {
        if let currentUser {
            return "Connected as \(currentUser.displayName)"
        }
        if isConnected {
            return "Connected"
        }
        if isConfigured {
            return "Connect this Plex user"
        }
        return "Not configured"
    }

    func contextDidChange() async {
        currentUser = nil
        publicSettings = nil
        lastConnectionError = nil

        guard plexService.isAuthenticated else {
            storedSessions = []
            SeerrCredentialStore.removeAll()
            return
        }

        guard isAvailableForCurrentContext else { return }
        do {
            try await refreshConnectionStatus()
        } catch {
            lastConnectionError = error.localizedDescription
        }
    }

    func connect(serverURLString: String) async throws {
        guard !isConnecting else { return }
        guard let profileID = plexService.activeProfileID,
              let serverID = plexService.currentServerIdentifier,
              let plexToken = plexService.activeAccountToken else {
            throw SeerrServiceError.notConnected
        }

        isConnecting = true
        lastConnectionError = nil
        defer { isConnecting = false }

        let baseURL = try await resolveServerURL(serverURLString: serverURLString)
        var cookies: [String: String] = [:]
        let settings: SeerrPublicSettings = try await send(
            baseURL: baseURL,
            path: "api/v1/settings/public",
            cookies: &cookies
        )

        let body = try encoder.encode(SeerrPlexLoginBody(authToken: plexToken))
        let user: SeerrUser
        do {
            user = try await send(
                baseURL: baseURL,
                method: "POST",
                path: "api/v1/auth/plex",
                body: body,
                cookies: &cookies
            )
        } catch let error as SeerrServiceError {
            if case .permissionDenied = error {
                throw SeerrServiceError.plexUserNotAllowed
            }
            if case .authenticationRequired = error {
                throw SeerrServiceError.plexUserNotAllowed
            }
            throw error
        }

        guard cookies["connect.sid"] != nil else {
            throw SeerrServiceError.invalidResponse
        }

        configuredBaseURL = baseURL
        configuredPlexServerID = serverID
        publicSettings = settings
        currentUser = user
        persistConfiguration()
        storedSessions.removeAll {
            $0.baseURL != baseURL.absoluteString || $0.serverID != serverID
        }
        upsertSession(
            SeerrStoredSession(
                baseURL: baseURL.absoluteString,
                profileID: profileID,
                serverID: serverID,
                cookies: cookies
            )
        )
    }

    func resolveServerURL(serverURLString: String) async throws -> URL {
        let candidates = try Self.connectionCandidates(from: serverURLString)
        var lastError: (any Error)?

        for baseURL in candidates {
            var cookies: [String: String] = [:]
            do {
                let settings: SeerrPublicSettings = try await send(
                    baseURL: baseURL,
                    path: "api/v1/settings/public",
                    cookies: &cookies
                )
                guard settings.initialized,
                      settings.isPlexServer,
                      settings.mediaServerLogin else {
                    throw SeerrServiceError.plexLoginUnavailable
                }
                return baseURL
            } catch let error as SeerrServiceError {
                if case .plexLoginUnavailable = error {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SeerrServiceError.invalidServerURL
    }

    func disconnect() async {
        if let baseURL = configuredBaseURL, var stored = currentStoredSession {
            _ = try? await sendWithoutResponse(
                baseURL: baseURL,
                method: "POST",
                path: "api/v1/auth/logout",
                cookies: &stored.cookies
            )
        }

        storedSessions = []
        SeerrCredentialStore.removeAll()

        configuredBaseURL = nil
        configuredPlexServerID = nil
        currentUser = nil
        publicSettings = nil
        lastConnectionError = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsBaseURLKey)
        UserDefaults.standard.removeObject(forKey: Self.defaultsServerIDKey)
    }

    func refreshConnectionStatus() async throws {
        guard let baseURL = configuredBaseURL,
              var stored = currentStoredSession else {
            currentUser = nil
            throw SeerrServiceError.notConnected
        }

        guard stored.serverID == plexService.currentServerIdentifier else {
            currentUser = nil
            throw SeerrServiceError.serverMismatch
        }

        do {
            let settings: SeerrPublicSettings = try await send(
                baseURL: baseURL,
                path: "api/v1/settings/public",
                cookies: &stored.cookies
            )
            let user: SeerrUser = try await send(
                baseURL: baseURL,
                path: "api/v1/auth/me",
                cookies: &stored.cookies
            )
            publicSettings = settings
            currentUser = user
            upsertSession(stored)
        } catch let error as SeerrServiceError {
            guard case .authenticationRequired = error else {
                throw error
            }
            try await reauthenticate(baseURL: baseURL, stored: &stored)
            upsertSession(stored)
        }
    }

    func search(query: String) async throws -> [SeerrSearchMedia] {
        let response: SeerrSearchResponse = try await authenticatedSend(
            path: "api/v1/search",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "page", value: "1"),
            ]
        )
        return response.results.filter { $0.supportedMediaType != nil }
    }

    func movieDetails(id: Int) async throws -> SeerrMovieDetails {
        try await authenticatedSend(path: "api/v1/movie/\(id)")
    }

    func tvDetails(id: Int) async throws -> SeerrTVDetails {
        try await authenticatedSend(path: "api/v1/tv/\(id)")
    }

    func seasonDetails(tvID: Int, seasonNumber: Int) async throws -> SeerrSeasonDetails {
        try await authenticatedSend(path: "api/v1/tv/\(tvID)/season/\(seasonNumber)")
    }

    func quota() async throws -> SeerrQuotaResponse {
        try await ensureConnected()
        guard let userID = currentUser?.id else {
            throw SeerrServiceError.notConnected
        }
        return try await authenticatedSend(path: "api/v1/user/\(userID)/quota")
    }

    @discardableResult
    func requestMovie(id: Int) async throws -> SeerrMediaRequest {
        try await createRequest(
            SeerrCreateRequestBody(
                mediaType: .movie,
                mediaId: id,
                seasons: nil,
                is4k: false
            )
        )
    }

    @discardableResult
    func requestTV(id: Int, seasons: SeerrRequestedSeasons) async throws -> SeerrMediaRequest {
        try await createRequest(
            SeerrCreateRequestBody(
                mediaType: .tv,
                mediaId: id,
                seasons: seasons,
                is4k: false
            )
        )
    }

    func requestState(
        mediaInfo: SeerrMediaInfo?,
        seasonNumber: Int? = nil
    ) -> SeerrRequestState {
        SeerrRequestState.resolve(
            mediaInfo: mediaInfo,
            currentUserID: currentUser?.id,
            seasonNumber: seasonNumber
        )
    }

    func posterURL(path: String?, width: Int = 500) -> URL? {
        let size: String
        switch width {
        case ...185: size = "w185"
        case ...342: size = "w342"
        case ...500: size = "w500"
        default: size = "w780"
        }
        return imageURL(path: path, size: size)
    }

    func backdropURL(path: String?, width: Int = 1280) -> URL? {
        let size: String
        switch width {
        case ...300: size = "w300"
        case ...780: size = "w780"
        default: size = "w1280"
        }
        return imageURL(path: path, size: size)
    }

    func stillURL(path: String?) -> URL? {
        imageURL(path: path, size: "w300")
    }

    static func normalizedBaseURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SeerrServiceError.invalidServerURL
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return try normalizedExplicitBaseURL(from: candidate)
    }

    private static func connectionCandidates(from value: String) throws -> [URL] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SeerrServiceError.invalidServerURL
        }

        if trimmed.contains("://") {
            return [try normalizedExplicitBaseURL(from: trimmed)]
        }

        return [
            try normalizedExplicitBaseURL(from: "https://\(trimmed)"),
            try normalizedExplicitBaseURL(from: "http://\(trimmed)"),
        ]
    }

    private static func normalizedExplicitBaseURL(from value: String) throws -> URL {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.nilIfEmpty != nil,
              components.user == nil,
              components.password == nil else {
            throw SeerrServiceError.invalidServerURL
        }

        components.query = nil
        components.fragment = nil
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path == "/" {
            components.path = ""
        }
        components.scheme = scheme
        components.host = components.host?.lowercased()

        guard let url = components.url else {
            throw SeerrServiceError.invalidServerURL
        }
        return url
    }

    private func ensureConnected() async throws {
        guard isAvailableForCurrentContext else {
            throw isConfigured ? SeerrServiceError.notConnected : SeerrServiceError.notConfigured
        }
        if currentUser == nil {
            try await refreshConnectionStatus()
        }
    }

    private func authenticatedSend<T: Decodable>(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> T {
        try await ensureConnected()
        guard let baseURL = configuredBaseURL else {
            throw SeerrServiceError.notConfigured
        }
        var stored = try requireStoredSession()
        do {
            let value: T = try await send(
                baseURL: baseURL,
                method: method,
                path: path,
                queryItems: queryItems,
                body: body,
                cookies: &stored.cookies
            )
            upsertSession(stored)
            return value
        } catch let error as SeerrServiceError {
            guard case .authenticationRequired = error else { throw error }
            try await reauthenticate(baseURL: baseURL, stored: &stored)
            let value: T = try await send(
                baseURL: baseURL,
                method: method,
                path: path,
                queryItems: queryItems,
                body: body,
                cookies: &stored.cookies
            )
            upsertSession(stored)
            return value
        }
    }

    private func createRequest(_ body: SeerrCreateRequestBody) async throws -> SeerrMediaRequest {
        try await ensureConnected()
        guard currentUser?.canRequest(body.mediaType) == true else {
            throw SeerrServiceError.permissionDenied(
                "This Seerr account does not have permission to request this media type."
            )
        }
        let payload = try encoder.encode(body)
        let request: SeerrMediaRequest = try await authenticatedSend(
            method: "POST",
            path: "api/v1/request",
            body: payload
        )
        return request
    }

    private func reauthenticate(
        baseURL: URL,
        stored: inout SeerrStoredSession
    ) async throws {
        guard let plexToken = plexService.activeAccountToken else {
            throw SeerrServiceError.notConnected
        }
        stored.cookies.removeValue(forKey: "connect.sid")
        let body = try encoder.encode(SeerrPlexLoginBody(authToken: plexToken))
        let user: SeerrUser = try await send(
            baseURL: baseURL,
            method: "POST",
            path: "api/v1/auth/plex",
            body: body,
            cookies: &stored.cookies
        )
        guard stored.cookies["connect.sid"] != nil else {
            throw SeerrServiceError.invalidResponse
        }
        currentUser = user
    }

    private func imageURL(path: String?, size: String) -> URL? {
        guard let baseURL = configuredBaseURL,
              let path = path?.nilIfEmpty else {
            return nil
        }
        return endpointURL(
            baseURL: baseURL,
            path: "imageproxy/tmdb/t/p/\(size)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        )
    }

    private var currentStoredSession: SeerrStoredSession? {
        guard let baseURL = configuredBaseURL?.absoluteString,
              let profileID = plexService.activeProfileID,
              let serverID = plexService.currentServerIdentifier else {
            return nil
        }
        return storedSessions.first {
            $0.baseURL == baseURL && $0.profileID == profileID && $0.serverID == serverID
        }
    }

    private func requireStoredSession() throws -> SeerrStoredSession {
        guard let currentStoredSession else {
            throw SeerrServiceError.notConnected
        }
        return currentStoredSession
    }

    private func upsertSession(_ stored: SeerrStoredSession) {
        if storedSessions.contains(stored) {
            return
        }
        storedSessions.removeAll { $0.matches(stored) }
        storedSessions.append(stored)
        SeerrCredentialStore.save(storedSessions)
    }

    private func persistConfiguration() {
        if let configuredBaseURL {
            UserDefaults.standard.set(
                configuredBaseURL.absoluteString,
                forKey: Self.defaultsBaseURLKey
            )
        }
        if let configuredPlexServerID {
            UserDefaults.standard.set(
                configuredPlexServerID,
                forKey: Self.defaultsServerIDKey
            )
        }
    }

    private func send<T: Decodable>(
        baseURL: URL,
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        cookies: inout [String: String]
    ) async throws -> T {
        let (data, response, updatedCookies) = try await perform(
            baseURL: baseURL,
            method: method,
            path: path,
            queryItems: queryItems,
            body: body,
            cookies: cookies
        )
        cookies = updatedCookies
        try validate(response: response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SeerrServiceError.invalidResponse
        }
    }

    private func sendWithoutResponse(
        baseURL: URL,
        method: String,
        path: String,
        cookies: inout [String: String]
    ) async throws {
        let (data, response, updatedCookies) = try await perform(
            baseURL: baseURL,
            method: method,
            path: path,
            queryItems: [],
            body: nil,
            cookies: cookies
        )
        cookies = updatedCookies
        try validate(response: response, data: data)
    }

    private func perform(
        baseURL: URL,
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Data?,
        cookies: [String: String]
    ) async throws -> (Data, HTTPURLResponse, [String: String]) {
        guard let url = endpointURL(baseURL: baseURL, path: path, queryItems: queryItems) else {
            throw SeerrServiceError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if !cookies.isEmpty {
            let cookieValue = cookies
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")
            request.setValue(cookieValue, forHTTPHeaderField: "Cookie")
        }
        if let xsrfToken = cookies["XSRF-TOKEN"] {
            request.setValue(xsrfToken, forHTTPHeaderField: "X-XSRF-TOKEN")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SeerrServiceError.invalidResponse
        }

        var updatedCookies = cookies
        let headerFields = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, element in
            guard let key = element.key as? String,
                  let value = element.value as? String else {
                return
            }
            result[key] = value
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url) {
            if cookie.value.isEmpty || cookie.expiresDate.map({ $0 <= .now }) == true {
                updatedCookies.removeValue(forKey: cookie.name)
            } else {
                updatedCookies[cookie.name] = cookie.value
            }
        }

        return (data, httpResponse, updatedCookies)
    }

    private func endpointURL(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        var url = baseURL
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component))
        }
        guard !queryItems.isEmpty else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        if response.statusCode == 202 {
            let message = (try? decoder.decode(SeerrErrorResponse.self, from: data))
                .flatMap { $0.message?.nilIfEmpty ?? $0.error?.nilIfEmpty }
                ?? "There are no new seasons available to request."
            throw SeerrServiceError.noSeasonsAvailable(message)
        }

        guard !(200...299).contains(response.statusCode) else { return }

        let message = (try? decoder.decode(SeerrErrorResponse.self, from: data))
            .flatMap { $0.message?.nilIfEmpty ?? $0.error?.nilIfEmpty }
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)

        switch response.statusCode {
        case 401:
            throw SeerrServiceError.authenticationRequired(message)
        case 403:
            throw SeerrServiceError.permissionDenied(message)
        case 409:
            throw SeerrServiceError.requestConflict(message)
        default:
            throw SeerrServiceError.serverError(message)
        }
    }
}

private struct SeerrPlexLoginBody: Encodable {
    let authToken: String
}

private struct SeerrErrorResponse: Decodable {
    let message: String?
    let error: String?
}

private extension SeerrStoredSession {
    func matches(_ other: SeerrStoredSession) -> Bool {
        baseURL == other.baseURL &&
            profileID == other.profileID &&
            serverID == other.serverID
    }
}

private final class SeerrURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.currentRequest?.url,
              let redirectedURL = request.url,
              Self.sameOrigin(originalURL, redirectedURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
            lhs.host?.lowercased() == rhs.host?.lowercased() &&
            effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
