import Foundation

struct PlexMetadataCache: Sendable {
    let fileStore: DownloadFileStore

    func storePayload(
        _ data: Data,
        accountProfileID: String,
        serverID: String,
        endpoint: String
    ) throws {
        try fileStore.prepareRootDirectory()
        let url = fileStore.metadataURL(
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: endpoint
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    func payload(accountProfileID: String, serverID: String, endpoint: String) -> Data? {
        try? Data(contentsOf: fileStore.metadataURL(
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: endpoint
        ))
    }

    func mediaDetails(accountProfileID: String, serverID: String, itemID: String) -> MediaDetails? {
        guard let data = payload(
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: Self.metadataEndpoint(itemID)
        ) else {
            return nil
        }
        return Self.decodeMetadata(MediaDetails.self, from: data, serverID: serverID).first
    }

    func seasons(accountProfileID: String, serverID: String, showKey: String) -> [Season]? {
        guard let data = payload(
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: Self.childrenEndpoint(showKey)
        ) else {
            return nil
        }
        return Self.decodeMetadata(Season.self, from: data, serverID: serverID)
    }

    func episodes(accountProfileID: String, serverID: String, seasonKey: String) -> [Episode]? {
        guard let data = payload(
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: Self.childrenEndpoint(seasonKey)
        ) else {
            return nil
        }
        return Self.decodeMetadata(Episode.self, from: data, serverID: serverID)
    }

    func firstCachedMediaDetails(
        accountProfileID: String,
        itemID: String,
        serverIDs: [String]
    ) -> MediaDetails? {
        for serverID in serverIDs {
            if let details = mediaDetails(
                accountProfileID: accountProfileID,
                serverID: serverID,
                itemID: itemID
            ) {
                return details
            }
        }
        return nil
    }

    func firstCachedSeasons(
        accountProfileID: String,
        showKey: String,
        serverIDs: [String]
    ) -> [Season]? {
        for serverID in serverIDs {
            if let seasons = seasons(
                accountProfileID: accountProfileID,
                serverID: serverID,
                showKey: showKey
            ) {
                return seasons
            }
        }
        return nil
    }

    func firstCachedEpisodes(
        accountProfileID: String,
        seasonKey: String,
        serverIDs: [String]
    ) -> [Episode]? {
        for serverID in serverIDs {
            if let episodes = episodes(
                accountProfileID: accountProfileID,
                serverID: serverID,
                seasonKey: seasonKey
            ) {
                return episodes
            }
        }
        return nil
    }

    static func metadataEndpoint(_ itemID: String) -> String {
        "/library/metadata/\(itemID)"
    }

    static func childrenEndpoint(_ itemID: String) -> String {
        "/library/metadata/\(itemID)/children"
    }

    /// Stamps the server onto the decoder so cached models carry the same
    /// server-scoped identity they would have had when fetched online.
    private static func decodeMetadata<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        serverID: String
    ) -> [T] {
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = serverID
        return (try? decoder.decode(MetadataResponse<T>.self, from: data).MediaContainer.Metadata) ?? []
    }
}
