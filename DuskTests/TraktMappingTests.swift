import Foundation
import Testing
@testable import Dusk

@Suite("Trakt history mapping and requests")
struct TraktMappingTests {
    private let date = Date(timeIntervalSince1970: 1_793_000_000)

    private func entry(_ type: PlexMediaType, guid: String? = nil, _ guids: [String] = []) -> TraktHistoryEntry? {
        TraktHistoryMapper.entry(
            type: type,
            guid: guid,
            guids: guids.map(PlexGuid.init(id:)),
            watchedAt: date,
            profileID: "profile"
        )
    }

    // MARK: Mapping

    @Test func modernMovieUsesAllExternalIDs() throws {
        let result = try #require(entry(.movie, guid: "plex://movie/5d776", ["imdb://tt0133093", "tmdb://603", "tvdb://169"]))
        #expect(result.kind == .movie)
        #expect(result.ids == TraktIDs(imdb: "tt0133093", tmdb: 603, tvdb: 169))
        #expect(result.profileID == "profile")
        #expect(result.watchedAt == date)
    }

    @Test func modernEpisodeUsesItsOwnIDs() throws {
        let result = try #require(entry(.episode, guid: "plex://episode/5d9c", ["tvdb://349232", "tmdb://63056"]))
        #expect(result.kind == .episode)
        #expect(result.ids == TraktIDs(tmdb: 63056, tvdb: 349232))
        #expect(result.season == nil)
    }

    @Test func malformedExternalIDsAreIgnored() throws {
        let result = try #require(entry(.movie, ["imdb://nm123", "tmdb://abc", "tvdb://42"]))
        #expect(result.ids == TraktIDs(tvdb: 42))
        #expect(entry(.movie, ["imdb://", "tmdb://x"]) == nil)
    }

    @Test func legacyMovieAgents() throws {
        let imdb = try #require(entry(.movie, guid: "com.plexapp.agents.imdb://tt0111161?lang=en"))
        #expect(imdb.kind == .movie)
        #expect(imdb.ids == TraktIDs(imdb: "tt0111161"))

        let tmdb = try #require(entry(.movie, guid: "com.plexapp.agents.themoviedb://278?lang=de"))
        #expect(tmdb.ids == TraktIDs(tmdb: 278))
    }

    @Test func legacyEpisodeIsShowPlusNumbers() throws {
        let result = try #require(entry(.episode, guid: "com.plexapp.agents.thetvdb://121361/3/9?lang=en"))
        #expect(result.kind == .showEpisode)
        #expect(result.ids == TraktIDs(tvdb: 121361))
        #expect(result.season == 3)
        #expect(result.episode == 9)

        let tmdb = try #require(entry(.episode, guid: "com.plexapp.agents.themoviedb://1399/1/1"))
        #expect(tmdb.ids == TraktIDs(tmdb: 1399))
    }

    @Test func unmatchableItemsAreSkipped() {
        #expect(entry(.movie) == nil)
        #expect(entry(.movie, guid: "local://12345") == nil)
        #expect(entry(.movie, guid: "plex://movie/5d776") == nil)
        #expect(entry(.movie, guid: "com.plexapp.agents.none://abc") == nil)
        #expect(entry(.episode, guid: "com.plexapp.agents.hama://anidb-123/1/1") == nil)
        // A legacy show guid without season/episode is not an episode.
        #expect(entry(.episode, guid: "com.plexapp.agents.thetvdb://121361") == nil)
    }

    @Test func onlyMoviesAndEpisodesAreTracked() {
        for type: PlexMediaType in [.show, .season, .clip, .track, .collection] {
            #expect(entry(type, ["tmdb://1"]) == nil)
        }
    }

    // MARK: Requests

    private let builder = TraktRequestBuilder(
        configuration: TraktConfiguration(
            clientID: "client-id",
            clientSecret: "client-secret",
            apiBase: URL(string: "https://api.trakt.tv")!
        ),
        userAgent: "Dusk/1.8.0 (iOS)"
    )

    private func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func historyRequestCarriesTraktHeaders() throws {
        let movie = try #require(entry(.movie, ["tmdb://603"]))
        let request = builder.addToHistory([movie], accessToken: "access")
        #expect(request.url?.absoluteString == "https://api.trakt.tv/sync/history")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(request.value(forHTTPHeaderField: "trakt-api-key") == "client-id")
        #expect(request.value(forHTTPHeaderField: "trakt-api-version") == "2")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Dusk/1.8.0 (iOS)")
    }

