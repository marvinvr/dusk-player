import Foundation
import CryptoKit

/// External ids Trakt matches on. Plex `Guid` entries carry them for both
/// movies and episodes (episode-level ids, not the show's).
struct TraktIDs: Codable, Sendable, Hashable {
    var imdb: String?
    var tmdb: Int?
    var tvdb: Int?

    var isEmpty: Bool { imdb == nil && tmdb == nil && tvdb == nil }
}

/// One finished movie or episode waiting to be added to Trakt history.
/// Persisted in `TraktHistoryQueue`, so it must stay `Codable`-stable.
struct TraktHistoryEntry: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case movie
        case episode
        /// A legacy-agent episode (`com.plexapp.agents.thetvdb://show/season/episode`):
        /// only the show's id is known, so it is sent as show + numbers.
        case showEpisode
    }

    let kind: Kind
    let ids: TraktIDs
    var season: Int?
    var episode: Int?
    let watchedAt: Date
    /// Plex profile the play belongs to; picks the Trakt account.
    let profileID: String
    var attempts = 0
    var id = UUID()
}

// MARK: - API payloads

struct TraktDeviceCode: Decodable, Sendable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

struct TraktTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Absolute expiry (Trakt sends `created_at` + `expires_in`).
    var expiresAt: Date
    var username: String?
    /// Redirect URI of a browser (authorization-code) grant; a refresh
    /// repeats it. `nil` for device-code links, which refresh with
    /// `TraktConfiguration.deviceRefreshRedirectURI`.
    var redirectURI: String?

    func refreshRedirectURI(_ configuration: TraktConfiguration) -> String {
        redirectURI.flatMap(TraktConfiguration.validatedRedirectURI) ?? configuration.deviceRefreshRedirectURI
    }

    func expires(within interval: TimeInterval, now: Date = .now) -> Bool {
        expiresAt.timeIntervalSince(now) < interval
    }
}

/// `/oauth/device/token` and `/oauth/token` success body.
struct TraktTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case createdAt = "created_at"
    }

    func tokens(username: String?, redirectURI: String? = nil) -> TraktTokens {
        TraktTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(createdAt + expiresIn)),
            username: username,
            redirectURI: redirectURI
        )
    }
}

/// One iOS PKCE sign-in. The verifier and state live only for this attempt;
/// Trakt redirects directly to the app's owned HTTPS callback.
struct TraktAuthorization: Sendable, Equatable {
    enum CallbackResult: Equatable {
        case code(String)
        /// The user declined on Trakt (`error=access_denied`).
        case denied
        /// `state` missing or different: not the answer to this request.
        case stateMismatch
        /// Not the configured redirect, another `error`, or no `code`.
        case invalid
    }

    let state: String
    let url: URL
    let redirectURI: String
    let codeVerifier: String

    /// `nil` when the build has no usable `TRAKT_REDIRECT_URI`.
    init?(
        configuration: TraktConfiguration,
        state: String = TraktAuthorization.randomState(),
        codeVerifier: String = TraktAuthorization.randomState()
    ) {
        guard let redirectURI = configuration.appRedirectURI else { return nil }
        self.state = state
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
        var components = URLComponents(
            url: configuration.authBase.appending(path: "oauth/authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        // `+` is legal in a query but read as a space by many servers.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        url = components.url!
    }

    static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 32 random bytes, base64url without padding (43 characters).
    static func randomState() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func result(for callbackURL: URL) -> CallbackResult {
        // Scheme and host compare case-insensitively, the path exactly.
        let expected = TraktConfiguration.callbackURL
        guard
              callbackURL.scheme?.lowercased() == expected.scheme?.lowercased(),
              callbackURL.host()?.lowercased() == expected.host()?.lowercased(),
              callbackURL.path() == expected.path(),
              callbackURL.port == nil, callbackURL.user == nil, callbackURL.password == nil,
              callbackURL.fragment == nil,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            return .invalid
        }
        let items = components.queryItems ?? []
        guard ["state", "code", "error"].allSatisfy({ name in
            items.filter { $0.name == name }.count <= 1
        }) else { return .invalid }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.nilIfEmpty
        }
        guard value("state") == state else { return .stateMismatch }
        if let error = value("error") {
            return error == "access_denied" ? .denied : .invalid
        }
        guard let code = value("code") else { return .invalid }
        return .code(code)
    }
}

