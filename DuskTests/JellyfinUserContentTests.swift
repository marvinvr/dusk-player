import Foundation
import Testing
@testable import Dusk

/// J-07: playlists, collections and the Watchlist on Jellyfin, over a stub
/// server that answers by path and records every request.
@MainActor
@Suite("Jellyfin playlists, collections, watchlist")
struct JellyfinUserContentTests {
    nonisolated private static let userID = "7b20244faaf946818eac31a8f0f72c7b"

    nonisolated private static func id(_ n: Int) -> String { String(format: "%032x", n) }

    private func client(_ server: StubContentServer) -> JellyfinClient {
        JellyfinClient(
            baseURL: URL(string: "http://jellyfin.test")!,
            identity: .dusk(deviceID: "device-test"),
            credentials: JellyfinCredentials(accessToken: "tok", userID: Self.userID),
            transport: server
        )
    }

    // MARK: Playlists

    @Test func repeatsOfAnItemGetTheirOwnEntryIDs() throws {
        let a = Self.id(1), b = Self.id(2)
        let json = """
        [{"Id":"\(a)","Name":"A","Type":"Movie","PlaylistItemId":"\(a)"},
         {"Id":"\(b)","Name":"B","Type":"Movie","PlaylistItemId":"\(b)"},
         {"Id":"\(a)","Name":"A","Type":"Movie","PlaylistItemId":"\(a)"}]
        """
        let dtos = try JSONDecoder().decode([JellyfinItemDTO].self, from: Data(json.utf8))
        let entries = JellyfinItemMapper.playlistEntries(dtos, serverID: Self.id(99))
        #expect(entries.map(\.playlistItemID) == [a, b, a])
        #expect(entries.map(\.id) == [a, b, "\(a)#1"])
        #expect(Set(entries.map(\.id)).count == 3)
    }

    @Test func plexEntryIDsAreUnchanged() {
        let item = FakeMedia.item(serverID: "plex-server", itemID: "83468", type: .movie, title: "Amber Atlas")
        #expect(PlaylistEntry(playlistItemID: "10", item: item).id == "10")
        #expect(PlaylistEntry(playlistItemID: nil, item: item).id == item.id.storageKey)
    }

