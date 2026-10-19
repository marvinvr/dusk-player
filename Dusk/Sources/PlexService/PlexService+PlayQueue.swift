import Foundation

extension PlexService {
    /// The pre-roll videos the server wants played before `ratingKey`, in
    /// order. Empty when the server has none configured.
    ///
    /// This is how official Plex clients get them: create a play queue for the
    /// movie with `extrasPrefixCount`, and the server puts its extras in front
    /// of the movie. The server decides what plays (Settings → Extras →
    /// "Cinema Trailer pre-roll video": a comma plays every file in order, a
    /// semicolon picks one at random); the client never reads that preference,
    /// which shared users could not read anyway.
    ///
    /// `extrasPrefixCount` is the number of cinema *trailers* in front of the
    /// pre-roll — in Plex a per-client setting, not a server one. Dusk has no
    /// such setting and sends 0 ("pre-roll only"): it plays exactly what the
    /// server owner set up, and a server without a pre-roll answers with the
    /// movie alone. Leaving the parameter out entirely returns no extras at all.
    func cinemaPrerolls(forMovieRatingKey ratingKey: String, serverID: String?) async throws -> [PlexMediaDetails] {
        let targetID = try resolveServerID(serverID)
        let data = try await rawServerRequest(
            method: "POST",
            path: "/playQueues",
            queryItems: [
                URLQueryItem(name: "type", value: "video"),
                URLQueryItem(
                    name: "uri",
                    value: "server://\(targetID)/com.plexapp.plugins.library/library/metadata/\(ratingKey)"
                ),
                URLQueryItem(name: "extrasPrefixCount", value: "0"),
                URLQueryItem(name: "repeat", value: "0"),
                URLQueryItem(name: "own", value: "1"),
            ],
            serverID: targetID
        )
        let items = try decodeJSON(MetadataResponse<PlexMediaDetails>.self, from: data, serverID: targetID)
            .MediaContainer.Metadata ?? []
        return Self.prerollItems(in: items, featureRatingKey: ratingKey)
    }

    /// Everything the queue puts in front of the movie. Only clips count: a
    /// queue that somehow led with anything else is not a pre-roll queue.
    static func prerollItems(in queue: [PlexMediaDetails], featureRatingKey: String) -> [PlexMediaDetails] {
        guard let featureIndex = queue.firstIndex(where: { $0.ratingKey == featureRatingKey }) else {
            return []
        }
        return queue[..<featureIndex].filter { $0.type == .clip && !$0.media.isEmpty }
    }
}
