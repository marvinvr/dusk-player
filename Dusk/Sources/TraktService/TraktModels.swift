import Foundation

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

/// Plex metadata → `TraktHistoryEntry`. Pure, so it is unit tested.
enum TraktHistoryMapper {
    static func entry(
        type: PlexMediaType,
        guid: String?,
        guids: [PlexGuid],
        watchedAt: Date,
        profileID: String
    ) -> TraktHistoryEntry? {
        guard type == .movie || type == .episode else { return nil }

        // Modern agents: the `Guid` array (imdb://, tmdb://, tvdb://).
        var ids = TraktIDs()
        for item in guids {
            if ids.imdb == nil, let value = item.value(for: "imdb"), value.hasPrefix("tt") { ids.imdb = value }
            if ids.tmdb == nil, let value = item.value(for: "tmdb").flatMap(Int.init) { ids.tmdb = value }
            if ids.tvdb == nil, let value = item.value(for: "tvdb").flatMap(Int.init) { ids.tvdb = value }
        }
        if !ids.isEmpty {
            return TraktHistoryEntry(
                kind: type == .movie ? .movie : .episode,
                ids: ids,
                watchedAt: watchedAt,
                profileID: profileID
            )
        }

        // Legacy agents: everything lives in the scalar guid.
        guard let legacy = LegacyGuid(guid) else { return nil }
        switch type {
        case .movie:
            guard legacy.numbers.isEmpty, let ids = legacy.ids else { return nil }
            return TraktHistoryEntry(kind: .movie, ids: ids, watchedAt: watchedAt, profileID: profileID)
        default:
            // thetvdb://<show>/<season>/<episode>, themoviedb://<show>/<season>/<episode>
            guard legacy.numbers.count == 2, let ids = legacy.ids else { return nil }
            return TraktHistoryEntry(
                kind: .showEpisode,
                ids: ids,
                season: legacy.numbers[0],
                episode: legacy.numbers[1],
                watchedAt: watchedAt,
                profileID: profileID
            )
        }
    }

    /// `com.plexapp.agents.<agent>://<id>[/<season>/<episode>][?lang=xx]`.
    private struct LegacyGuid {
        let agent: String
        let id: String
        let numbers: [Int]

        init?(_ guid: String?) {
            guard let guid, let schemeEnd = guid.range(of: "://") else { return nil }
            let scheme = guid[..<schemeEnd.lowerBound].lowercased()
            guard scheme.hasPrefix("com.plexapp.agents.") else { return nil }
            agent = String(scheme.dropFirst("com.plexapp.agents.".count))
            let rest = guid[schemeEnd.upperBound...].split(separator: "?").first.map(String.init) ?? ""
            let parts = rest.split(separator: "/").map(String.init)
            guard let first = parts.first, !first.isEmpty else { return nil }
            id = first
            let numbers = parts.dropFirst().compactMap(Int.init)
            guard numbers.count == parts.count - 1 else { return nil }
            self.numbers = numbers
        }

        var ids: TraktIDs? {
            switch agent {
            case "imdb":
                return id.hasPrefix("tt") ? TraktIDs(imdb: id) : nil
            case "themoviedb":
                return Int(id).map { TraktIDs(tmdb: $0) }
            case "thetvdb":
                return Int(id).map { TraktIDs(tvdb: $0) }
            default:
                return nil
            }
        }
    }
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

    func tokens(username: String?) -> TraktTokens {
        TraktTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(createdAt + expiresIn)),
            username: username
        )
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
            "client_secret": configuration.clientSecret,
        ])
    }

    func refresh(refreshToken: String) -> URLRequest {
        post("oauth/token", json: [
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
            "client_secret": configuration.clientSecret,
            "redirect_uri": TraktConfiguration.redirectURI,
            "grant_type": "refresh_token",
        ])
    }

    func revoke(accessToken: String) -> URLRequest {
        post("oauth/revoke", json: [
            "token": accessToken,
            "client_id": configuration.clientID,
            "client_secret": configuration.clientSecret,
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
        var request = URLRequest(url: configuration.apiBase.appending(path: path))
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