    @Test func historyBodyGroupsByKind() throws {
        let movie = try #require(entry(.movie, ["imdb://tt0133093", "tmdb://603"]))
        let episode = try #require(entry(.episode, ["tvdb://349232"]))
        let legacy = try #require(entry(.episode, guid: "com.plexapp.agents.thetvdb://121361/3/9"))
        let body = try json(builder.addToHistory([movie, episode, legacy], accessToken: "a"))

        let movies = try #require(body["movies"] as? [[String: Any]])
        #expect(movies.count == 1)
        #expect(movies[0]["watched_at"] as? String == "2026-10-26T07:33:20.000Z")
        let movieIDs = try #require(movies[0]["ids"] as? [String: Any])
        #expect(movieIDs["imdb"] as? String == "tt0133093")
        #expect(movieIDs["tmdb"] as? Int == 603)
        #expect(movieIDs["tvdb"] == nil)

        let episodes = try #require(body["episodes"] as? [[String: Any]])
        #expect((episodes[0]["ids"] as? [String: Any])?["tvdb"] as? Int == 349232)

        let shows = try #require(body["shows"] as? [[String: Any]])
        #expect((shows[0]["ids"] as? [String: Any])?["tvdb"] as? Int == 121361)
        let seasons = try #require(shows[0]["seasons"] as? [[String: Any]])
        #expect(seasons[0]["number"] as? Int == 3)
        let episodesInSeason = try #require(seasons[0]["episodes"] as? [[String: Any]])
        #expect(episodesInSeason[0]["number"] as? Int == 9)
        #expect(episodesInSeason[0]["watched_at"] as? String == "2026-10-26T07:33:20.000Z")
    }

    @Test func historyBodyOmitsEmptyGroups() throws {
        let movie = try #require(entry(.movie, ["tmdb://603"]))
        let body = try json(builder.addToHistory([movie], accessToken: "a"))
        #expect(Set(body.keys) == ["movies"])
    }