/// What a `/oauth/device/token` poll answered, by status code.
enum TraktDevicePollResult: Equatable {
    case pending
    case slowDown
    case denied
    case expired
    case invalid
    case failed(Int)

    init(status: Int) {
        switch status {
        case 400: self = .pending
        case 429: self = .slowDown
        case 418: self = .denied
        case 410: self = .expired
        case 404, 409: self = .invalid
        default: self = .failed(status)
        }
    }
}

// MARK: - Request building

/// Builds every Trakt request. Pure, so headers and bodies are unit tested.
struct TraktRequestBuilder: Sendable {
    let configuration: TraktConfiguration
    let userAgent: String

    func deviceCode() -> URLRequest {
        post("oauth/device/code", json: ["client_id": configuration.clientID])
    }

    func deviceToken(deviceCode: String) -> URLRequest {
        post("oauth/device/token", json: [
            "code": deviceCode,
            "client_id": configuration.clientID,
        ])
    }

    /// Exchanges the iOS sign-in's authorization code for tokens.
    /// `redirectURI` must be the one the authorize URL carried.
    func authorizationToken(code: String, redirectURI: String, codeVerifier: String) -> URLRequest {
        post("oauth/token", json: [
            "code": code,
            "client_id": configuration.clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ])
    }

    func refresh(refreshToken: String, redirectURI: String = TraktConfiguration.defaultRedirectURI) -> URLRequest {
        post("oauth/token", json: [
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
            "redirect_uri": redirectURI,
            "grant_type": "refresh_token",
        ])
    }

    func revoke(accessToken: String) -> URLRequest {
        post("oauth/revoke", json: [
            "token": accessToken,
            "client_id": configuration.clientID,
        ])
    }

    func userSettings(accessToken: String) -> URLRequest {
        var request = base("users/settings", accessToken: accessToken)
        request.httpMethod = "GET"
        return request
    }

    func addToHistory(_ entries: [TraktHistoryEntry], accessToken: String) -> URLRequest {
        var request = base("sync/history", accessToken: accessToken)
        request.httpMethod = "POST"
        request.httpBody = Self.historyBody(for: entries)
        return request
    }

    /// `/sync/history` body: `movies`, `episodes` (matched by their own ids)
    /// and `shows` (legacy show id + season/episode numbers).
    static func historyBody(for entries: [TraktHistoryEntry]) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func ids(_ ids: TraktIDs) -> [String: Any] {
            var result: [String: Any] = [:]
            if let imdb = ids.imdb { result["imdb"] = imdb }
            if let tmdb = ids.tmdb { result["tmdb"] = tmdb }
            if let tvdb = ids.tvdb { result["tvdb"] = tvdb }
            return result
        }

        var movies: [[String: Any]] = []
        var episodes: [[String: Any]] = []
        var shows: [[String: Any]] = []
        for entry in entries {
            let watchedAt = formatter.string(from: entry.watchedAt)
            switch entry.kind {
            case .movie:
                movies.append(["watched_at": watchedAt, "ids": ids(entry.ids)])
            case .episode:
                episodes.append(["watched_at": watchedAt, "ids": ids(entry.ids)])
            case .showEpisode:
                guard let season = entry.season, let episode = entry.episode else { continue }
                shows.append([
                    "ids": ids(entry.ids),
                    "seasons": [[
                        "number": season,
                        "episodes": [["number": episode, "watched_at": watchedAt]],
                    ]],
                ])
            }
        }

        var body: [String: Any] = [:]
        if !movies.isEmpty { body["movies"] = movies }
        if !episodes.isEmpty { body["episodes"] = episodes }
        if !shows.isEmpty { body["shows"] = shows }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private func post(_ path: String, json: [String: String]) -> URLRequest {
        var request = base(path, accessToken: nil)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return request
    }

    private func base(_ path: String, accessToken: String?) -> URLRequest {
        var request = URLRequest(url: (path.hasPrefix("oauth/") ? configuration.authBase : configuration.apiBase).appending(path: path))
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TraktConfiguration.apiVersion, forHTTPHeaderField: "trakt-api-version")
        request.setValue(configuration.clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
