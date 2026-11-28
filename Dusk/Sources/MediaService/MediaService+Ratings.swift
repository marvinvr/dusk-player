import Foundation

extension MediaService {
    /// The user-rating facet of one server's provider; nil when the server
    /// has no ratings (every Plex server has them).
    func userRating(on serverID: String) -> (any UserRatingProviding)? {
        serverProvider(for: serverID).rating
    }

    /// Sets the signed-in user's rating of a title on a 0–10 scale (two per
    /// star), or clears it with nil.
    func setUserRating(_ rating: Int?, id: MediaItemID) async throws {
        guard let facet = userRating(on: try resolveServerID(id.serverID)) else {
            throw PlexServiceError.noServerConnected
        }
        try await facet.setRating(rating, itemID: id.itemID)
    }
}
