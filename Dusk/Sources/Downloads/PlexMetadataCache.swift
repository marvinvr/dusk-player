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

    func mediaDetails(accountProfileID: String, serverID: String, ratingKey: String) -> PlexMediaDetails? {
        guard let data = payload(
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: Self.metadataEndpoint(ratingKey)
        ) else {
            return nil
        }
        return Self.decodeMetadata(PlexMediaDetails.self, from: data).first
    }

    func seasons(accountProfileID: String, serverID: String, showKey: String) -> [PlexSeason]? {
        guard let data = payload(
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: Self.childrenEndpoint(showKey)
        ) else {
            return nil
        }
        return Self.decodeMetadata(PlexSeason.self, from: data)
    }

    func episodes(accountProfileID: String, serverID: String, seasonKey: String) -> [PlexEpisode]? {
        guard let data = payload(
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: Self.childrenEndpoint(seasonKey)
        ) else {
            return nil
        }
        return Self.decodeMetadata(PlexEpisode.self, from: data)
    }

    func firstCachedMediaDetails(
        accountProfileID: String,
        ratingKey: String,
        serverIDs: [String]
    ) -> PlexMediaDetails? {
        for serverID in serverIDs {
            if let details = mediaDetails(
                accountProfileID: accountProfileID,
                serverID: serverID,
                ratingKey: ratingKey
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
    ) -> [PlexSeason]? {
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
    ) -> [PlexEpisode]? {
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

    static func metadataEndpoint(_ ratingKey: String) -> String {
        "/library/metadata/\(ratingKey)"
    }

    static func childrenEndpoint(_ ratingKey: String) -> String {
        "/library/metadata/\(ratingKey)/children"
    }

    private static func decodeMetadata<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        (try? JSONDecoder().decode(MetadataResponse<T>.self, from: data).MediaContainer.Metadata) ?? []
    }
}
