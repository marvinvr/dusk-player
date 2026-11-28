import Foundation
import Testing
@testable import Dusk

/// J-04: Jellyfin's Home rows, library rows, Continue Watching, dismiss and
/// Hide Row, over a stub server that answers per path; and Plex's dismiss
/// request, which moved into `PlexHomeRows`.
@MainActor
@Suite(.serialized)
struct JellyfinHomeTests {
    nonisolated private static let serverID = "99d23e4060434e129f9ae072bf97d30d"
    nonisolated private static let userID = "7b20244faaf946818eac31a8f0f72c7b"
    nonisolated private static let movies = "f137a2dd21bbc1b99aa5c0f6bf02a805"
    nonisolated private static let tv = "a8ee6ba847f2671fe06a474d749352b9"
    nonisolated private static let office = "4eb7e22c1653ab565cf44daa4176ca56"
    nonisolated private static let severance = "7820db538a32435f48c0a565e198f893"

    private typealias Spec = JellyfinHomeRowSpec

    // MARK: Row vocabulary

    @Test func rowsUsePlexNamesForTheSameRow() {
        let added = Spec(row: .recentlyAdded, libraryKind: .movie, libraryID: Self.movies)
        let row = added.homeRow(items: [], libraryTitle: "Movies", more: false, serverID: Self.serverID)
        #expect(row.hubIdentifier == "movie.recentlyadded.\(Self.movies)")
        #expect(row.title == "Recently Added in Movies")
        #expect(row.mergeKey == "id:movie.recentlyadded|movie")
        #expect(row.kind == .recentlyAdded)
        #expect(row.libraryScope == .section(Self.movies))
        #expect(row.canHide)
        #expect(row.sources.first?.key == added.key)

        let tvAdded = Spec(row: .recentlyAdded, libraryKind: .show, libraryID: Self.tv)
        #expect(tvAdded.identifier == "tv.recentlyadded")
        #expect(tvAdded.type == "mixed")
        #expect(Spec(row: .recentlyAdded, libraryKind: .video, libraryID: "v").identifier == "video.recent")

        let names = Spec.libraryRows(for: .show).map { Spec(row: $0, libraryKind: .show, libraryID: Self.tv) }
            .map { "\($0.identifier)|\($0.title(libraryTitle: "Real TV"))|\($0.type)" }
        #expect(names == [
            "tv.inprogress|Continue Watching|episode",
            "tv.recentlyaired|Recently Released Episodes|episode",
            "tv.recentlyadded|Recently Added in Real TV|mixed",
            "tv.toprated|Top Rated TV|show",
            "tv.recentlyviewed|Recently Watched Episodes|episode",
        ])
        let movieNames = Spec.libraryRows(for: .movie).map { Spec(row: $0, libraryKind: .movie, libraryID: "m") }
            .map(\.identifier)
        #expect(movieNames == ["movie.inprogress", "movie.recentlyreleased", "movie.recentlyadded",
                               "movie.topunwatched", "movie.recentlyviewed"])
        #expect(Spec.libraryRows(for: .video).map(\.rawValue) == ["continueWatching", "recentlyAdded", "recentlyWatched"])
        #expect(Spec.libraryRows(for: .photo).isEmpty)

        // Only Recently Added has a Home switch.
        let watched = Spec(row: .recentlyWatched, libraryKind: .movie, libraryID: "m")
        #expect(!watched.homeRow(items: [], libraryTitle: "M", more: false, serverID: Self.serverID).canHide)
    }

    @Test func rowKeysRoundTrip() {
        for row in Spec.Row.allCases {
            for kind in [LibraryKind.movie, .show, .video] {
                let spec = Spec(row: row, libraryKind: kind, libraryID: Self.movies)
                #expect(Spec(key: spec.key) == spec)
            }
        }
        #expect(Spec(key: "/library/sections/1/all") == nil)
        #expect(Spec(key: "jellyfin-row/recentlyAdded/movie/") == nil)
        #expect(Spec(key: "jellyfin-row/bogus/movie/x") == nil)
    }

    @Test func listingRowsCarryPlexConditions() throws {
        func parameters(_ spec: Spec) -> [String: String] {
            let query = spec.itemsQuery(start: 0, limit: 12)!
            return Dictionary(query.queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        }
        let top = parameters(Spec(row: .topRated, libraryKind: .show, libraryID: Self.tv))
        #expect(top["includeItemTypes"] == "Series")
        #expect(top["isPlayed"] == "false")
        #expect(top["sortBy"] == "CommunityRating,SortName")
        #expect(top["parentId"] == Self.tv)

        let watched = parameters(Spec(row: .recentlyWatched, libraryKind: .show, libraryID: Self.tv))
        #expect(watched["includeItemTypes"] == "Episode")
        #expect(watched["isPlayed"] == "true")
        #expect(watched["sortBy"] == "DatePlayed")

        let released = parameters(Spec(row: .recentlyReleased, libraryKind: .show, libraryID: Self.tv))
        #expect(released["isMissing"] == "false")
        #expect(released["sortBy"] == "PremiereDate,SortName")
        #expect(Spec(row: .recentlyAdded, libraryKind: .movie, libraryID: "m").itemsQuery(start: 0, limit: 1) == nil)

        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-28T12:00:00Z"))
        let releasedMovies = Spec(row: .recentlyReleased, libraryKind: .movie, libraryID: "m")
        #expect(releasedMovies.keeps(try Self.item(premiere: "2026-03-01T00:00:00.0000000Z"), now: now))
        #expect(!releasedMovies.keeps(try Self.item(premiere: "2024-02-26T00:00:00.0000000Z"), now: now))
        #expect(!releasedMovies.keeps(try Self.item(), now: now))
        let topMovies = Spec(row: .topRated, libraryKind: .movie, libraryID: "m")
        #expect(topMovies.keeps(try Self.item(rating: 7.33), now: now))
        #expect(!topMovies.keeps(try Self.item(rating: 6.47), now: now))
    }

    // MARK: Configuration round trip

    @Test func hideRowChangesOnlyLatestItemsExcludes() throws {
        let user = try JellyfinFixtures.decode(JellyfinJSONObject.self, "users-me")
        guard case .object(let configuration)? = user["Configuration"] else {
            Issue.record("fixture has no Configuration")
            return
        }
        let hidden = try #require(JellyfinHome.configuration(configuration, showingLatestOf: Self.movies, onHome: false))
        #expect(JellyfinHome.latestExcludes(in: hidden) == [Self.movies])
        #expect(hidden.count == configuration.count)
        #expect(hidden["CastReceiverId"] == .string("F007D354"))
        #expect(hidden["EnableLocalPassword"] == .bool(false))
        #expect(hidden.filter { $0.key != "LatestItemsExcludes" } == configuration.filter { $0.key != "LatestItemsExcludes" })
        #expect(JellyfinHome.configuration(hidden, showingLatestOf: Self.movies, onHome: false) == nil)

        // Dashed ids from another client are the same library.
        var dashed = configuration
        dashed["LatestItemsExcludes"] = .array([.string("f137a2dd-21bb-c1b9-9aa5-c0f6bf02a805"), .string("other")])
        let shown = try #require(JellyfinHome.configuration(dashed, showingLatestOf: Self.movies, onHome: true))
        #expect(shown["LatestItemsExcludes"] == .array([.string("other")]))

        // Encodes back with every key, integers as integers.
        let encoded = try JellyfinJSON.encode(JellyfinJSONValue.object(["A": .int(3), "B": .double(1.5), "C": .null]))
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("\"A\":3"))
        #expect(text.contains("\"B\":1.5"))
        #expect(text.contains("\"C\":null"))
    }

    // MARK: Continue Watching

    @Test func continueWatchingIsNewestFirstOnePerShow() throws {
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let movie = JellyfinContinueWatchingEntry(
            dto: try Self.item(id: "a1", position: 790_000_000), libraryID: Self.movies, playedAt: date("2026-11-27T20:52:08Z"))
        let officeResume = JellyfinContinueWatchingEntry(
            dto: try Self.item(id: "b1", type: "Episode", series: Self.office, position: 10), libraryID: Self.tv,
            playedAt: date("2026-11-27T21:00:00Z"))
        let officeNext = JellyfinContinueWatchingEntry(
            dto: try Self.item(id: "b2", type: "Episode", series: Self.office), libraryID: Self.tv,
            playedAt: date("2026-11-27T19:00:00Z"))
        let severanceNext = JellyfinContinueWatchingEntry(
            dto: try Self.item(id: "c1", type: "Episode", series: Self.severance), libraryID: Self.tv,
            playedAt: date("2026-11-27T20:00:00Z"))
        let undated = JellyfinContinueWatchingEntry(
            dto: try Self.item(id: "d1", type: "Episode", series: "eeee"), libraryID: Self.tv, playedAt: nil)

        let ordered = JellyfinContinueWatchingEntry.ordered([undated, movie, officeNext, severanceNext, officeResume])
        #expect(ordered.map(\.dto.id) == ["b1", "a1", "c1", "d1"])
        #expect(!officeResume.isNextUp)
        #expect(officeNext.isNextUp)
    }

    @Test func dismissedNextUpStaysOutUntilTheShowMovesOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "JellyfinHomeTests.dismissals"))
        defaults.removePersistentDomain(forName: "JellyfinHomeTests.dismissals")
        defer { defaults.removePersistentDomain(forName: "JellyfinHomeTests.dismissals") }
        let scope = JellyfinNextUpDismissals.scope(serverID: Self.serverID, userID: Self.userID)
        let other = JellyfinNextUpDismissals.scope(serverID: Self.serverID, userID: "another")

        JellyfinNextUpDismissals.dismiss(episodeID: "E81233B0-EB7A-A322-19E3-278C455EA807", seriesID: Self.office,
                                         scope: scope, defaults: defaults)
        let diversityDay = try Self.item(id: "e81233b0eb7aa32219e3278c455ea807", type: "Episode", series: Self.office)
        let youYouAre = try Self.item(id: "689ee48ed9f46ad912e68b6955d4e1fa", type: "Episode", series: Self.severance)

        #expect(JellyfinNextUpDismissals.filter([diversityDay, youYouAre], scope: scope, defaults: defaults)
            .map(\.id) == [youYouAre.id])
        // Another profile on the same server is not affected.
        #expect(JellyfinNextUpDismissals.filter([diversityDay], scope: other, defaults: defaults).count == 1)
        // A page without the show keeps the dismissal.
        _ = JellyfinNextUpDismissals.filter([youYouAre], scope: scope, defaults: defaults)
        #expect(JellyfinNextUpDismissals.dismissed(scope: scope, defaults: defaults)[Self.office] != nil)

        // The next episode is shown and the dismissal forgotten.
        let basketball = try Self.item(id: "0000000000000000000000000000beef", type: "Episode", series: Self.office)
        #expect(JellyfinNextUpDismissals.filter([basketball], scope: scope, defaults: defaults).count == 1)
        #expect(JellyfinNextUpDismissals.dismissed(scope: scope, defaults: defaults).isEmpty)
        #expect(defaults.object(forKey: JellyfinNextUpDismissals.defaultsKey) == nil)
    }

    // MARK: Facet over a stub server

    @Test func homeHasOneRecentlyAddedRowPerShownLibrary() async throws {
        let server = StubHomeServer(excludes: [Self.tv])
        let rows = try await makeHome(server).homeRows()
        #expect(rows.map(\.title) == ["Recently Added in Movies", "Recently Added in Home Videos"])
        let movies = try #require(rows.first)
        #expect(movies.items.map(\.title) == ["Latest 1", "Latest 2"])
        #expect(movies.items.allSatisfy { $0.libraryID == Self.movies })
        #expect(server.requests.contains { $0.path == "/Items/Latest" && $0.query["parentId"] == Self.movies
            && $0.query["limit"] == "\(JellyfinHome.homeRowCount)" })
        #expect(!server.requests.contains { $0.path == "/Items/Latest" && $0.query["parentId"] == Self.tv })
        // Photos and the Collections/Playlists views get no row.
        #expect(server.requests.filter { $0.path == "/Items/Latest" }.count == 2)
    }

    @Test func continueWatchingMergesResumeAndDatedNextUp() async throws {
        let server = StubHomeServer()
        let items = try await makeHome(server).continueWatching()
        // Resume: Big Buck Bunny 20:52; Next Up: The Office dated by its last
        // played episode (21:30), Severance (19:00).
        #expect(items.map(\.title) == ["Diversity Day", "Big Buck Bunny", "The You You Are"])
        #expect(items[0].libraryID == Self.tv)
        #expect(items[1].libraryID == Self.movies)
        #expect(items[0].lastPlayedAt == Int(ISO8601DateFormatter().date(from: "2026-11-27T21:30:00Z")!.timeIntervalSince1970))
        let nextUp = try #require(server.requests.first { $0.path == "/Shows/NextUp" })
        #expect(nextUp.query["parentId"] == Self.tv)
        #expect(nextUp.query["enableResumable"] == "false")
        #expect(!server.requests.contains { $0.path == "/Shows/NextUp" && $0.query["parentId"] == Self.movies })
    }

    @Test func dismissClearsTheResumePointAndRemembersTheEpisode() async throws {
        let scope = JellyfinNextUpDismissals.scope(serverID: Self.serverID, userID: Self.userID)
        let saved = UserDefaults.standard.object(forKey: JellyfinNextUpDismissals.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: JellyfinNextUpDismissals.defaultsKey) }

        let server = StubHomeServer()
        let home = makeHome(server)
        try await home.dismissFromContinueWatching(itemID: StubHomeServer.resumableEpisode)
        let post = try #require(server.requests.first { $0.method == "POST" })
        #expect(post.path == "/UserItems/\(StubHomeServer.resumableEpisode)/UserData")
        #expect(post.body == #"{"PlaybackPositionTicks":0}"#)
        #expect(JellyfinNextUpDismissals.dismissed(scope: scope)[Self.office] == StubHomeServer.resumableEpisode)

        // A Next Up episode has no resume point to clear.
        let next = StubHomeServer()
        try await makeHome(next).dismissFromContinueWatching(itemID: StubHomeServer.nextUpEpisode)
        #expect(!next.requests.contains { $0.method == "POST" })
    }

    @Test func hideRowWritesTheWholeConfigurationBack() async throws {
        let server = StubHomeServer()
        let home = makeHome(server)
        #expect(try await home.managedRows(libraryID: Self.movies).map(\.promotedToOwnHome) == [true])
        let row = try #require(try await home.homeRows().first)
        let managed = try #require(await home.managedRow(for: row, source: row.sources[0], libraryIDs: []))
        #expect(managed.sectionID == Self.movies)
        try await home.setManagedRow(managed.hub.withOwnHome(false), libraryID: managed.sectionID)
        let post = try #require(server.requests.first { $0.method == "POST" })
        #expect(post.path == "/Users/Configuration")
        #expect(post.query["userId"] == Self.userID)
        let body = try JellyfinJSON.decode(JellyfinJSONObject.self, from: Data(post.body.utf8))
        #expect(JellyfinHome.latestExcludes(in: body) == [Self.movies])
        #expect(body["CastReceiverId"] == .string("F007D354"))
    }

    // MARK: Plex

    @Test func plexDismissIsTheSameRequestAsBefore() async throws {
        let transport = RecordingPlexTransport()
        try await PlexHomeRows(serverID: "plex1", transport: transport).dismissFromContinueWatching(itemID: "42")
        #expect(transport.requests == ["PUT /actions/removeFromContinueWatching?ratingKey=42 @plex1"])
    }

    // MARK: Helpers

    private func makeHome(_ server: StubHomeServer) -> JellyfinHome {
        let client = JellyfinClient(
            baseURL: URL(string: "http://jellyfin.test")!,
            identity: .dusk(deviceID: "device-test"),
            credentials: JellyfinCredentials(accessToken: "tok", userID: Self.userID),
            transport: server
        )
        return JellyfinHome(serverID: Self.serverID, client: { client })
    }

    nonisolated static func item(
        id: String = "0000000000000000000000000000aaaa",
        type: String = "Movie",
        series: String? = nil,
        position: Int64 = 0,
        premiere: String? = nil,
        rating: Double? = nil
    ) throws -> JellyfinItemDTO {
        var fields = [#""Id":"\#(id)""#, #""Name":"\#(id)""#, #""Type":"\#(type)""#,
                      #""UserData":{"PlaybackPositionTicks":\#(position),"Played":false}"#]
        if let series { fields.append(#""SeriesId":"\#(series)""#) }
        if let premiere { fields.append(#""PremiereDate":"\#(premiere)""#) }
        if let rating { fields.append(#""CommunityRating":\#(rating)"#) }
        return try JellyfinJSON.decode(JellyfinItemDTO.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }
}

/// A Jellyfin server with four views (Movies, Real TV, Home Videos, Photos)
/// plus Collections and Playlists, answering by path. Records every request.
private final class StubHomeServer: JellyfinTransport, @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let body: String
    }

    static let resumableEpisode = "111111111111111111111111111111e1"
    static let nextUpEpisode = "e81233b0eb7aa32219e3278c455ea807"

    private let lock = NSLock()
    private var _requests: [Request] = []
    private let excludes: [String]

    init(excludes: [String] = []) { self.excludes = excludes }

    var requests: [Request] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { _, last in last })
        let path = components?.path ?? ""
        let recorded = Request(method: request.httpMethod ?? "GET", path: path, query: query,
                               body: request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "")
        lock.withLock { _requests.append(recorded) }
        let response = HTTPURLResponse(url: url, statusCode: recorded.method == "POST" ? 204 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body(for: recorded).utf8), response)
    }

    private func body(for request: Request) -> String {
        let movies = "f137a2dd21bbc1b99aa5c0f6bf02a805"
        let tv = "a8ee6ba847f2671fe06a474d749352b9"
        func items(_ list: [String]) -> String { #"{"Items":[\#(list.joined(separator: ","))],"TotalRecordCount":\#(list.count)}"# }
        func item(_ id: String, _ name: String, _ type: String, series: String? = nil,
                  position: Int64 = 0, played: String? = nil, extra: String = "") -> String {
            let seriesField = series.map { #","SeriesId":"\#($0)""# } ?? ""
            let playedField = played.map { #","LastPlayedDate":"\#($0)""# } ?? ""
            return #"{"Id":"\#(id)","Name":"\#(name)","Type":"\#(type)"\#(seriesField)\#(extra),"UserData":{"PlaybackPositionTicks":\#(position),"Played":false\#(playedField)}}"#
        }
        switch (request.method, request.path) {
        case ("POST", _):
            return ""
        case (_, "/UserViews"):
            return items([
                #"{"Id":"\#(movies)","Name":"Movies","Type":"CollectionFolder","CollectionType":"movies","UserData":{}}"#,
                #"{"Id":"\#(tv)","Name":"Real TV","Type":"CollectionFolder","CollectionType":"tvshows","UserData":{}}"#,
                #"{"Id":"f4415c72cc16920fce19d78d636a3ce7","Name":"Home Videos","Type":"CollectionFolder","CollectionType":"homevideos","UserData":{}}"#,
                #"{"Id":"52f1cc5cfe5ba8c9452cebe7bca9e026","Name":"Photos","Type":"CollectionFolder","CollectionType":"photos","UserData":{}}"#,
                #"{"Id":"9d7ad6afe9afa2dab1a2f6e00ad28fa6","Name":"Collections","Type":"CollectionFolder","CollectionType":"boxsets","UserData":{}}"#,
                #"{"Id":"07ccd1a1904596a9f460271dd5d0b0da","Name":"Playlists","Type":"CollectionFolder","CollectionType":"playlists","UserData":{}}"#,
            ])
        case (_, "/Items") where request.query["limit"] == "0":
            // Home Videos holds videos.
            return #"{"Items":[],"TotalRecordCount":\#(request.query["includeItemTypes"] == "Video" ? 5 : 0)}"#
        case (_, "/Users/Me"):
            let excluded = excludes.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"Id":"7b20244faaf946818eac31a8f0f72c7b","Name":"duskcompare","Configuration":{"CastReceiverId":"F007D354","LatestItemsExcludes":[\#(excluded)],"OrderedViews":[]}}"#
        case (_, "/Items/Latest"):
            return "[" + [item("00000000000000000000000000000l01", "Latest 1", "Movie"),
                          item("00000000000000000000000000000l02", "Latest 2", "Movie")].joined(separator: ",") + "]"
        case (_, "/UserItems/Resume"):
            guard request.query["parentId"] == movies else { return items([]) }
            return items([item("0000000000000000000000000000bbbb", "Big Buck Bunny", "Movie",
                               position: 790_000_000, played: "2026-11-27T20:52:08.0000000Z")])
        case (_, "/Shows/NextUp"):
            return items([
                item(Self.nextUpEpisode, "Diversity Day", "Episode", series: "4eb7e22c1653ab565cf44daa4176ca56"),
                item("689ee48ed9f46ad912e68b6955d4e1fa", "The You You Are", "Episode", series: "7820db538a32435f48c0a565e198f893"),
            ])
        case (_, "/Items"):
            // The played episodes that date Next Up.
            return items([
                item("0000000000000000000000000000ee01", "Pilot", "Episode", series: "4eb7e22c1653ab565cf44daa4176ca56",
                     played: "2026-11-27T21:30:00.0000000Z"),
                item("0000000000000000000000000000ee02", "Half Loop", "Episode", series: "7820db538a32435f48c0a565e198f893",
                     played: "2026-11-27T19:00:00.0000000Z"),
            ].map { $0.replacingOccurrences(of: #""Played":false"#, with: #""Played":true"#) })
        case (_, let path) where path == "/Items/\(Self.resumableEpisode)":
            return item(Self.resumableEpisode, "Basketball", "Episode", series: "4eb7e22c1653ab565cf44daa4176ca56", position: 5_000)
        case (_, let path) where path == "/Items/\(Self.nextUpEpisode)":
            return item(Self.nextUpEpisode, "Diversity Day", "Episode", series: "4eb7e22c1653ab565cf44daa4176ca56")
        default:
            return "{}"
        }
    }
}

/// Records what `PlexHomeRows` sends.
@MainActor
private final class RecordingPlexTransport: PlexServerTransport {
    var requests: [String] = []

    func rawServerRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?,
        timeoutInterval: TimeInterval?,
        serverID: String?
    ) async throws -> Data {
        let query = (queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        requests.append("\(method) \(path)?\(query) @\(serverID ?? "nil")\(timeoutInterval.map { " t\($0)" } ?? "")")
        return Data()
    }

    func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data, serverID: String?) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
