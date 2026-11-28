import Foundation
import Testing
@testable import Dusk

/// J-02: the neutral browse vocabulary as `/Items` parameters, the A–Z table
/// and the catalog over a stub server. The server ignores parameters it does
/// not know (02 §0), so every check reads the query that is sent or the
/// result that comes back, never a status code.
@MainActor
struct JellyfinCatalogTests {
    nonisolated private static let serverID = "99d23e4060434e129f9ae072bf97d30d"
    nonisolated private static let userID = "7b20244faaf946818eac31a8f0f72c7b"

    private typealias Vocabulary = JellyfinBrowseVocabulary

    private func parameters(_ query: JellyfinItemQuery) -> [String: String] {
        Dictionary(query.queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    // MARK: Sorts

    @Test func sortsMapOntoSortKeysWithASortNameTiebreak() {
        var query = JellyfinItemQuery()
        Vocabulary.apply(sort: LibrarySortOption(.addedAt), to: &query)
        #expect(parameters(query)["sortBy"] == "DateCreated,SortName")
        #expect(parameters(query)["sortOrder"] == "Descending,Ascending")

        Vocabulary.apply(sort: .titleDescending, to: &query)
        #expect(parameters(query)["sortBy"] == "SortName")
        #expect(parameters(query)["sortOrder"] == "Descending")

        Vocabulary.apply(sort: nil, to: &query)
        #expect(parameters(query)["sortBy"] == "SortName")
        #expect(parameters(query)["sortOrder"] == "Ascending")

        var random = JellyfinItemQuery()
        Vocabulary.apply(sort: LibrarySortOption(.random), to: &random)
        #expect(parameters(random)["sortBy"] == "Random")
        #expect(parameters(random)["sortOrder"] == nil)

        let keys = LibrarySortField.allCases.filter { $0 != .userRating }.map { Vocabulary.sortKey($0).rawValue }
        #expect(keys == ["SortName", "PremiereDate", "ProductionYear", "DateCreated", "DateLastContentAdded",
                         "CriticRating", "CommunityRating", "Runtime", "DatePlayed", "Random"])
    }

    @Test func yourRatingIsNotOffered() {
        for kind in [LibraryKind.movie, .show, .video] {
            #expect(!Vocabulary.sortFields(for: kind).contains(.userRating))
        }
        #expect(Vocabulary.sortFields(for: .movie).first == .title)
    }

    // MARK: Filters

    @Test func filtersMapOntoItemsParameters() {
        var filter = LibraryFilter(genre: "Science Fiction", watchStatus: .unwatched)
        filter.choices = ["decade": "2010", "contentRating": "PG-13", "resolution": "hd", "studio": "s1"]
        let query = Vocabulary.baseQuery(libraryID: "lib", kind: .movie, filter: filter)
        let sent = parameters(query)
        #expect(sent["parentId"] == "lib")
        #expect(sent["recursive"] == "true")
        #expect(sent["includeItemTypes"] == "Movie")
        #expect(sent["genres"] == "Science Fiction")
        #expect(sent["isPlayed"] == "false")
        #expect(sent["years"] == (2010...2019).map(String.init).joined(separator: ","))
        #expect(sent["officialRatings"] == "PG-13")
        #expect(sent["isHD"] == "true")
        #expect(sent["is4K"] == "false")
        #expect(sent["studioIds"] == "s1")
    }

    @Test func watchStateAndPeopleByKind() {
        let watched = parameters(Vocabulary.baseQuery(libraryID: "tv", kind: .show, filter: LibraryFilter(watchStatus: .watched)))
        #expect(watched["includeItemTypes"] == "Series")
        #expect(watched["isPlayed"] == "true")

        let resumable = parameters(Vocabulary.baseQuery(libraryID: "m", kind: .movie, filter: LibraryFilter(watchStatus: .inProgress)))
        #expect(resumable["filters"] == "IsResumable")

        let director = parameters(Vocabulary.baseQuery(libraryID: "m", kind: .movie, filter: LibraryFilter(choices: ["director": "p1"])))
        #expect(director["personIds"] == "p1")
        #expect(director["personTypes"] == "Director")

        let actor = parameters(Vocabulary.baseQuery(libraryID: "m", kind: .movie, filter: LibraryFilter(choices: ["actor": "p2"])))
        #expect(actor["personTypes"] == "Actor,GuestStar")

        let uhd = parameters(Vocabulary.baseQuery(libraryID: "m", kind: .movie, filter: LibraryFilter(choices: ["resolution": "4k"])))
        #expect(uhd["is4K"] == "true")
        #expect(uhd["isHD"] == nil)

        let videos = parameters(Vocabulary.baseQuery(libraryID: "v", kind: .video, filter: LibraryFilter()))
        #expect(videos["includeItemTypes"] == "Video")

        // A photo library counts its photos too, or the libraries list hides it.
        let photos = parameters(Vocabulary.baseQuery(libraryID: "p", kind: .photo, filter: LibraryFilter()))
        #expect(photos["includeItemTypes"] == "Photo,Video")
    }

