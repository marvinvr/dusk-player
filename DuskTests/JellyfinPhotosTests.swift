import Foundation
import Testing
@testable import Dusk

/// J-10: photo library pages as `/Items` queries and `BaseItemDto` →
/// `PhotoItem` (docs/jellyfin/02-jellyfin-api-mapping.md §13).
@MainActor
struct JellyfinPhotosTests {
    nonisolated private static let serverID = "99d23e4060434e129f9ae072bf97d30d"
    nonisolated private static let userID = "7b20244faaf946818eac31a8f0f72c7b"

    private func parameters(_ query: JellyfinItemQuery) -> [String: String] {
        Dictionary(query.queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    // MARK: Queries

    @Test func albumsAreTheFoldersDirectlyInsideTheParent() {
        let root = parameters(JellyfinPhotos.query(libraryID: "lib", query: .albums(parent: nil), start: 0, size: 60))
        #expect(root["parentId"] == "lib")
        // With a library as the parent, `includeItemTypes` alone walks the tree.
        #expect(root["recursive"] == "false")
        #expect(root["includeItemTypes"] == "PhotoAlbum,Folder")
        #expect(root["sortBy"] == "SortName")
        #expect(root["sortOrder"] == "Ascending")
        #expect(root["startIndex"] == "0")
        #expect(root["limit"] == "60")
        #expect(root["enableTotalRecordCount"] == "true")

        let nested = parameters(JellyfinPhotos.query(libraryID: "lib", query: .albums(parent: "album"), start: 60, size: 150))
        #expect(nested["parentId"] == "album")
        #expect(nested["recursive"] == "false")
        #expect(nested["startIndex"] == "60")
    }

    @Test func albumMediaIsOldestFirstLikePlex() {
        let sent = parameters(JellyfinPhotos.query(libraryID: "lib", query: .media(parent: "album"), start: 0, size: 60))
        #expect(sent["parentId"] == "album")
        #expect(sent["recursive"] == "false")
        #expect(sent["includeItemTypes"] == "Photo,Video")
        #expect(sent["sortBy"] == "PremiereDate,SortName")
        #expect(sent["sortOrder"] == "Ascending")
        #expect(sent["fields"] == "DateCreated,Width,Height")

        let loose = parameters(JellyfinPhotos.query(libraryID: "lib", query: .media(parent: nil), start: 0, size: 60))
        #expect(loose["parentId"] == "lib")
        #expect(loose["recursive"] == "false")
    }

    @Test func timelineIsTheWholeLibraryNewestFirst() {
        let sent = parameters(JellyfinPhotos.query(libraryID: "lib", query: .timeline, start: 150, size: 150))
        #expect(sent["parentId"] == "lib")
        #expect(sent["recursive"] == "true")
        #expect(sent["includeItemTypes"] == "Photo,Video")
        #expect(sent["sortBy"] == "DateCreated,SortName")
        #expect(sent["sortOrder"] == "Descending,Ascending")
        #expect(sent["startIndex"] == "150")
    }

    // MARK: Mapping

    @Test func albumsFoldersPhotosAndClips() throws {
        let album = try map(#"{"Id":"A84083D1-3066-DE65-6879-18CD5992577F","Name":"2025 Summer Trip","Type":"PhotoAlbum","IsFolder":true,"ImageTags":{"Primary":"23cb"}}"#)
        #expect(album.kind == .album)
        #expect(album.itemID == "a84083d13066de65687918cd5992577f")
        #expect(album.serverID == Self.serverID)
        #expect(album.thumb == "jf:a84083d13066de65687918cd5992577f:Primary:0:23cb")
        #expect(album.composite == nil)

        let folder = try map(#"{"Id":"58455f87e1e4950304f36f9460038bb3","Name":"2026","Type":"Folder","IsFolder":true}"#)
        #expect(folder.kind == .album)
        #expect(folder.thumb == nil)

        let photo = try map(#"""
        {"Id":"924c27aea22476b7968270714d789cbb","Name":"Rotated_Orientation6","Type":"Photo","MediaType":"Photo",
         "PremiereDate":"2025-09-14T09:00:00.0000000Z","DateCreated":"2025-09-14T09:00:00.0000000Z","ProductionYear":2025,
         "Width":1600,"Height":1067,"ImageOrientation":"RightTop","CameraMake":"Dusk","CameraModel":"T-0 Generator",
         "ImageTags":{"Primary":"de59"}}
        """#)
        #expect(photo.kind == .photo)
        #expect(photo.partKey == nil)
        #expect(photo.originallyAvailableAt == JellyfinItemMapper.photoDay(JellyfinDate(raw: "2025-09-14T09:00:00Z")))
        #expect(photo.addedAt == 1_757_840_400)
        #expect(photo.year == 2025)
        #expect(photo.duration == nil)
        #expect(photo.width == 1600 && photo.height == 1067)
        #expect(photo.displayCamera == "Dusk T-0 Generator")
        #expect(photo.places.isEmpty)

        let clip = try map(#"{"Id":"2dcede876f3e9868ef5664e64b8f26e5","Name":"Clip_2025-10-05","Type":"Video","MediaType":"Video","RunTimeTicks":80000000,"PremiereDate":"2025-10-05T15:20:00.0000000Z"}"#)
        #expect(clip.kind == .clip)
        #expect(clip.isClip)
        #expect(clip.duration == 8000)
        #expect(clip.originallyAvailableAt == JellyfinItemMapper.photoDay(JellyfinDate(raw: "2025-10-05T15:20:00Z")))

        let other = try map(#"{"Id":"0aeb03d7340c7ed459b9caecd0caaba0","Name":"Song","Type":"Audio"}"#)
        #expect(other.kind == nil)
    }

    /// The server stores the EXIF time converted from its own zone to UTC; the
    /// day is read in the device's zone and never rounded to the next midnight.
    @Test func photoDayIsTheLocalDayUnrounded() throws {
        let zurich = try #require(TimeZone(identifier: "Europe/Zurich"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        // EXIF 09:15, 18:40, 20:10 local → stored 07:15Z, 16:40Z, 19:10Z.
        #expect(JellyfinItemMapper.photoDay(JellyfinDate(raw: "2025-08-03T07:15:00.0000000Z"), in: zurich) == "2025-08-03")
        #expect(JellyfinItemMapper.photoDay(JellyfinDate(raw: "2025-08-21T16:40:00.0000000Z"), in: zurich) == "2025-08-21")
        #expect(JellyfinItemMapper.photoDay(JellyfinDate(raw: "2025-10-30T19:10:00.0000000Z"), in: zurich) == "2025-10-30")
        // A photo taken at 00:30 in Zurich is stored on the previous UTC day.
        #expect(JellyfinItemMapper.photoDay(JellyfinDate(raw: "2025-08-02T22:30:00Z"), in: zurich) == "2025-08-03")
        #expect(JellyfinItemMapper.photoDay(JellyfinDate(raw: "2025-08-03T23:59:59Z"), in: utc) == "2025-08-03")
        #expect(JellyfinItemMapper.photoDay(nil) == nil)
    }

    /// No EXIF date: the grid shows the file date.
    @Test func undatedPhotoFallsBackToDateCreated() throws {
        let photo = try map(#"{"Id":"0743fc2eb2b4a8a565141d01232abb19","Name":"photo_7","Type":"Photo","DateCreated":"2026-10-20T04:17:41.2041034Z"}"#)
        #expect(photo.originallyAvailableAt == nil)
        #expect(photo.addedAt == 1_792_469_861)
        #expect(photo.displayDate != nil)
    }

    // MARK: Catalog over a stub server

    @Test func pageMapsAlbumsAndKeepsTheTotal() async throws {
        let server = StubPhotoServer(body: #"""
        {"Items":[
          {"Id":"a84083d1306de65687918cd5992577f9","Name":"Trip","Type":"PhotoAlbum","UserData":{}},
          {"Id":"58455f87e1e4950304f36f9460038bb3","Name":"2026","Type":"Folder","UserData":{}}
        ],"TotalRecordCount":7,"StartIndex":0}
        """#)
        let client = JellyfinClient(
            baseURL: URL(string: "http://jellyfin.test")!,
            identity: .dusk(deviceID: "device-test"),
            credentials: JellyfinCredentials(accessToken: "tok", userID: Self.userID),
            transport: server
        )
        let catalog = JellyfinCatalog(serverID: Self.serverID, client: { client })
        let page = try await catalog.photoPage(libraryID: "lib", query: .albums(parent: nil), start: 0, size: 3)
        #expect(page.items.map(\.title) == ["Trip", "2026"])
        #expect(page.items.allSatisfy { $0.isAlbum })
        #expect(page.totalSize == 7)
        let sent = try #require(server.requests.last)
        #expect(sent["parentId"] == "lib")
        #expect(sent["userId"] == Self.userID)
    }

    private func map(_ json: String) throws -> PhotoItem {
        let dto = try JellyfinJSON.decode(JellyfinItemDTO.self, from: Data(json.utf8))
        return JellyfinItemMapper.photoItem(dto, serverID: Self.serverID)
    }
}

/// Answers every request with one `/Items` body and records the queries.
private final class StubPhotoServer: JellyfinTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let body: String
    private var _requests: [[String: String]] = []

    init(body: String) { self.body = body }

    var requests: [[String: String]] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        lock.withLock { _requests.append(query) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}
