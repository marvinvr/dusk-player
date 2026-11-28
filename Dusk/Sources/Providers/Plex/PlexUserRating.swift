import Foundation

/// Plex's `UserRatingProviding`. Empty until P0-07 moves the Plex calls here.
struct PlexUserRating: UserRatingProviding {
    let client: PlexClient
}

extension PlexServerProvider {
    var rating: (any UserRatingProviding)? { PlexUserRating(client: client) }
}
