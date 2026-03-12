import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class PlexService {
    // MARK: - State

    private var authToken: String?
    private(set) var connectedServer: PlexServer?
    private var serverBaseURL: URL?

    var isAuthenticated: Bool { authToken != nil }
    var isConnected: Bool { serverBaseURL != nil }

    // MARK: - Dependencies

    let clientIdentifier: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    // MARK: - Constants

    private static let plexTVBase = "https://plex.tv"
    private static let keychainTokenKey = "PlexAuthToken"
    private static let defaultsClientIDKey = "PlexClientIdentifier"
    private static let defaultsServerURLKey = "PlexServerURL"
    private static let defaultsServerIDKey = "PlexServerID"
    private static let defaultsServerDataKey = "PlexServerData"

    // MARK: - Init

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = AppImageCache.shared
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()

        if let stored = UserDefaults.standard.string(forKey: Self.defaultsClientIDKey) {
            self.clientIdentifier = stored
        } else {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: Self.defaultsClientIDKey)
            self.clientIdentifier = id
        }

        if let data = KeychainHelper.load(key: Self.keychainTokenKey),
           let token = String(data: data, encoding: .utf8) {
            self.authToken = token
        }

        if let urlString = UserDefaults.standard.string(forKey: Self.defaultsServerURLKey),
           let url = URL(string: urlString) {
            self.serverBaseURL = url
        }

        if let serverData = UserDefaults.standard.data(forKey: Self.defaultsServerDataKey),
           let server = try? decoder.decode(PlexServer.self, from: serverData) {
            self.connectedServer = server
        }
    }

    // MARK: - Auth Token Management

    func setAuthToken(_ token: String) {
        authToken = token
        KeychainHelper.save(key: Self.keychainTokenKey, data: Data(token.utf8))
    }

    func clearAuthToken() {
        authToken = nil
        KeychainHelper.delete(key: Self.keychainTokenKey)
    }

    // MARK: - Server Management

    func setServer(_ server: PlexServer, baseURL: URL) {
        connectedServer = server
        serverBaseURL = baseURL
        UserDefaults.standard.set(baseURL.absoluteString, forKey: Self.defaultsServerURLKey)
        UserDefaults.standard.set(server.clientIdentifier, forKey: Self.defaultsServerIDKey)
        if let data = try? encoder.encode(server) {
            UserDefaults.standard.set(data, forKey: Self.defaultsServerDataKey)
        }
    }

    func clearServer() {
        connectedServer = nil
        serverBaseURL = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsServerURLKey)
        UserDefaults.standard.removeObject(forKey: Self.defaultsServerIDKey)
        UserDefaults.standard.removeObject(forKey: Self.defaultsServerDataKey)
    }

    // MARK: - Auth

    func generatePin() async throws -> PlexPin {
        try await plexTVRequest(
            method: "POST",
            path: "/api/v2/pins",
            formBody: ["strong": "true"]
        )
    }

    func checkPin(_ pinId: Int) async throws -> String? {
        let pin: PlexPin = try await plexTVRequest(path: "/api/v2/pins/\(pinId)")
        return pin.authToken
    }

    func signOut() {
        clearAuthToken()
        clearServer()
    }

    /// Construct the Plex auth URL for a given PIN. Opens in a browser for the user to approve.
    func authURL(for pin: PlexPin) -> URL? {
        URL(string: "https://app.plex.tv/auth#?clientID=\(clientIdentifier)&code=\(pin.code)&context%5Bdevice%5D%5Bproduct%5D=Dusk")
    }

    // MARK: - Server Discovery

    func discoverServers() async throws -> [PlexServer] {
        guard authToken != nil else { throw PlexServiceError.notAuthenticated }

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
        applyHeaders(to: &request)
        let data = try await executeRequest(request)

        // Decode each resource individually — non-server resources may fail to
        // parse as PlexServer, so we filter at the JSON level first.
        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PlexServiceError.decodingError("Expected JSON array from resources endpoint")
        }

        return jsonArray.compactMap { json -> PlexServer? in
            guard let provides = json["provides"] as? String, provides.contains("server") else {
                return nil
            }
            guard let itemData = try? JSONSerialization.data(withJSONObject: json) else {
                return nil
            }
            return try? decoder.decode(PlexServer.self, from: itemData)
        }
    }

    func connect(to server: PlexServer) async throws {
        // Try connections in priority order: local → remote → relay.
        for connection in server.sortedConnections {
            guard let url = URL(string: connection.uri) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 5
            applyHeaders(to: &request)

            // Use the server-specific access token if available.
            if let serverToken = server.accessToken {
                request.setValue(serverToken, forHTTPHeaderField: "X-Plex-Token")
            }

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    setServer(server, baseURL: url)
                    return
                }
            } catch {
                continue
            }
        }

        throw PlexServiceError.networkError("Could not connect to \(server.name)")
    }

    // MARK: - Libraries

    func getLibraries() async throws -> [PlexLibrary] {
        try await fetchDirectories(path: "/library/sections")
    }

    func getLibraryItems(sectionId: String, start: Int = 0, size: Int = 50) async throws -> [PlexItem] {
        try await fetchMetadata(
            path: "/library/sections/\(sectionId)/all",
            queryItems: [
                URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(size)),
            ]
        )
    }

    // MARK: - Browsing

    func getSeasons(showKey: String) async throws -> [PlexSeason] {
        try await fetchMetadata(path: "/library/metadata/\(showKey)/children")
    }

    func getEpisodes(seasonKey: String) async throws -> [PlexEpisode] {
        try await fetchMetadata(path: "/library/metadata/\(seasonKey)/children")
    }

    // MARK: - Home

    func getHubs() async throws -> [PlexHub] {
        try await fetchHubs(path: "/hubs")
    }

    func getContinueWatching() async throws -> [PlexItem] {
        try await fetchMetadata(path: "/library/onDeck")
    }

    // MARK: - Search

    func search(query: String) async throws -> [PlexSearchResult] {
        let hubs = try await fetchHubs(
            path: "/hubs/search",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "includeCollections", value: "0"),
            ]
        )
        return hubs
            .filter { !$0.items.isEmpty }
            .map { PlexSearchResult(hub: $0) }
    }

    // MARK: - Media Details

    func getMediaDetails(ratingKey: String) async throws -> PlexMediaDetails {
        let items: [PlexMediaDetails] = try await fetchMetadata(path: "/library/metadata/\(ratingKey)")
        guard let details = items.first else {
            throw PlexServiceError.decodingError("No metadata found for ratingKey \(ratingKey)")
        }
        return details
    }

    // MARK: - People

    func getPerson(personID: String) async throws -> PlexPerson {
        let people: [PlexPerson] = try await fetchDirectories(path: "/library/people/\(personID)")
        guard let person = people.first else {
            throw PlexServiceError.decodingError("No person found for id \(personID)")
        }
        return person
    }

    func getPersonMedia(personID: String) async throws -> [PlexItem] {
        let items: [PlexItem] = try await fetchMetadata(path: "/library/people/\(personID)/media")

        var seen = Set<String>()
        return items
            .filter { $0.type == .movie || $0.type == .show }
            .filter { seen.insert($0.ratingKey).inserted }
    }

    // MARK: - Playback Tracking

    func reportTimeline(ratingKey: String, state: PlaybackState, timeMs: Int, durationMs: Int) async {
        let stateString: String
        switch state {
        case .playing: stateString = "playing"
        case .paused: stateString = "paused"
        default: stateString = "stopped"
        }

        _ = try? await rawServerRequest(
            path: "/:/timeline",
            queryItems: [
                URLQueryItem(name: "ratingKey", value: ratingKey),
                URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
                URLQueryItem(name: "state", value: stateString),
                URLQueryItem(name: "time", value: String(timeMs)),
                URLQueryItem(name: "duration", value: String(durationMs)),
            ]
        )
    }

    func scrobble(ratingKey: String) async throws {
        _ = try await rawServerRequest(
            path: "/:/scrobble",
            queryItems: [
                URLQueryItem(name: "key", value: ratingKey),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            ]
        )
    }

    func unscrobble(ratingKey: String) async throws {
        _ = try await rawServerRequest(
            path: "/:/unscrobble",
            queryItems: [
                URLQueryItem(name: "key", value: ratingKey),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            ]
        )
    }

    // MARK: - Image URLs

    /// Construct a full image URL from a relative Plex image path (thumb, art, etc.).
    /// When a target size is provided, prefer Plex's photo transcoder so the server
    /// returns an image close to the on-screen size instead of the original asset.
    func imageURL(for path: String?, width: Int? = nil, height: Int? = nil) -> URL? {
        guard let path else { return nil }

        if let width, width > 0 || (height ?? 0) > 0,
           let transcodedURL = transcodedImageURL(for: path, width: width, height: height) {
            return transcodedURL
        }

        return directImageURL(for: path)
    }

    // MARK: - Direct Play URL

    /// Construct the direct play URL for a media part.
    /// Format: `{serverURL}{part.key}?X-Plex-Token={token}`
    func directPlayURL(for part: PlexMediaPart) -> URL? {
        guard let baseURL = serverBaseURL else { return nil }
        let urlString = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast()) + part.key
            : baseURL.absoluteString + part.key
        guard var components = URLComponents(string: urlString) else { return nil }
        var items = components.queryItems ?? []
        if let token = authToken {
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}

