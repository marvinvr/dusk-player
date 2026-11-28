import Foundation

/// Plex's `UserRatingProviding`: `PUT /:/rate`, on Plex's 0–10 scale.
///
/// Every request goes to `serverID` through `transport` (`PlexServerTransport`).
struct PlexUserRating: UserRatingProviding {
    let serverID: String
    /// nil on the value `PlexServerProvider.rating` hands out, which then
    /// throws `noServerConnected`.
    let transport: (any PlexServerTransport)?

    /// `rating=-1` clears it.
    func setRating(_ rating: Int?, itemID: String) async throws {
        guard let transport else { throw MediaServiceError.noServerConnected }
        _ = try await transport.rawServerRequest(
            method: "PUT",
            path: "/:/rate",
            queryItems: [
                URLQueryItem(name: "key", value: itemID),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "rating", value: String(rating ?? -1)),
            ],
            timeoutInterval: nil,
            serverID: serverID
        )
    }
}

extension PlexServerProvider {
    /// Sends through the account's routed send (`PlexServerRouter`).
    var rating: (any UserRatingProviding)? { PlexUserRating(serverID: descriptor.id, transport: router) }
}
