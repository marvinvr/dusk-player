import Foundation

/// The offline metadata of downloaded items: raw provider payloads under
/// `Metadata/[Profiles/{profile}/]{serverID}/{hash}.json`, where the hash is
/// SHA-256 of the provider's `storageName(for:)` (for Plex, today's PMS
/// endpoint path, so existing files keep being found). Decoding goes through
/// the format of the provider kind that wrote the payload; no session needed.
struct MetadataSnapshotCache: Sendable {
    let fileStore: DownloadFileStore
    let formats: MetadataSnapshotFormats

    init(fileStore: DownloadFileStore, formats: MetadataSnapshotFormats) {
        self.fileStore = fileStore
        self.formats = formats
    }

    func storePayload(
        _ data: Data,
        for key: MetadataSnapshotKey,
        accountProfileID: String,
        serverID: String,
        kind: ProviderKind
    ) throws {
        guard let format = formats.format(for: kind) else {
            throw MetadataSnapshotCacheError.unsupportedProvider
        }
        try fileStore.prepareRootDirectory()
        let url = fileStore.metadataURL(
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: format.storageName(for: key)
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    func payload(
        for key: MetadataSnapshotKey,
        accountProfileID: String,
        serverID: String,
        kind: ProviderKind
    ) -> Data? {
        guard let format = formats.format(for: kind) else { return nil }
        return try? Data(contentsOf: fileStore.metadataURL(
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: format.storageName(for: key)
        ))
    }

    func mediaDetails(accountProfileID: String, serverID: String, itemID: String, kind: ProviderKind) -> MediaDetails? {
        guard let format = formats.format(for: kind),
              let data = payload(for: .details(itemID: itemID), accountProfileID: accountProfileID, serverID: serverID, kind: kind) else {
            return nil
        }
        return (try? format.details(from: data, serverID: serverID))?.first
    }

    func seasons(accountProfileID: String, serverID: String, showKey: String, kind: ProviderKind) -> [Season]? {
        guard let format = formats.format(for: kind),
              let data = payload(for: .children(itemID: showKey), accountProfileID: accountProfileID, serverID: serverID, kind: kind) else {
            return nil
        }
        return (try? format.seasons(from: data, serverID: serverID)) ?? []
    }

    func episodes(accountProfileID: String, serverID: String, seasonKey: String, kind: ProviderKind) -> [Episode]? {
        guard let format = formats.format(for: kind),
              let data = payload(for: .children(itemID: seasonKey), accountProfileID: accountProfileID, serverID: serverID, kind: kind) else {
            return nil
        }
        return (try? format.episodes(from: data, serverID: serverID)) ?? []
    }

    /// `kind` answers which provider runs each candidate server.
    func firstCachedMediaDetails(
        accountProfileID: String,
        itemID: String,
        serverIDs: [String],
        kind: (String) -> ProviderKind
    ) -> MediaDetails? {
        for serverID in serverIDs {
            if let details = mediaDetails(
                accountProfileID: accountProfileID,
                serverID: serverID,
                itemID: itemID,
                kind: kind(serverID)
            ) {
                return details
            }
        }
        return nil
    }

    func firstCachedSeasons(
        accountProfileID: String,
        showKey: String,
        serverIDs: [String],
        kind: (String) -> ProviderKind
    ) -> [Season]? {
        for serverID in serverIDs {
            if let seasons = seasons(
                accountProfileID: accountProfileID,
                serverID: serverID,
                showKey: showKey,
                kind: kind(serverID)
            ) {
                return seasons
            }
        }
        return nil
    }

    func firstCachedEpisodes(
        accountProfileID: String,
        seasonKey: String,
        serverIDs: [String],
        kind: (String) -> ProviderKind
    ) -> [Episode]? {
        for serverID in serverIDs {
            if let episodes = episodes(
                accountProfileID: accountProfileID,
                serverID: serverID,
                seasonKey: seasonKey,
                kind: kind(serverID)
            ) {
                return episodes
            }
        }
        return nil
    }
}

enum MetadataSnapshotCacheError: Error {
    /// No snapshot format for the server's provider in this build.
    case unsupportedProvider
}
