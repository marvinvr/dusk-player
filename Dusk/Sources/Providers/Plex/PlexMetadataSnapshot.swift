import Foundation

/// Plex's offline metadata snapshot: the raw PMS response, stored bare (no
/// envelope) under SHA-256 of the PMS endpoint path. Those paths are the file
/// names every existing install already has on disk, so they are wire format.
struct PlexMetadataSnapshotFormat: MetadataSnapshotFormat {
    var kind: ProviderKind { .plex }

    func storageName(for key: MetadataSnapshotKey) -> String {
        switch key {
        case .details(let itemID): Self.metadataEndpoint(itemID)
        case .children(let itemID): Self.childrenEndpoint(itemID)
        }
    }

    /// The same details and children reads the catalog makes online
    /// (`getMediaDetailsPayload`, the catalog's children request), so a cached
    /// payload is what an online screen would have decoded.
    func fetchRequest(for key: MetadataSnapshotKey) -> MetadataSnapshotRequest {
        switch key {
        case .details(let itemID):
            MetadataSnapshotRequest(
                path: Self.metadataEndpoint(itemID),
                queryItems: [
                    URLQueryItem(name: "includeMarkers", value: "1"),
                    URLQueryItem(name: "includeGuids", value: "1"),
                ]
            )
        case .children(let itemID):
            MetadataSnapshotRequest(path: Self.childrenEndpoint(itemID), queryItems: nil)
        }
    }

    func details(from data: Data, serverID: String) throws -> [MediaDetails] {
        try Self.decode(PlexMediaDetailsDTO.self, from: data, serverID: serverID).map { PlexItemMapper.map($0, serverID: serverID) }
    }

    func seasons(from data: Data, serverID: String) throws -> [Season] {
        try Self.decode(PlexSeasonDTO.self, from: data, serverID: serverID).map { PlexItemMapper.map($0, serverID: serverID) }
    }

    func episodes(from data: Data, serverID: String) throws -> [Episode] {
        try Self.decode(PlexEpisodeDTO.self, from: data, serverID: serverID).map { PlexItemMapper.map($0, serverID: serverID) }
    }

    static func metadataEndpoint(_ itemID: String) -> String {
        "/library/metadata/\(itemID)"
    }

    static func childrenEndpoint(_ itemID: String) -> String {
        "/library/metadata/\(itemID)/children"
    }

    /// The server stays stamped on the decoder as well, exactly as the online
    /// decoder (`ServerPool.decoder(for:)`) does it.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, serverID: String) throws -> [T] {
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = serverID
        return try decoder.decode(MetadataResponse<T>.self, from: data).MediaContainer.Metadata ?? []
    }
}

extension PlexProviderFactory: MetadataSnapshotFormatProviding {
    var metadataSnapshotFormat: any MetadataSnapshotFormat { PlexMetadataSnapshotFormat() }
}

// MARK: - Source compatibility

// `MediaService+Library` (P0-07) and the persisted-data tests still name the
// cache by its old Plex name. Delete this section once they use
// `MetadataSnapshotCache` / `PlexMetadataSnapshotFormat`.

typealias PlexMetadataCache = MetadataSnapshotCache

extension MetadataSnapshotCache {
    /// A cache that reads and writes Plex payloads only.
    init(fileStore: DownloadFileStore) {
        self.init(fileStore: fileStore, formats: MetadataSnapshotFormats([PlexMetadataSnapshotFormat()]))
    }

    static func metadataEndpoint(_ itemID: String) -> String {
        PlexMetadataSnapshotFormat.metadataEndpoint(itemID)
    }

    static func childrenEndpoint(_ itemID: String) -> String {
        PlexMetadataSnapshotFormat.childrenEndpoint(itemID)
    }

    func mediaDetails(accountProfileID: String, serverID: String, itemID: String) -> MediaDetails? {
        mediaDetails(accountProfileID: accountProfileID, serverID: serverID, itemID: itemID, kind: .plex)
    }

    func seasons(accountProfileID: String, serverID: String, showKey: String) -> [Season]? {
        seasons(accountProfileID: accountProfileID, serverID: serverID, showKey: showKey, kind: .plex)
    }

    func episodes(accountProfileID: String, serverID: String, seasonKey: String) -> [Episode]? {
        episodes(accountProfileID: accountProfileID, serverID: serverID, seasonKey: seasonKey, kind: .plex)
    }
}
