import Foundation

struct PlexMetadataCache: Sendable {
    let fileStore: DownloadFileStore

    func storePayload(_ data: Data, serverID: String, endpoint: String) throws {
        try fileStore.prepareRootDirectory()
        let url = fileStore.metadataURL(serverID: serverID, endpoint: endpoint)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    func payload(serverID: String, endpoint: String) -> Data? {
        try? Data(contentsOf: fileStore.metadataURL(serverID: serverID, endpoint: endpoint))
    }

    func mediaDetails(serverID: String, ratingKey: String) -> PlexMediaDetails? {
        guard let data = payload(serverID: serverID, endpoint: Self.metadataEndpoint(ratingKey)) else { return nil }
        return Self.decodeMetadata(PlexMediaDetails.self, from: data).first
    }

    func seasons(serverID: String, showKey: String) -> [PlexSeason]? {
        guard let data = payload(serverID: serverID, endpoint: Self.childrenEndpoint(showKey)) else { return nil }
        return Self.decodeMetadata(PlexSeason.self, from: data)
    }

    func episodes(serverID: String, seasonKey: String) -> [PlexEpisode]? {
        guard let data = payload(serverID: serverID, endpoint: Self.childrenEndpoint(seasonKey)) else { return nil }
        return Self.decodeMetadata(PlexEpisode.self, from: data)
    }

    func firstCachedMediaDetails(ratingKey: String, serverIDs: [String]) -> PlexMediaDetails? {
        for serverID in serverIDs {
            if let details = mediaDetails(serverID: serverID, ratingKey: ratingKey) {
                return details
            }
        }
        return nil
    }

    func firstCachedSeasons(showKey: String, serverIDs: [String]) -> [PlexSeason]? {
        for serverID in serverIDs {
            if let seasons = seasons(serverID: serverID, showKey: showKey) {
                return seasons
            }
        }
        return nil
    }

    func firstCachedEpisodes(seasonKey: String, serverIDs: [String]) -> [PlexEpisode]? {
        for serverID in serverIDs {
            if let episodes = episodes(serverID: serverID, seasonKey: seasonKey) {
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
