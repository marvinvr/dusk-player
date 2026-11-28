import Foundation
import Testing
@testable import Dusk

/// J-08a: Jellyfin's original-file request, its offline metadata snapshot
/// (envelope, file names, the online requests it repeats) and the credential
/// rules a download transfer follows.
@Suite("Jellyfin downloads")
struct JellyfinDownloadsTests {
    private static let server = "99d23e4060434e129f9ae072bf97d30d"
    private static let knivesOut = "980dffd6dfa0d8cfd69e5bd6b350e983"
    private static let theOffice = "4eb7e22c1653ab565cf44daa4176ca56"
    private static let seasonOne = "89b6f2f7378f55721704fcbc3b7b776f"

    private static func client(_ transport: any JellyfinTransport = JellyfinStubTransport()) -> JellyfinClient {
        JellyfinClient(
            baseURL: URL(string: "http://jellyfin.example:8096/jf")!,
            identity: JellyfinClientIdentity(client: "Dusk", device: "iPhone", deviceID: "device-1", version: "2.0.0"),
            credentials: JellyfinCredentials(accessToken: "0123abcd", userID: "user-1"),
            transport: transport
        )
    }

    // MARK: Storage names (wire format)

    /// Pinned: the file name of every Jellyfin snapshot on a device. Changing
    /// either string orphans the offline metadata of existing downloads.
    @Test func storageNamesArePinned() {
        let format = JellyfinMetadataSnapshotFormat()
        #expect(format.storageName(for: .details(itemID: Self.knivesOut)) == "jellyfin:/Items/980dffd6dfa0d8cfd69e5bd6b350e983")
        #expect(format.storageName(for: .children(itemID: Self.seasonOne)) == "jellyfin:/Items/89b6f2f7378f55721704fcbc3b7b776f/children")
        #expect(DownloadFileStore.hash(format.storageName(for: .details(itemID: Self.knivesOut)))
            == "163357ea577aa3a2ed7872bbbad5baf5d52703d81d39dea817a0b0ceacf54ddf")
        #expect(DownloadFileStore.hash(format.storageName(for: .children(itemID: Self.seasonOne)))
            == "6e8e9c2fe4061b56f7983ca47b569eca8381d74e09611cc4d5f202d0eaf02a3e")
        // The dashed id form names the same file.
        #expect(format.storageName(for: .details(itemID: "980dffd6-dfa0-d8cf-d69e-5bd6b350e983"))
            == format.storageName(for: .details(itemID: Self.knivesOut)))
    }

    // MARK: Envelope

    @Test func detailsDecodeLikeTheOnlineScreen() throws {
        let item = try JellyfinFixtures.data("item-knives-out")
        let segments = try JellyfinFixtures.data("media-segments-knives-out")
        let data = JellyfinMetadataSnapshotFormat.envelope(payload: item, segments: segments)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["provider"] as? String == "jellyfin")
        #expect(object["schema"] as? Int == 1)

        let cached = try #require(try JellyfinMetadataSnapshotFormat().details(from: data, serverID: Self.server).first)
        let online = JellyfinItemMapper.mapDetails(
            try JellyfinJSON.decode(JellyfinItemDTO.self, from: item),
            serverID: Self.server,
            markers: JellyfinMediaMapper.markers(try JellyfinJSON.decode(JellyfinQueryResult<JellyfinMediaSegmentDTO>.self, from: segments).items)
        )
        #expect(cached.itemID == online.itemID)
        #expect(cached.serverID == Self.server)
        #expect(cached.title == online.title)
        #expect(cached.media.map(\.id) == online.media.map(\.id))
        #expect(cached.media.first?.parts.first?.streams.map(\.id) == online.media.first?.parts.first?.streams.map(\.id))
        #expect(cached.markers.map(\.startTimeOffset) == online.markers.map(\.startTimeOffset))
        #expect(!cached.markers.isEmpty)
    }

    @Test func detailsWithoutSegmentsHaveNoMarkers() throws {
        let data = JellyfinMetadataSnapshotFormat.envelope(payload: try JellyfinFixtures.data("item-knives-out"))
        let cached = try #require(try JellyfinMetadataSnapshotFormat().details(from: data, serverID: Self.server).first)
        #expect(cached.markers.isEmpty)
        #expect(cached.itemID == Self.knivesOut)
    }

    @Test func childrenDecodeByType() throws {
        let format = JellyfinMetadataSnapshotFormat()
        let seasons = JellyfinMetadataSnapshotFormat.envelope(payload: try JellyfinFixtures.data("shows-seasons-the-office"))
        #expect(try format.seasons(from: seasons, serverID: Self.server).count == 9)
        #expect(try format.episodes(from: seasons, serverID: Self.server).isEmpty)

        let episodes = JellyfinMetadataSnapshotFormat.envelope(payload: try JellyfinFixtures.data("shows-episodes-the-office-s01"))
        let decoded = try format.episodes(from: episodes, serverID: Self.server)
        #expect(decoded.count == 6)
        #expect(decoded.allSatisfy { $0.serverID == Self.server })
        #expect(try format.seasons(from: episodes, serverID: Self.server).isEmpty)
    }

    /// A bare payload is Plex's; another provider's envelope or a newer schema
    /// is never read as Jellyfin's.
    @Test func foreignPayloadsAreRejected() throws {
        let format = JellyfinMetadataSnapshotFormat()
        let item = try JellyfinFixtures.data("item-knives-out")
        #expect(throws: (any Error).self) { try format.details(from: item, serverID: Self.server) }
        var other = Data(#"{"provider":"plex","schema":1,"payload":"#.utf8)
        other.append(item)
        other.append(Data("}".utf8))
        #expect(throws: (any Error).self) { try format.details(from: other, serverID: Self.server) }
        var newer = Data(#"{"provider":"jellyfin","schema":2,"payload":"#.utf8)
        newer.append(item)
        newer.append(Data("}".utf8))
        #expect(throws: (any Error).self) { try format.details(from: newer, serverID: Self.server) }
    }

    @Test func cacheStoresAndReadsJellyfinSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadFileStore(rootDirectory: root)
        let cache = MetadataSnapshotCache(
            fileStore: store,
            formats: MetadataSnapshotFormats([PlexMetadataSnapshotFormat(), JellyfinMetadataSnapshotFormat()])
        )
        let profile = "jellyfin-\(Self.server)-user-1"
        let data = JellyfinMetadataSnapshotFormat.envelope(payload: try JellyfinFixtures.data("item-knives-out"))
        try cache.storePayload(data, for: .details(itemID: Self.knivesOut), accountProfileID: profile, serverID: Self.server, kind: .jellyfin)
        #expect(cache.mediaDetails(accountProfileID: profile, serverID: Self.server, itemID: Self.knivesOut, kind: .jellyfin)?.title == "Knives Out")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "Metadata/Profiles/\(profile)/\(Self.server)/163357ea577aa3a2ed7872bbbad5baf5d52703d81d39dea817a0b0ceacf54ddf.json"
        ).path))
        // Plex's reader never picks up a Jellyfin file.
        #expect(cache.mediaDetails(accountProfileID: profile, serverID: Self.server, itemID: Self.knivesOut, kind: .plex) == nil)
    }

    // MARK: Fetching

    @Test func detailsFetchStoresTheItemAndItsSegments() async throws {
        let transport = RoutedTransport([
            "/jf/Items/\(Self.knivesOut)": try JellyfinFixtures.data("item-knives-out"),
            "/jf/MediaSegments/\(Self.knivesOut)": try JellyfinFixtures.data("media-segments-knives-out"),
        ])
        let data = try await JellyfinMetadataSnapshotFormat.fetch(.details(itemID: Self.knivesOut), client: Self.client(transport))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["payload"] as? [String: Any])?["Id"] as? String == Self.knivesOut)
        #expect(object["segments"] != nil)
        let item = try #require(transport.requests.first { $0.url?.path == "/jf/Items/\(Self.knivesOut)" })
        #expect(item.url?.query?.contains("userId=user-1") == true)
    }

    @Test func detailsFetchSurvivesMissingSegments() async throws {
        let transport = RoutedTransport(["/jf/Items/\(Self.knivesOut)": try JellyfinFixtures.data("item-knives-out")])
        let data = try await JellyfinMetadataSnapshotFormat.fetch(.details(itemID: Self.knivesOut), client: Self.client(transport))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["segments"] == nil)
    }

    /// `raw()` keeps the request's own checks: an answer for another item fails.
    @Test func detailsFetchRejectsAnotherItem() async throws {
        let transport = RoutedTransport(["/jf/Items/\(Self.theOffice)": try JellyfinFixtures.data("item-knives-out")])
        await #expect(throws: (any Error).self) {
            _ = try await JellyfinMetadataSnapshotFormat.fetch(.details(itemID: Self.theOffice), client: Self.client(transport))
        }
    }

    @Test func seriesChildrenAreItsSeasons() async throws {
        let transport = RoutedTransport([
            "/jf/Items": Data(#"{"Items":[{"Id":"\#(Self.theOffice)","Type":"Series"}],"TotalRecordCount":1}"#.utf8),
            "/jf/Shows/\(Self.theOffice)/Seasons": try JellyfinFixtures.data("shows-seasons-the-office"),
        ])
        let data = try await JellyfinMetadataSnapshotFormat.fetch(.children(itemID: Self.theOffice), client: Self.client(transport))
        #expect(try JellyfinMetadataSnapshotFormat().seasons(from: data, serverID: Self.server).count == 9)
        #expect(transport.requests.map { $0.url?.path } == ["/jf/Items", "/jf/Shows/\(Self.theOffice)/Seasons"])
    }

    @Test func seasonChildrenAreItsEpisodes() async throws {
        let episodes = try JellyfinFixtures.data("shows-episodes-the-office-s01")
        let transport = RoutedTransport([
            "/jf/Items": Data(#"{"Items":[{"Id":"\#(Self.seasonOne)","Type":"Season"}],"TotalRecordCount":1}"#.utf8),
        ], followUp: ["/jf/Items": episodes])
        let data = try await JellyfinMetadataSnapshotFormat.fetch(.children(itemID: Self.seasonOne), client: Self.client(transport))
        #expect(try JellyfinMetadataSnapshotFormat().episodes(from: data, serverID: Self.server).count == 6)
        let query = try #require(transport.requests.last?.url?.query)
        #expect(query.contains("parentId=\(Self.seasonOne)"))
        #expect(query.contains("includeItemTypes=Episode"))
        #expect(query.contains("isMissing=false"))
    }

    // MARK: Original file

    @Test func originalFileIsTheSourcesDownloadRoute() throws {
        let request = try #require(JellyfinDownloads.originalFileRequest(
            sourceID: "d3b6645f-8469-bbe6-01a5-fe21fd857945",
            client: Self.client()
        ))
        #expect(request.url?.absoluteString == "http://jellyfin.example:8096/jf/Items/d3b6645f8469bbe601a5fe21fd857945/Download")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains(#"Token="0123abcd""#) == true)
        // The token is in the header only, never in the URL.
        #expect(request.url?.query == nil)
    }

    // MARK: Transfer credential rules

    @Test func jellyfinCredentialNeverFollowsARedirectToAnotherHost() throws {
        let original = try #require(JellyfinDownloads.originalFileRequest(sourceID: Self.knivesOut, client: Self.client()))
        let sameHost = URLRequest(url: URL(string: "http://jellyfin.example:8096/jf/file.mkv")!)
        let otherHost = URLRequest(url: URL(string: "http://cdn.example/file.mkv")!)
        #expect(TransportSecurity.allowsRedirect(sameHost, original: original))
        #expect(!TransportSecurity.allowsRedirect(otherHost, original: original))

        var downgrade = original
        downgrade.url = URL(string: "https://jellyfin.example/jf/Items/x/Download")
        #expect(!TransportSecurity.allowsRedirect(URLRequest(url: URL(string: "http://jellyfin.example/x")!), original: downgrade))
        #expect(throws: (any Error).self) {
            var bad = original
            bad.url = URL(string: "file:///tmp/x")
            try TransportSecurity.validate(bad)
        }
    }

    /// Requests without a Jellyfin credential keep Plex's rules exactly.
    @Test func plexRequestsKeepTheirRules() throws {
        var plex = URLRequest(url: URL(string: "http://plex.example:32400/library/parts/1/file.mkv")!)
        plex.setValue("token", forHTTPHeaderField: "X-Plex-Token")
        #expect(TransportSecurity.allowsRedirect(URLRequest(url: URL(string: "http://plex.example:32400/other")!), original: plex))
        #expect(!TransportSecurity.allowsRedirect(URLRequest(url: URL(string: "http://elsewhere.example/x")!), original: plex))
        let plain = URLRequest(url: URL(string: "http://cdn.example/poster.jpg")!)
        #expect(TransportSecurity.allowsRedirect(URLRequest(url: URL(string: "http://other.example/x")!), original: plain))
        try TransportSecurity.validate(plain)
    }
}

/// Answers by URL path; `followUp` answers a path's second request.
private final class RoutedTransport: JellyfinTransport, @unchecked Sendable {
    private let routes: [String: Data]
    private let followUp: [String: Data]
    private let lock = NSLock()
    private var sent: [URLRequest] = []

    init(_ routes: [String: Data], followUp: [String: Data] = [:]) {
        self.routes = routes
        self.followUp = followUp
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        let body: Data? = lock.withLock {
            let seen = sent.contains { $0.url?.path == path }
            sent.append(request)
            return seen ? (followUp[path] ?? routes[path]) : routes[path]
        }
        let status = body == nil ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body ?? Data(), response)
    }
}
