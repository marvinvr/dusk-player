import Foundation

/// Cinema pre-rolls on Jellyfin (02 §10, 04 §12.7): what the server's intros
/// plugin puts in front of a film, `GET /Items/{id}/Intros`. A server without
/// such a plugin answers `{Items: []}`, the normal case.
///
/// The intros answer carries media sources without probed streams, so each
/// intro is read again as a full item (`/Items/{id}`): the engine pick needs
/// its codecs. An intro that cannot be read is left out; the film never waits
/// on a broken one.
enum JellyfinPrerolls {
    @MainActor
    static func load(before itemID: String, server: JellyfinServerProvider) async throws -> [MediaDetails] {
        let client = try server.client()
        let serverID = server.descriptor.id
        let intros = try await client.send(JellyfinAPI.intros(itemID: itemID)).items
            .filter { !JellyfinID.same($0.id, itemID) }
        guard !intros.isEmpty else { return [] }

        // One after the other: a plugin returns one or two.
        var loaded: [MediaDetails] = []
        for intro in intros {
            guard let item = try? await client.send(JellyfinAPI.item(id: intro.id)) else { continue }
            let details = JellyfinItemMapper.mapDetails(item, serverID: serverID, markers: [])
            if !details.media.isEmpty { loaded.append(details) }
        }
        return loaded
    }
}
