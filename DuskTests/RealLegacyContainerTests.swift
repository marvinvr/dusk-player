import Foundation
import Testing
@testable import Dusk

/// G4 against a container captured from a real install of the baseline build:
/// the Debug app in screenshot mode against `scripts/mock_large_plex.py`,
/// with one movie and one season seeded as finished downloads. See
/// `Fixtures/LegacyContainer/LegacyContainer-README.md` for how it was produced.
///
/// The test rebuilds that container in a temporary directory at the paths the
/// app wrote (`LegacyContainer-real-manifest.json`) and reads it back through
/// `DownloadFileStore` and `PlexMetadataCache`, the way an updated build finds
/// it on first launch.
@Suite("Legacy container: captured install", .serialized)
@MainActor
struct RealLegacyContainerTests {
    private static let profile = "bigplexuser"
    private static let server = "bigplexserver000000000000000000000000001"

    private struct Manifest: Decodable {
        let metadata: [String: String]
        let artwork: [String]
        let videos: [String]
        let defaults: [String: DefaultsValue]
    }

    private enum DefaultsValue: Decodable, Equatable {
        case string(String)
        case bool(Bool)
        case serverIDs([String: [String]])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                self = .serverIDs(try container.decode([String: [String]].self))
            }
        }
    }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: LegacyFixture.data("LegacyContainer-real-manifest.json"))
    }

    /// The captured `Library/Application Support/Dusk/Downloads` tree, minus
    /// artwork bytes and the (sparse, multi-GB) placeholder videos.
    private func withCapturedRoot(_ body: (URL, Manifest) throws -> Void) throws {
        let manifest = try manifest()
        try LegacyFixture.withTemporaryRoot { root in
            try LegacyFixture.place(try LegacyFixture.data("LegacyContainer-real-downloads.json"), at: "downloads.json", under: root)
            for (relativePath, fixture) in manifest.metadata {
                try LegacyFixture.place(try LegacyFixture.data(fixture), at: relativePath, under: root)
            }
            try body(root, manifest)
        }
    }

    @Test func capturedDownloadsDecode() throws {
        try withCapturedRoot { root, _ in
            let snapshot = DownloadFileStore(rootDirectory: root).loadSnapshot()
            try #require(snapshot.records.count == 5)
            #expect(snapshot.pendingQueueRemovals?.isEmpty == true)
            #expect(snapshot.smartDownloadRules == nil)

            let movie = snapshot.records[0]
            #expect(movie.accountProfileID == "bigplexuser")
            #expect(movie.serverID == "bigplexserver000000000000000000000000001")
            #expect(movie.serverName == "Big NAS")
            #expect(movie.ratingKey == "1004")
            #expect(movie.type == .movie)
            #expect(movie.isClip == false)
            #expect(movie.title == "Winter Stone")
            #expect(movie.subtitle == "1977")
            #expect(movie.thumbPath == "/library/metadata/1004/thumb/1795812082")
            #expect(movie.artPath == "/library/metadata/1004/art/1795812082")
            #expect(movie.mediaID == 1004)
            #expect(movie.partID == 1004)
            #expect(movie.downloadQuality == .original)
            #expect(movie.relativeVideoPath == "Profiles/bigplexuser/Movies/Winter Stone (1977)/Winter Stone (1977).mp4")
            #expect(movie.externalSubtitlePaths == nil)
            #expect(movie.status == .completed)
            #expect(movie.progress == 1)
            #expect(movie.downloadedBytes == 4_000_000_000)
            #expect(movie.totalBytes == 4_000_000_000)
            #expect(movie.addedAt == Date(timeIntervalSinceReferenceDate: 817_504_891.742967))
            #expect(movie.updatedAt == Date(timeIntervalSinceReferenceDate: 817_504_891.742967))
            #expect(movie.globalKey == "bigplexuser:bigplexserver000000000000000000000000001:1004")

            let episodes = Array(snapshot.records.dropFirst())
            #expect(episodes.map(\.ratingKey) == ["750002", "750003", "750004", "750005"])
            #expect(episodes.map(\.title) == ["Episode 1", "Episode 2", "Episode 3", "Episode 4"])
            #expect(episodes.map(\.subtitle) == [
                "Season 1 · Episode 1", "Season 1 · Episode 2", "Season 1 · Episode 3", "Season 1 · Episode 4",
            ])
            #expect(episodes.map(\.mediaID) == [750002, 750003, 750004, 750005])
            #expect(episodes.map(\.partID) == [750002, 750003, 750004, 750005])
            #expect(episodes.map(\.relativeVideoPath) == [
                "Profiles/bigplexuser/TV Shows/Harbor Final/Season 01/S01E01 - Episode 1.mp4",
                "Profiles/bigplexuser/TV Shows/Harbor Final/Season 01/S01E02 - Episode 2.mp4",
                "Profiles/bigplexuser/TV Shows/Harbor Final/Season 01/S01E03 - Episode 3.mp4",
                "Profiles/bigplexuser/TV Shows/Harbor Final/Season 01/S01E04 - Episode 4.mp4",
            ])
            for episode in episodes {
                #expect(episode.accountProfileID == "bigplexuser")
                #expect(episode.serverID == "bigplexserver000000000000000000000000001")
                #expect(episode.type == .episode)
                #expect(episode.parentRatingKey == "750001")
                #expect(episode.parentTitle == nil)
                #expect(episode.grandparentRatingKey == "1201")
                #expect(episode.grandparentTitle == "Harbor Final")
                #expect(episode.thumbPath == "/library/metadata/\(episode.ratingKey)/thumb/1795812082")
                #expect(episode.artPath == nil)
                #expect(episode.status == .completed)
                #expect(episode.downloadedBytes == 1_000_000_000)
                #expect(episode.globalKey == "bigplexuser:bigplexserver000000000000000000000000001:\(episode.ratingKey)")
            }
        }
    }

    @Test func capturedDownloadsReEncode() throws {
        try withCapturedRoot { root, _ in
            let fixture = try LegacyFixture.data("LegacyContainer-real-downloads.json")
            let store = DownloadFileStore(rootDirectory: root)
            let snapshot = store.loadSnapshot()
            try #require(snapshot.records.count == 5)
            try store.saveSnapshot(snapshot)
            try LegacyFixture.expectSameJSON(try Data(contentsOf: root.appendingPathComponent("downloads.json")), fixture)
        }
    }

    @Test func capturedMetadataCacheFilesAreFoundAndDecode() throws {
        try withCapturedRoot { root, manifest in
            #expect(manifest.metadata.count == 9)
            let cache = PlexMetadataCache(fileStore: DownloadFileStore(rootDirectory: root))

            let movie = try #require(cache.mediaDetails(accountProfileID: Self.profile, serverID: Self.server, ratingKey: "1004"))
            #expect(movie.serverID == "bigplexserver000000000000000000000000001")
            #expect(movie.id.storageKey == "bigplexserver000000000000000000000000001|1004")
            #expect(movie.type == .movie)
            #expect(movie.title == "Winter Stone")
            #expect(movie.year == 1977)
            #expect(movie.thumb == "/library/metadata/1004/thumb/1795812082")
            try #require(movie.media.count == 1)
            #expect(movie.media[0].id == 1004)
            #expect(movie.media[0].parts.map(\.id) == [1004])
            #expect(movie.media[0].parts[0].key == "/library/parts/1004/1/file.mp4")
            #expect(movie.media[0].parts[0].size == 4_000_000_000)

            let show = try #require(cache.mediaDetails(accountProfileID: Self.profile, serverID: Self.server, ratingKey: "1201"))
            #expect(show.type == .show)
            #expect(show.title == "Harbor Final")

            let season = try #require(cache.mediaDetails(accountProfileID: Self.profile, serverID: Self.server, ratingKey: "750001"))
            #expect(season.type == .season)
            #expect(season.title == "Season 1")

            let seasons = try #require(cache.seasons(accountProfileID: Self.profile, serverID: Self.server, showKey: "1201"))
            #expect(seasons.map(\.ratingKey) == ["750001", "750006"])
            #expect(seasons.map(\.title) == ["Season 1", "Season 2"])
            #expect(seasons.map(\.index) == [1, 2])

            let episodes = try #require(cache.episodes(accountProfileID: Self.profile, serverID: Self.server, seasonKey: "750001"))
            #expect(episodes.map(\.ratingKey) == ["750002", "750003", "750004", "750005"])
            #expect(episodes.map(\.title) == ["Episode 1", "Episode 2", "Episode 3", "Episode 4"])

            for ratingKey in ["750002", "750003", "750004", "750005"] {
                let episode = try #require(cache.mediaDetails(accountProfileID: Self.profile, serverID: Self.server, ratingKey: ratingKey))
                #expect(episode.type == .episode)
                #expect(episode.grandparentRatingKey == "1201")
                #expect(episode.parentRatingKey == "750001")
                #expect(episode.media.first?.parts.first?.id == Int(ratingKey))
            }

            // Same profile, other server: nothing; other profile: nothing.
            #expect(cache.mediaDetails(accountProfileID: Self.profile, serverID: "other", ratingKey: "1004") == nil)
            #expect(cache.mediaDetails(accountProfileID: "plex-home-1", serverID: Self.server, ratingKey: "1004") == nil)
        }
    }

    /// The file names the baseline build chose are what today's code derives.
    @Test func capturedPathsMatchTheirDerivation() throws {
        try withCapturedRoot { root, manifest in
            let store = DownloadFileStore(rootDirectory: root)
            let expectedMetadata = Set([
                "/library/metadata/1004", "/library/metadata/1201", "/library/metadata/1201/children",
                "/library/metadata/750001", "/library/metadata/750001/children", "/library/metadata/750002",
                "/library/metadata/750003", "/library/metadata/750004", "/library/metadata/750005",
            ].map { store.relativePath(for: store.metadataURL(accountProfileID: Self.profile, serverID: Self.server, endpoint: $0)) })
            #expect(Set(manifest.metadata.keys) == expectedMetadata)
            #expect(manifest.metadata.keys.contains(
                "Metadata/Profiles/bigplexuser/bigplexserver000000000000000000000000001/a3d2fd1255dd164fe3a146fd6cabed9c4f5c911cf83d7a41d5f4b157240d2011.json"
            ))

            let artworkPaths = [
                "/library/metadata/1004/thumb/1795812082", "/library/metadata/1004/art/1795812082",
                "/library/metadata/750002/thumb/1795812082", "/library/metadata/750003/thumb/1795812082",
                "/library/metadata/750004/thumb/1795812082", "/library/metadata/750005/thumb/1795812082",
                "/library/metadata/1201/thumb/1795812082", "/library/metadata/1201/art/1795812082",
            ]
            #expect(Set(artworkPaths.compactMap { store.artworkURL(for: $0)?.lastPathComponent }) == Set(manifest.artwork))
            #expect(store.artworkURL(for: "/library/metadata/1004/thumb/1795812082")?.lastPathComponent
                == "285545de12c00c41703b4ef478f798b78e90ca241b34b4b5c2d636497a5cf0ff.jpg")

            let records = store.loadSnapshot().records
            #expect(records.compactMap(\.relativeVideoPath).sorted() == manifest.videos)

            // The video file name is derived from the cached metadata.
            let cache = PlexMetadataCache(fileStore: store)
            for record in records {
                let details = try #require(cache.mediaDetails(
                    accountProfileID: Self.profile, serverID: Self.server, ratingKey: record.ratingKey
                ))
                let part = try #require(details.media.first?.parts.first)
                let url = try store.targetVideoURL(accountProfileID: Self.profile, for: details, part: part)
                #expect(store.relativePath(for: url) == record.relativeVideoPath)
            }
        }
    }

    /// The defaults keys the baseline build wrote, with their literal names.
    @Test func capturedDefaultsKeys() throws {
        let manifest = try manifest()
        #expect(manifest.defaults == [
            "HomeContinueWatchingServerIDs": .serverIDs(["bigplexuser": ["bigplexserver000000000000000000000000001"]]),
            "PlexAutomaticallySignInHomeUser": .bool(true),
            "PlexHomeMigrationCompleted": .bool(true),
            "PlexLastGoodConnectionURI.bigplexserver000000000000000000000000001": .string("http://127.0.0.1:47721"),
            "PlexPrimaryProfileID": .string("bigplexuser"),
            "PlexServerURL.bigplexserver000000000000000000000000001": .string("http://127.0.0.1:47721"),
        ])
        #expect(ServerPool.lastGoodConnectionKey(serverID: Self.server)
            == "PlexLastGoodConnectionURI.bigplexserver000000000000000000000000001")
        #expect(ServerPool.baseURLKey(serverID: Self.server) == "PlexServerURL.bigplexserver000000000000000000000000001")
    }

    @Test func capturedServerPriorityAndSnapshotsDecode() throws {
        let priority = try LegacyFixture.data("LegacyContainer-real-PlexServerPriority.json")
        try LegacyFixture.withScratchDefaults { defaults in
            defaults.set(priority, forKey: "PlexServerPriority")
            #expect(ServerPriorityStore(defaults: defaults).entries == [
                ServerPriorityStore.Entry(machineIdentifier: "bigplexserver000000000000000000000000001", isEnabled: true),
            ])
        }

        let snapshots = try LegacyFixture.data("LegacyContainer-real-PlexServerSnapshots.json")
        let servers = LegacyFixture.withStandardDefault("PlexServerSnapshots", set: snapshots) {
            ServerPool.storedSnapshots()
        }
        try #require(servers.count == 1)
        #expect(servers[0].name == "Big NAS")
        #expect(servers[0].clientIdentifier == "bigplexserver000000000000000000000000001")
        #expect(servers[0].product == "Plex Media Server")
        #expect(servers[0].productVersion == "1.42.1.10060")
        #expect(servers[0].owned == true)
        #expect(servers[0].accessToken == nil)
        #expect(servers[0].connections == [PlexConnection(
            protocol: "http", address: "127.0.0.1", port: 47721, uri: "http://127.0.0.1:47721",
            local: true, relay: false, iPv6: false
        )])
        try LegacyFixture.expectSameJSON(try JSONEncoder().encode(servers.map(\.withoutAccessToken)), snapshots)
    }

    @Test func capturedActiveHomeUserDecodes() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-real-PlexActiveHomeUserData.json")
        let user = try JSONDecoder().decode(PlexHomeUser.self, from: fixture)
        #expect(user.id == 1)
        #expect(user.uuid == "bigplexuser")
        #expect(user.username == "bigplex")
        #expect(user.friendlyName == "Big Plex")
        #expect(user.isAdmin == true)
        #expect(user.stableProfileID == "bigplexuser")
        try LegacyFixture.expectSameJSON(try JSONEncoder().encode(user), fixture)
    }

    /// `SiriTitleCatalog.Stored` is private, so its envelope is mirrored here
    /// with the literal keys; the entries are today's `SiriCatalogEntry`.
    private struct SiriCatalogEnvelope: Codable {
        let profileID: String
        let refreshedAt: Date
        let entries: [SiriCatalogEntry]
        let hiddenLibraryIDs: Set<String>?
    }

    @Test func capturedSiriCatalogDecodes() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-real-siriTitleCatalog.json")
        let catalog = try JSONDecoder().decode(SiriCatalogEnvelope.self, from: fixture)
        #expect(catalog.profileID == "bigplexuser")
        #expect(catalog.refreshedAt == Date(timeIntervalSinceReferenceDate: 817_504_896.470797))
        #expect(catalog.hiddenLibraryIDs == [])
        #expect(catalog.entries.count == 184)
        #expect(catalog.entries.filter { $0.kind == .movie }.count == 96)
        #expect(catalog.entries.first == SiriCatalogEntry(
            id: PlexItemID(serverID: "bigplexserver000000000000000000000000001", ratingKey: "1281"),
            kind: .show, title: "River Golden 80", year: 2010, lastViewedAt: 1_795_809_247
        ))
        #expect(catalog.entries.last == SiriCatalogEntry(
            id: PlexItemID(serverID: "bigplexserver000000000000000000000000001", ratingKey: "1298"),
            kind: .show, title: "Secret Northern 0", year: 1998, lastViewedAt: nil
        ))
        #expect(catalog.entries.allSatisfy { $0.id.serverID == "bigplexserver000000000000000000000000001" })
        #expect(PlexTitleEntity(catalog.entries[0]).id == "bigplexserver000000000000000000000000001|1281")
        try LegacyFixture.expectSameJSON(try JSONEncoder().encode(catalog), fixture)
    }
}
