import Foundation

extension MediaService {
    /// The user-rating facet of one server. Built here rather than read off
    /// `session.provider` while routing still lives in the facade
    /// (`PlexCatalogTransport`).
    func userRating(on serverID: String) -> any UserRatingProviding {
        PlexUserRating(serverID: serverID, transport: self)
    }

    /// Sets the signed-in user's rating of a title on a 0–10 scale (two per
    /// star), or clears it with nil.
    func setUserRating(_ rating: Int?, id: MediaItemID) async throws {
        try await userRating(on: resolveServerID(id.serverID)).setRating(rating, itemID: id.itemID)
    }
}
