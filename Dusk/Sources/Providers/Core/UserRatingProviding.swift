import Foundation

/// The user's own numeric rating of an item, for servers that keep one
/// (docs/jellyfin/04-architecture.md §3, `MediaServerProvider.rating`).
@MainActor
protocol UserRatingProviding: Sendable {
    /// Sets the rating on a 0–10 scale (two per star), or clears it with nil.
    func setRating(_ rating: Int?, itemID: String) async throws
}
