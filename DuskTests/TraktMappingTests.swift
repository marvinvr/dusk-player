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
