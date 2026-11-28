import Foundation

extension PlexService {
    /// Sets the signed-in user's rating of a title on Plex's 0–10 scale (two
    /// per star), or clears it with nil (`PUT /:/rate`, `rating=-1`).
    func setUserRating(_ rating: Int?, id: MediaItemID) async throws {
        _ = try await rawServerRequest(
            method: "PUT",
            path: "/:/rate",
            queryItems: [
                URLQueryItem(name: "key", value: id.itemID),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "rating", value: String(rating ?? -1)),
            ],
            serverID: id.serverID
        )
    }
}
