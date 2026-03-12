import Foundation

/// A season within a TV show.
/// Returned from `GET /library/metadata/{showRatingKey}/children`.
struct PlexSeason: Codable, Sendable, Identifiable {
    var id: String { ratingKey }

    let ratingKey: String
    let key: String
    let title: String
    let index: Int

    // Parent show
    let parentRatingKey: String?
    let parentTitle: String?
    let parentThumb: String?

    // Images
    let thumb: String?
    let art: String?

    // Episode counts
    let leafCount: Int?
    let viewedLeafCount: Int?

    // Timestamps
    let addedAt: Int?
    let updatedAt: Int?
}

extension PlexSeason {
    /// Whether all episodes in this season have been watched.
    var isFullyWatched: Bool {
        guard let total = leafCount, let viewed = viewedLeafCount else { return false }
        return total > 0 && viewed >= total
    }
}