    @Test func collectionMatchesItsMembersInsideTheLibrary() {
        let query = Vocabulary.baseQuery(
            libraryID: "lib", kind: .movie, filter: LibraryFilter(choices: ["collection": "box"]), collectionMembers: ["a", "b"]
        )
        let sent = parameters(query)
        #expect(sent["parentId"] == "lib")
        #expect(sent["ids"] == "a,b")
    }

    @Test func sheetFieldsFollowPlexOrderWithoutTheMissingOnes() {
        #expect(Vocabulary.filterParameters(for: .movie, includesCollection: true).map(\.rawValue)
            == ["decade", "year", "contentRating", "resolution", "studio", "collection", "director", "actor"])
        #expect(Vocabulary.filterParameters(for: .show, includesCollection: false).map(\.rawValue)
            == ["year", "contentRating", "studio", "director", "actor"])
        #expect(Vocabulary.filterParameters(for: .video, includesCollection: false).map(\.rawValue)
            == ["decade", "year", "resolution"])
    }

    @Test func choiceSourceRoundTrips() throws {
        let field = Vocabulary.field(.studio, libraryID: "lib1", kind: .show)
        guard case .values(let encoded) = field.kind else { Issue.record("not a values field"); return }
        let source = try #require(Vocabulary.ChoiceSource(encoded: encoded))
        #expect(source == Vocabulary.ChoiceSource(libraryID: "lib1", kind: .show, parameter: .studio))
        #expect(Vocabulary.ChoiceSource(encoded: "/library/sections/1/studio") == nil)
    }

    @Test func decadesAndYearsNewestFirst() {
        #expect(Vocabulary.decadeChoices(years: [2008, 2015, 2010, 2026]).map(\.title) == ["2020s", "2010s", "2000s"])
        #expect(Vocabulary.decadeChoices(years: [2015]).map(\.value) == ["2010"])
        #expect(Vocabulary.yearChoices(years: [2008, 2026, 2008]).map(\.value) == ["2026", "2008"])
    }

    // MARK: A–Z

    @Test func letterTableFromNameLessThanCounts() {
        // Paging Test on jellyfin-demo: 10 titles before "A", 22 in A, …
        var below: [String: Int] = [:]
        var running = 10
        for letter in Vocabulary.letters {
            below[letter] = running
            running += letter == "A" ? 22 : (letter == "Q" ? 0 : 19)
        }
        let rows = Vocabulary.letterCounts(below: below, total: running)
        #expect(rows.first == LibraryLetterCount(key: "#", size: 10))
        #expect(rows.dropFirst().first == LibraryLetterCount(key: "A", size: 22))
        #expect(!rows.contains { $0.key == "Q" })
        #expect(rows.reduce(0) { $0 + $1.size } == running)

        let index = LibraryLetterIndex(characters: rows, descending: false)
        #expect(index.entries.first { $0.label == "B" }?.offset == 32)
        #expect(index.entries.first { $0.label == "Q" }?.isAvailable == false)

        #expect(Vocabulary.letterCounts(below: ["A": 0], total: 3).isEmpty)
    }

    // MARK: Mapping

    @Test func extraKindsAndThemeVideos() {
        #expect(JellyfinItemMapper.extraKind("Trailer") == .trailer)
        #expect(JellyfinItemMapper.extraKind("BehindTheScenes") == .behindTheScenes)
        #expect(JellyfinItemMapper.extraKind("DeletedScene") == .deletedScene)
        #expect(JellyfinItemMapper.extraKind("Sample") == .sceneOrSample)
        #expect(JellyfinItemMapper.extraKind("Unknown") == .other)
        #expect(JellyfinItemMapper.extraKind("ThemeVideo") == nil)
    }

    @Test func castMemberCarriesItsPersonID() {
        let role = JellyfinItemMapper.mapRole(JellyfinPersonDTO(
            id: "7756EF19-2111-66D2-D529-0B3EB1D354B9", name: "Daniel Craig", role: "Benoit Blanc",
            type: .actor, primaryImageTag: nil
        ))
        #expect(role.personID == "7756ef19211166d2d5290b3eb1d354b9")
        #expect(PersonReference(role: role).personID == "7756ef19211166d2d5290b3eb1d354b9")
    }

    @Test func homeVideosViewWithPhotosIsAPhotoLibrary() throws {
        let view = try JellyfinJSON.decode(JellyfinItemDTO.self, from: Data(
            #"{"Id":"52f1cc5cfe5ba8c9452cebe7bca9e026","Name":"Photos","CollectionType":"homevideos"}"#.utf8))
        #expect(JellyfinItemMapper.mapLibrary(view, serverID: Self.serverID)?.libraryType == .video)
        #expect(JellyfinItemMapper.mapLibrary(view, serverID: Self.serverID, homeVideosHoldPhotos: true)?.libraryType == .photo)
    }

    // MARK: Catalog over a stub server

    @Test func letterCountsAreCachedUntilTheTotalChanges() async throws {
        let server = StubItemsServer(sortNames: ["#tag", "alpha", "amber", "beta", "zulu"])
        let catalog = makeCatalog(server)

        let rows = try await catalog.letterCounts(libraryID: "cache-\(UUID().uuidString)", kind: .movie, filter: LibraryFilter())
        #expect(rows == [
            LibraryLetterCount(key: "#", size: 1), LibraryLetterCount(key: "A", size: 2),
            LibraryLetterCount(key: "B", size: 1), LibraryLetterCount(key: "Z", size: 1),
        ])
        #expect(server.requests.count == 27)

        let libraryID = "cache-fixed"
        _ = try await catalog.letterCounts(libraryID: libraryID, kind: .movie, filter: LibraryFilter())
        let afterFirst = server.requests.count
        _ = try await catalog.letterCounts(libraryID: libraryID, kind: .movie, filter: LibraryFilter())
        #expect(server.requests.count == afterFirst + 1)

        server.sortNames.append("yak")
        let grown = try await catalog.letterCounts(libraryID: libraryID, kind: .movie, filter: LibraryFilter())
        #expect(grown.contains(LibraryLetterCount(key: "Y", size: 1)))
    }

    @Test func pageMapsItemsAndAsksForThePageOnly() async throws {
        let server = StubItemsServer(sortNames: ["alpha", "beta", "gamma"])
        let items = try await makeCatalog(server).items(
            libraryID: "lib", kind: .movie, start: 1, size: 2, sort: .titleAscending, filter: LibraryFilter()
        )
        #expect(items.map(\.title) == ["beta", "gamma"])
        #expect(items.allSatisfy { $0.serverID == Self.serverID && $0.libraryID == "lib" })
        let sent = try #require(server.requests.last)
        #expect(sent["startIndex"] == "1")
        #expect(sent["limit"] == "2")
        #expect(sent["userId"] == Self.userID)
    }

    private func makeCatalog(_ server: StubItemsServer) -> JellyfinCatalog {
        let client = JellyfinClient(
            baseURL: URL(string: "http://jellyfin.test")!,
            identity: .dusk(deviceID: "device-test"),
            credentials: JellyfinCredentials(accessToken: "tok", userID: Self.userID),
            transport: server
        )
        return JellyfinCatalog(serverID: Self.serverID, client: { client })
    }
}

/// `/Items` over a list of sort names: honours `nameLessThan`, `startIndex`,
/// `limit` (0 = count only), and records every query.
private final class StubItemsServer: JellyfinTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sortNames: [String]
    private var _requests: [[String: String]] = []

    init(sortNames: [String]) { _sortNames = sortNames }

    var sortNames: [String] {
        get { lock.withLock { _sortNames } }
        set { lock.withLock { _sortNames = newValue } }
    }

    var requests: [[String: String]] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        var names = lock.withLock {
            _requests.append(query)
            return _sortNames.sorted()
        }
        if let bound = query["nameLessThan"]?.lowercased() {
            names = names.filter { $0 < bound }
        }
        let total = names.count
        let start = Int(query["startIndex"] ?? "") ?? 0
        let limit = Int(query["limit"] ?? "") ?? names.count
        let page = names.dropFirst(start).prefix(limit)
        let items = page.enumerated().map { offset, name in
            #"{"Id":"\#(String(format: "%032x", start + offset + 1))","Name":"\#(name)","SortName":"\#(name)","Type":"Movie","UserData":{"Played":false}}"#
        }
        let body = #"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":\#(total),"StartIndex":\#(start)}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
