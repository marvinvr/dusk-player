import Foundation

/// An episode within a TV season.
/// Returned from `GET /library/metadata/{seasonRatingKey}/children`.
struct PlexEpisode: Codable, Sendable, Identifiable {
    var id: String { ratingKey }

    let ratingKey: String
    let key: String
    let title: String

    // Episode/season numbering
    let index: Int?
    let parentIndex: Int?

    // Parent season
    let parentRatingKey: String?
    let parentTitle: String?

    // Grandparent show
    let grandparentRatingKey: String?
    let grandparentTitle: String?
    let grandparentThumb: String?

    // Content
    let summary: String?
    let contentRating: String?
    let originallyAvailableAt: String?
    let year: Int?

    // Images
    let thumb: String?
    let art: String?

    // Playback / watch state
    let duration: Int?
    let viewCount: Int?
    let viewOffset: Int?
    let lastViewedAt: Int?

    // Timestamps
    let addedAt: Int?
    let updatedAt: Int?
}

extension PlexEpisode {
    var isWatched: Bool {
        guard let count = viewCount else { return false }
        return count > 0
    }

    var isPartiallyWatched: Bool {
        guard let offset = viewOffset, offset > 0 else { return false }
        return true
    }

    /// Human-readable episode label like "Episode 5".
    var episodeLabel: String? {
        guard let e = index else { return nil }
        return "Episode \(e)"
    }
}
