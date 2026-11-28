import Foundation

/// One item's details as the player needs them: `GET /Items/{id}?userId=`
/// with its skip markers from `/MediaSegments/{id}`, fetched in parallel
/// (04 §12.6). The player builds its markers from `MediaDetails.markers`
/// where no service is reachable, so they travel on the details.
///
/// A segments failure means no skip buttons, never a failed load.
enum JellyfinItemDetails {
    static func load(itemID: String, serverID: String?, client: JellyfinClient) async throws -> MediaDetails {
        async let markers = markers(itemID: itemID, client: client)
        let item = try await client.send(JellyfinAPI.item(id: itemID))
        return JellyfinItemMapper.mapDetails(item, serverID: serverID, markers: await markers)
    }

    /// Every segment type is mapped; the player shows only intro and credits.
    static func markers(itemID: String, client: JellyfinClient) async -> [Marker] {
        guard let segments = try? await client.send(JellyfinAPI.mediaSegments(itemID: itemID)) else { return [] }
        return JellyfinMediaMapper.markers(segments.items)
    }
}