// MARK: - Networking Foundation

extension PlexService {
    private func directImageURL(for path: String) -> URL? {
        guard let urlString = imageRequestURLString(for: path, includeToken: true) else {
            return nil
        }
        return URL(string: urlString)
    }

    private func transcodedImageURL(for path: String, width: Int, height: Int?) -> URL? {
        guard let baseURL = serverBaseURL,
              let originalURLString = imageRequestURLString(for: path, includeToken: true) else {
            return nil
        }

        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        guard var components = URLComponents(string: base + "/photo/:/transcode") else {
            return nil
        }

        var items = [
            URLQueryItem(name: "width", value: String(max(width, 1))),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "0"),
            URLQueryItem(name: "url", value: originalURLString),
        ]

        if let height, height > 0 {
            items.append(URLQueryItem(name: "height", value: String(height)))
        }

        if let token = authToken {
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }

        components.queryItems = items
        return components.url
    }

    private func imageRequestURLString(for path: String, includeToken: Bool) -> String? {
        if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
            return absoluteURL.absoluteString
        }

        guard let baseURL = serverBaseURL else { return nil }
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        guard var components = URLComponents(string: base + path) else { return nil }

        if includeToken, let token = authToken {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
            components.queryItems = items
        }

        return components.url?.absoluteString
    }

    /// Plex-specific headers sent with every request.
    private var plexHeaders: [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json",
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": "Dusk",
            "X-Plex-Version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ]

        #if os(tvOS)
        headers["X-Plex-Platform"] = "tvOS"
        headers["X-Plex-Device-Name"] = "Apple TV"
        #elseif canImport(UIKit)
        headers["X-Plex-Platform"] = "iOS"
        headers["X-Plex-Device-Name"] = UIDevice.current.name
        #endif

        if let token = authToken {
            headers["X-Plex-Token"] = token
        }

        return headers
    }

    // MARK: - Raw Request Execution

    /// Execute a request against the plex.tv API (responses are plain JSON, no MediaContainer).
    func plexTVRequest<T: Decodable>(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil,
        formBody: [String: String]? = nil
    ) async throws -> T {
        guard let url = buildURL(base: Self.plexTVBase, path: path, queryItems: queryItems) else {
            throw PlexServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        applyHeaders(to: &request)

        if let formBody {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = formBody.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = components.query?.data(using: .utf8)
        }

        let data = try await executeRequest(request)
        return try decodeJSON(T.self, from: data)
    }

    /// Execute a request against the connected Plex server and return raw data.
    func rawServerRequest(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> Data {
        guard let baseURL = serverBaseURL else {
            throw PlexServiceError.noServerConnected
        }

        guard let url = buildURL(base: baseURL.absoluteString, path: path, queryItems: queryItems) else {
            throw PlexServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        applyHeaders(to: &request)

        return try await executeRequest(request)
    }

    // MARK: - MediaContainer Helpers

    /// Fetch items from a server endpoint where the MediaContainer wraps a `Metadata` array.
    func fetchMetadata<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> [T] {
        let data = try await rawServerRequest(path: path, queryItems: queryItems)
        let response = try decodeJSON(MetadataResponse<T>.self, from: data)
        return response.MediaContainer.Metadata ?? []
    }

    /// Fetch items from a server endpoint where the MediaContainer wraps a `Directory` array.
    func fetchDirectories<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> [T] {
        let data = try await rawServerRequest(path: path, queryItems: queryItems)
        let response = try decodeJSON(DirectoryResponse<T>.self, from: data)
        return response.MediaContainer.Directory ?? []
    }

    /// Fetch hubs from a server endpoint where the MediaContainer wraps a `Hub` array.
    func fetchHubs(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> [PlexHub] {
        let data = try await rawServerRequest(path: path, queryItems: queryItems)
        let response = try decodeJSON(HubResponse.self, from: data)
        return response.MediaContainer.Hub ?? []
    }

    // MARK: - Internals

    private func applyHeaders(to request: inout URLRequest) {
        for (key, value) in plexHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func executeRequest(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
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

    private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw PlexServiceError.decodingError(String(describing: error))
        }
    }

    private func buildURL(base: String, path: String, queryItems: [URLQueryItem]? = nil) -> URL? {
        let base = base.hasSuffix("/") ? String(base.dropLast()) : base
        let path = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: base + path) else { return nil }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }
}

// MARK: - MediaContainer Response Types

/// Server response with items in a `Metadata` array.
private struct MetadataResponse<T: Decodable>: Decodable {
    let MediaContainer: Container
    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Metadata: [T]?
    }
}

/// Server response with items in a `Directory` array.
private struct DirectoryResponse<T: Decodable>: Decodable {
    let MediaContainer: Container
    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Directory: [T]?
    }
}

/// Server response with items in a `Hub` array.
private struct HubResponse: Decodable {
    let MediaContainer: Container
    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Hub: [PlexHub]?
    }
}