    @Test func moveAfterBecomesTheIndexWithoutTheMovedEntry() async throws {
        let (a, b, c, d) = (Self.id(1), Self.id(2), Self.id(3), Self.id(4))
        let server = StubContentServer { request in
            guard request.method == "GET", request.path == "/Playlists/p1/Items" else { return nil }
            return .items([a, b, c, d].map { #"{"Id":"\#($0)","Type":"Movie","PlaylistItemId":"\#($0)","UserData":{}}"# })
        }
        let playlists = JellyfinPlaylists(serverID: Self.id(99), client: { [client] in client(server) })

        try await playlists.moveEntry(a, after: d, in: "p1")
        try await playlists.moveEntry(c, after: a, in: "p1")
        try await playlists.moveEntry(d, after: nil, in: "p1")

        let moves = server.requests.filter { $0.method == "POST" }.map(\.path)
        #expect(moves == ["/Playlists/p1/Items/\(a)/Move/3", "/Playlists/p1/Items/\(c)/Move/1", "/Playlists/p1/Items/\(d)/Move/0"])
        // To the top needs no read of the order.
        #expect(server.requests.filter { $0.method == "GET" }.count == 2)
    }

    @Test func addSkipsWhatIsThereAndExpandsShows() async throws {
        let (movie, show, e1, e2) = (Self.id(1), Self.id(2), Self.id(3), Self.id(4))
        let server = StubContentServer { request in
            switch (request.method, request.path) {
            case ("GET", "/Playlists/p1"):
                return .json(#"{"OpenAccess":false,"Shares":[],"ItemIds":["\#(e1)"]}"#)
            case ("GET", "/Items") where request.query["ids"] != nil:
                return .items([#"{"Id":"\#(movie)","Type":"Movie"}"#, #"{"Id":"\#(show)","Type":"Series"}"#])
            case ("GET", "/Items") where request.query["parentId"] == show:
                return .items([#"{"Id":"\#(e1)","Type":"Episode"}"#, #"{"Id":"\#(e2)","Type":"Episode"}"#])
            default:
                return nil
            }
        }
        let playlists = JellyfinPlaylists(serverID: Self.id(99), client: { [client] in client(server) })

        let result = try await playlists.add(itemIDs: [movie, show], to: "p1")

        #expect(result == PlaylistAddResult(added: 2, requested: 3))
        let add = try #require(server.requests.first { $0.method == "POST" })
        #expect(add.path == "/Playlists/p1/Items")
        #expect(add.query["ids"] == "\(movie),\(e2)")
    }

    @Test func addingOnlyRepeatsSendsNothing() async throws {
        let movie = Self.id(1)
        let server = StubContentServer { request in
            switch (request.method, request.path) {
            case ("GET", "/Playlists/p1"): return .json(#"{"ItemIds":["\#(movie)"]}"#)
            case ("GET", "/Items"): return .items([#"{"Id":"\#(movie)","Type":"Movie"}"#])
            default: return nil
            }
        }
        let playlists = JellyfinPlaylists(serverID: Self.id(99), client: { [client] in client(server) })

        let result = try await playlists.add(itemIDs: [movie], to: "p1")

        #expect(result == PlaylistAddResult(added: 0, requested: 1))
        #expect(!server.requests.contains { $0.method == "POST" })
    }

    // MARK: Collections

    @Test func aLibraryListsTheCollectionsWithATitleInIt() async throws {
        let serverID = Self.id(0xC01)
        let (films, mixed, film, show, library) = (Self.id(11), Self.id(12), Self.id(13), Self.id(14), Self.id(15))
        let filmsJSON = #"{"Id":"\#(films)","Name":"Films","Type":"BoxSet","UserData":{}}"#
        let mixedJSON = #"{"Id":"\#(mixed)","Name":"Mixed","Type":"BoxSet","UserData":{}}"#
        let server = StubContentServer { request in
            guard request.method == "GET", request.path == "/Items" else { return nil }
            if request.query["includeItemTypes"] == "BoxSet" {
                // The server lists a library's BoxSets itself; by id; or all.
                if request.query["parentId"] == library { return .items([filmsJSON]) }
                if request.query["ids"] == mixed { return .items([mixedJSON]) }
                return .items([filmsJSON, mixedJSON])
            }
            switch request.query["parentId"] {
            case films:
                return .items([#"{"Id":"\#(film)","Type":"Movie","ImageTags":{"Primary":"tag1"},"UserData":{}}"#])
            case mixed:
                return .items([#"{"Id":"\#(show)","Type":"Series","UserData":{}}"#])
            default:
                return nil
            }
        }
        let catalog = JellyfinCatalog(serverID: serverID, client: { [client] in client(server) })

        let page = try await catalog.collections(libraryID: library, start: 0, size: 50)

        #expect(page.items.map(\.title) == ["Films"])
        #expect(page.totalSize == 1)
        let collection = try #require(page.items.first)
        #expect(collection.type == .collection)
        #expect(collection.childCount == 1)
        #expect(collection.collectionCountLabel == "1 movie")
        #expect(collection.thumb == JellyfinArtworkLocator(itemID: film, type: .primary, tag: "tag1").locator)

        let partOf = try await catalog.collections(containing: show, libraryID: nil, tags: [])
        #expect(partOf.map(\.title) == ["Mixed"])
        #expect(try await catalog.collection(itemID: mixed)?.title == "Mixed")

        // A BoxSet's titles are read once and reused.
        let childReads = server.requests.filter { $0.query["parentId"] == films }
        #expect(childReads.count == 1)
    }

    @Test func theCollectionFilterKeepsOnlyTheLibrarysTitles() async throws {
        let serverID = Self.id(0xC03)
        let (box, here, elsewhere, library) = (Self.id(21), Self.id(22), Self.id(23), Self.id(24))
        let server = StubContentServer { request in
            switch request.path {
            case "/Items/\(here)/Ancestors":
                return .json(#"[{"Id":"\#(library)","Type":"CollectionFolder"}]"#)
            case "/Items/\(elsewhere)/Ancestors":
                return .json(#"[{"Id":"\#(Self.id(25))","Type":"CollectionFolder"}]"#)
            case "/Items" where request.query["includeItemTypes"] == "BoxSet":
                return .items([#"{"Id":"\#(box)","Name":"Box","Type":"BoxSet","UserData":{}}"#])
            case "/Items" where request.query["parentId"] == box:
                return .items([#"{"Id":"\#(here)","Type":"Movie","UserData":{}}"#,
                               #"{"Id":"\#(elsewhere)","Type":"Movie","UserData":{}}"#])
            default:
                return nil
            }
        }
        let catalog = JellyfinCatalog(serverID: serverID, client: { [client] in client(server) })
        let ids = try await catalog.collectionMemberIDs(box, inLibrary: library, client: client(server))
        #expect(ids == [here])
    }

    @Test func collectionItemsKeepTheCollectionOrderUnlessSorted() async throws {
        let server = StubContentServer { request in
            guard request.path == "/Items" else { return nil }
            return .items([#"{"Id":"\#(Self.id(1))","Type":"Movie","UserData":{}}"#], total: 7)
        }
        let catalog = JellyfinCatalog(serverID: Self.id(0xC02), client: { [client] in client(server) })

        let page = try await catalog.collectionItems(collectionID: "box", start: 0, size: 1, sort: nil)
        #expect(page.totalSize == 7)
        #expect(server.requests.last?.query["parentId"] == "box")
        #expect(server.requests.last?.query["sortBy"] == nil)

        _ = try await catalog.collectionItems(collectionID: "box", start: 0, size: 1, sort: .titleDescending)
        #expect(server.requests.last?.query["sortBy"] == "SortName")
        #expect(server.requests.last?.query["sortOrder"] == "Descending")
    }

    // MARK: Watchlist

    @Test func watchlistEntriesAreTheirOwnServerCopy() throws {
        let serverID = Self.id(0xF00)
        let item = FakeMedia.item(serverID: serverID, itemID: Self.id(1), type: .movie, title: "Film")
        let entry = try #require(JellyfinItemMapper.watchlistEntry(for: item))
        #expect(entry.serverItem?.id == item.id)
        #expect(entry.thumb == nil)
        let target = try #require(JellyfinItemMapper.watchlistTarget(entry.guid))
        #expect(target.serverID == serverID)
        #expect(target.itemID == Self.id(1))

        #expect(JellyfinItemMapper.watchlistEntry(for: FakeMedia.item(serverID: serverID, itemID: Self.id(2), type: .episode, title: "Pilot")) == nil)
        #expect(JellyfinItemMapper.watchlistTarget("plex://movie/abc") == nil)
    }
}

/// One request as the stub saw it.
struct StubContentRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
}

/// Answers from a closure; nil is `204` for a write and an empty list for a
/// read.
final class StubContentServer: JellyfinTransport, @unchecked Sendable {
    enum Answer {
        case json(String)

        static func items(_ items: [String], total: Int? = nil) -> Answer {
            .json(#"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":\#(total ?? items.count),"StartIndex":0}"#)
        }
    }

    private let lock = NSLock()
    private var recorded: [StubContentRequest] = []
    private let route: @Sendable (StubContentRequest) -> Answer?

    init(route: @escaping @Sendable (StubContentRequest) -> Answer?) {
        self.route = route
    }

    var requests: [StubContentRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let seen = StubContentRequest(
            method: request.httpMethod ?? "GET",
            path: components?.path ?? "",
            query: Dictionary(
                (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                uniquingKeysWith: { _, last in last }
            )
        )
        lock.withLock { recorded.append(seen) }
        let answer = route(seen)
        let body: String
        let status: Int
        switch answer {
        case .json(let json)?:
            body = json
            status = 200
        case nil where seen.method == "GET":
            body = #"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#
            status = 200
        case nil:
            body = ""
            status = 204
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
