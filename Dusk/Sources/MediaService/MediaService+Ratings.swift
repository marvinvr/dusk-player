import Foundation

extension MediaService {
    /// The user-rating facet of one server's provider; nil when the server
    /// has no ratings (every Plex server has them).
    func userRating(on serverID: String) -> (any UserRatingProviding)? {
        serverProvider(for: serverID).rating
    }

    /// Whether the title's server takes a user rating (Jellyfin has none,
    /// 04 §21 row 5). An unresolved server counts as one that does.
    func canRate(_ id: MediaItemID) -> Bool {
        guard let serverID = try? resolveServerID(id.serverID) else { return true }
        return userRating(on: serverID) != nil
    }

    /// Sets the signed-in user's rating of a title on a 0–10 scale (two per
    /// star), or clears it with nil.
    func setUserRating(_ rating: Int?, id: MediaItemID) async throws {
        guard let facet = userRating(on: try resolveServerID(id.serverID)) else {
            throw MediaServiceError.noServerConnected
        }
        try await facet.setRating(rating, itemID: id.itemID)
    }
}
