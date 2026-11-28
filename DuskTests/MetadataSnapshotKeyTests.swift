import Foundation
import Testing
@testable import Dusk

/// P0-15 risk register ("existing downloads disappear"): a `MetadataSnapshotKey`
/// must name the same cache file the pre-refactor build wrote. The hashes are
/// the literals `PersistedGoldenStringTests.metadataCacheFileNames` pins
/// (computed on the host with `printf %s '<input>' | shasum -a 256`).
@Suite("Metadata snapshot keys")
struct MetadataSnapshotKeyTests {
    private let profile = "4f2a9c1d7e3b5a60"
    private let server = "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9"

    @Test func plexStorageNamesAreTheEndpointPaths() {
        let format = PlexMetadataSnapshotFormat()
        #expect(format.storageName(for: .details(itemID: "1001")) == "/library/metadata/1001")
        #expect(format.storageName(for: .children(itemID: "2010")) == "/library/metadata/2010/children")
        #expect(DownloadFileStore.hash(format.storageName(for: .details(itemID: "1001")))
            == "763c91a41ab63b9ef1c896ef1ba98e74bfa00f41e8b707861698dbddb117df34")
        #expect(DownloadFileStore.hash(format.storageName(for: .children(itemID: "2010")))
            == "b484084a00b1917dc534fbcdfc156b65b7a3256f71dd8c3e9bd61db291688b24")
    }

    @Test func plexFetchRequestsMatchTheCatalogReads() {
        let format = PlexMetadataSnapshotFormat()
        let details = format.fetchRequest(for: .details(itemID: "1001"))
        #expect(details.path == "/library/metadata/1001")
        #expect(details.queryItems == [
            URLQueryItem(name: "includeMarkers", value: "1"),
            URLQueryItem(name: "includeGuids", value: "1"),
        ])
        let children = format.fetchRequest(for: .children(itemID: "2010"))
        #expect(children.path == "/library/metadata/2010/children")
        #expect(children.queryItems == nil)
    }

    @Test func storedSnapshotLandsAtTheLegacyFileName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadFileStore(rootDirectory: root)
        let cache = MetadataSnapshotCache(fileStore: store, formats: MetadataSnapshotFormats([PlexMetadataSnapshotFormat()]))
        try cache.storePayload(Data("{}".utf8), for: .details(itemID: "1001"), accountProfileID: profile, serverID: server, kind: .plex)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "Metadata/Profiles/\(profile)/\(server)/763c91a41ab63b9ef1c896ef1ba98e74bfa00f41e8b707861698dbddb117df34.json"
        ).path))
        // A provider this build has no format for reads nothing and writes nothing.
        #expect(cache.payload(for: .details(itemID: "1001"), accountProfileID: profile, serverID: server, kind: .jellyfin) == nil)
        #expect(throws: MetadataSnapshotCacheError.self) {
            try cache.storePayload(Data("{}".utf8), for: .details(itemID: "1001"), accountProfileID: profile, serverID: server, kind: .jellyfin)
        }
    }

    @Test func plexRecordsCarryNoProviderTag() throws {
        let data = Data(#"{"serverID":"server-a","ratingKey":"42","type":"movie","title":"Example","status":"completed","progress":1,"downloadedBytes":1234,"addedAt":0,"updatedAt":1}"#.utf8)
        let record = try JSONDecoder().decode(DownloadedMediaRecord.self, from: data)
        #expect(record.provider == nil)
        #expect(record.providerKind == .plex)
        #expect(DownloadedMediaRecord.providerTag(for: .plex) == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(encoded["provider"] == nil)

        var tagged = record
        tagged.provider = DownloadedMediaRecord.providerTag(for: .jellyfin)
        let restored = try JSONDecoder().decode(DownloadedMediaRecord.self, from: JSONEncoder().encode(tagged))
        #expect(restored.providerKind == .jellyfin)
    }

    @Test func plexQueueItemsMapToJobsByRatingKey() throws {
        let raw = try #require(JSONSerialization.jsonObject(with: Data(
            #"{"id":"23","queueId":"7","key":"/library/metadata/42","status":"available"}"#.utf8
        )) as? [String: Any])
        let job = try PlexDownloadQueueResponse.item(raw, queueID: "7").job
        #expect(job.id == "23")
        #expect(job.queueID == "7")
        #expect(job.itemID == "42")
        #expect(job.state == .ready)
        #expect(job.progress == 1)
    }
}
