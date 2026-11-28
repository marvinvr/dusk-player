import Foundation

extension MediaService {
    /// The extras of a movie, show, season, or episode: local trailers,
    /// featurettes, deleted scenes, …, each a playable clip. They belong to
    /// that server's copy of the title, so they are never merged across
    /// servers. A route to the server's catalog facet.
    func getExtras(itemID: String, serverID: String? = nil) async throws -> [Extra] {
        try await catalog(on: resolveServerID(serverID)).extras(itemID: itemID)
    }
}
