import Foundation

extension PlexService {
    /// The extras of a movie, show, season, or episode: local trailers,
    /// featurettes, deleted scenes, … (Plex's "Local Files for Trailers and
    /// Extras"), each a playable clip. They belong to that server's copy of the
    /// title, so they are never merged across servers.
    func getExtras(itemID: String, serverID: String? = nil) async throws -> [Extra] {
        let targetID = try resolveServerID(serverID)
        let data = try await rawServerRequest(
            path: "/library/metadata/\(itemID)/extras",
            serverID: targetID
        )
        let items = try decodeJSON(MetadataResponse<MediaItem>.self, from: data, serverID: targetID)
            .MediaContainer.Metadata ?? []
        let fields = (try? decodeJSON(MetadataResponse<PlexExtraFieldsDTO>.self, from: data, serverID: targetID))?
            .MediaContainer.Metadata ?? []
        return PlexUserContentMapper.extras(items: items, fields: fields)
    }
}