    @Test func deviceFlowRequests() throws {
        let code = builder.deviceCode()
        #expect(code.url?.path == "/oauth/device/code")
        #expect(code.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try json(code) as? [String: String] == ["client_id": "client-id"])

        let token = builder.deviceToken(deviceCode: "dev")
        #expect(token.url?.path == "/oauth/device/token")
        #expect(try json(token) as? [String: String] == [
            "code": "dev", "client_id": "client-id", "client_secret": "client-secret",
        ])

        let refresh = builder.refresh(refreshToken: "r")
        #expect(refresh.url?.path == "/oauth/token")
        #expect(try json(refresh) as? [String: String] == [
            "refresh_token": "r",
            "client_id": "client-id",
            "client_secret": "client-secret",
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
            "grant_type": "refresh_token",
        ])
    }

    // MARK: Authorization code (iOS)

    private let browserConfiguration = TraktConfiguration(
        clientID: "client-id",
        clientSecret: "client-secret",
        apiBase: URL(string: "https://api.trakt.tv")!,
        appRedirectURI: "dusk://trakt/callback"
    )

    @Test func redirectURISettingFallsBackToDeviceFlow() {
        // No setting, or nothing usable: no browser sign-in.
        #expect(builder.configuration.appRedirectURI == nil)
        #expect(TraktAuthorization(configuration: builder.configuration) == nil)
        for unusable in ["", "  ", "dusk:", "dusk:/", "not a url", "http://localhost/callback", "https://dusk-player.app/trakt"] {
            let configuration = TraktConfiguration(
                clientID: "c", clientSecret: "s", apiBase: TraktConfiguration.productionAPIBase, appRedirectURI: unusable
            )
            #expect(configuration.appRedirectURI == nil, "\(unusable)")
        }
        #expect(browserConfiguration.appRedirectURI == "dusk://trakt/callback")
        let trimmed = TraktConfiguration(
            clientID: "c", clientSecret: "s", apiBase: TraktConfiguration.productionAPIBase,
            appRedirectURI: " dusk://trakt/callback\n"
        )
        #expect(trimmed.appRedirectURI == "dusk://trakt/callback")
    }

    @Test func authorizeURLCarriesClientRedirectAndState() throws {
        let authorization = try #require(TraktAuthorization(configuration: browserConfiguration, state: "s+t/a=te"))
        #expect(authorization.callbackScheme == "dusk")
        #expect(authorization.redirectURI == "dusk://trakt/callback")
        let url = authorization.url
        #expect(url.scheme == "https")
        #expect(url.host() == "trakt.tv")
        #expect(url.path() == "/oauth/authorize")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }) == [
            "response_type": "code",
            "client_id": "client-id",
            "redirect_uri": "dusk://trakt/callback",
            "state": "s+t/a=te",
        ])
        // `+` must not reach Trakt as a space.
        #expect(!url.absoluteString.contains("+"))
        #expect(url.absoluteString.contains("s%2Bt"))
    }

    @Test func randomStateIsLongURLSafeAndFresh() {
        let states = (0..<20).map { _ in TraktAuthorization.randomState() }
        #expect(Set(states).count == states.count)
        for state in states {
            #expect(state.count == 43)
            #expect(state.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
        let first = TraktAuthorization(configuration: browserConfiguration)
        let second = TraktAuthorization(configuration: browserConfiguration)
        #expect(first?.state != nil)
        #expect(first?.state != second?.state)
    }

    @Test func callbackAcceptsOnlyMatchingState() throws {
        let authorization = try #require(TraktAuthorization(configuration: browserConfiguration, state: "abc"))
        func result(_ string: String) throws -> TraktAuthorization.CallbackResult {
            authorization.result(for: try #require(URL(string: string)))
        }
        #expect(try result("dusk://trakt/callback?code=xyz&state=abc") == .code("xyz"))
        #expect(try result("DUSK://Trakt/callback?state=abc&code=xyz") == .code("xyz"))
        #expect(try result("dusk://trakt/callback?code=xyz&state=abd") == .stateMismatch)
        #expect(try result("dusk://trakt/callback?code=xyz") == .stateMismatch)
        #expect(try result("dusk://trakt/callback?code=xyz&state=") == .stateMismatch)
        #expect(try result("dusk://trakt/callback?error=access_denied&state=abc") == .denied)
        // A denial for another request is still not ours.
        #expect(try result("dusk://trakt/callback?error=access_denied&state=zzz") == .stateMismatch)
        #expect(try result("dusk://trakt/callback?error=server_error&state=abc") == .invalid)
        #expect(try result("dusk://trakt/callback?state=abc") == .invalid)
        #expect(try result("dusk://trakt/callback?code=&state=abc") == .invalid)
        // Other dusk:// links (tvOS Top Shelf) and other schemes are rejected.
        #expect(try result("dusk://play?code=xyz&state=abc") == .invalid)
        #expect(try result("dusk://trakt/other?code=xyz&state=abc") == .invalid)
        #expect(try result("https://trakt/callback?code=xyz&state=abc") == .invalid)
    }

    @Test func authorizationCodeExchangeRequest() throws {
        let request = builder.authorizationToken(code: "the-code", redirectURI: "dusk://trakt/callback")
        #expect(request.url?.absoluteString == "https://api.trakt.tv/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try json(request) as? [String: String] == [
            "code": "the-code",
            "client_id": "client-id",
            "client_secret": "client-secret",
            "redirect_uri": "dusk://trakt/callback",
            "grant_type": "authorization_code",
        ])
    }

    @Test func refreshRepeatsTheGrantRedirect() throws {
        let data = Data(#"{"access_token":"a","refresh_token":"r","expires_in":86400,"created_at":1793000000}"#.utf8)
        let response = try JSONDecoder().decode(TraktTokenResponse.self, from: data)
        let browser = response.tokens(username: nil, redirectURI: "dusk://trakt/callback")
        #expect(browser.refreshRedirectURI == "dusk://trakt/callback")
        let device = response.tokens(username: nil)
        #expect(device.refreshRedirectURI == "urn:ietf:wg:oauth:2.0:oob")

        let request = builder.refresh(refreshToken: "r", redirectURI: browser.refreshRedirectURI)
        #expect((try json(request) as? [String: String])?["redirect_uri"] == "dusk://trakt/callback")

        // Tokens saved before `redirectURI` existed still decode (device flow).
        let legacy = Data(#"{"accessToken":"a","refreshToken":"r","expiresAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(TraktTokens.self, from: legacy)
        #expect(decoded.redirectURI == nil)
        #expect(decoded.refreshRedirectURI == "urn:ietf:wg:oauth:2.0:oob")
    }

    @Test func devicePollStatusMapping() {
        #expect(TraktDevicePollResult(status: 400) == .pending)
        #expect(TraktDevicePollResult(status: 429) == .slowDown)
        #expect(TraktDevicePollResult(status: 418) == .denied)
        #expect(TraktDevicePollResult(status: 410) == .expired)
        #expect(TraktDevicePollResult(status: 404) == .invalid)
        #expect(TraktDevicePollResult(status: 409) == .invalid)
        #expect(TraktDevicePollResult(status: 502) == .failed(502))
    }

    @Test func tokenResponseExpiryIsAbsolute() throws {
        let data = Data(#"{"access_token":"a","refresh_token":"r","expires_in":86400,"created_at":1793000000,"token_type":"bearer","scope":"public"}"#.utf8)
        let tokens = try JSONDecoder().decode(TraktTokenResponse.self, from: data).tokens(username: "marvin")
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 1_793_086_400))
        #expect(tokens.username == "marvin")
        #expect(tokens.expires(within: 3600, now: Date(timeIntervalSince1970: 1_793_084_000)))
        #expect(!tokens.expires(within: 3600, now: Date(timeIntervalSince1970: 1_793_000_000)))
    }

    @Test func queueRoundTripsAndIsBounded() throws {
        let defaults = try #require(UserDefaults(suiteName: "TraktQueueTests-\(UUID().uuidString)"))
        let queue = TraktHistoryQueue(defaults: defaults)
        let movie = try #require(entry(.movie, ["tmdb://603"]))
        queue.save(Array(repeating: movie, count: TraktHistoryQueue.maximumEntries + 5))
        #expect(queue.load().count == TraktHistoryQueue.maximumEntries)
        queue.save([])
        #expect(queue.load().isEmpty)
    }
}
