import Foundation

/// An episode within a TV season.
/// Returned from `GET /library/metadata/{seasonRatingKey}/children`.
struct Episode: Sendable, Identifiable {
    /// Server-scoped identity; see `MediaItemID`.
    var id: MediaItemID { MediaItemID(serverID: serverID, itemID: itemID) }

    /// Stamped by the provider's mapper (`PlexItemMapper`); never part of the
    /// server payload.
    let serverID: String?

    let itemID: String
    let key: String
    let title: String

    // Episode/season numbering
    let index: Int?
    let parentIndex: Int?

    // Parent season
    let parentID: String?
    let parentTitle: String?

    // Grandparent show
    let grandparentID: String?
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
    let playCount: Int?
    let resumeOffsetMs: Int?
    let lastPlayedAt: Int?

    // Timestamps
    let addedAt: Int?
    let updatedAt: Int?
}

extension Episode {
    var isWatched: Bool {
        guard let count = playCount else { return false }
        return count > 0
    }

    var isPartiallyWatched: Bool {
        guard let offset = resumeOffsetMs, offset > 0 else { return false }
        return true
    }

    /// Human-readable episode label like "Episode 5".
    var episodeLabel: String? {
        guard let e = index else { return nil }
        return "Episode \(e)"
    }
}

/// The episodes either side of the one playing, for the player's Previous /
/// Next Episode controls. Either side may be nil: the first or last episode of
/// the show, or (for downloads) no downloaded neighbour.
struct AdjacentEpisodes: Sendable {
    var previous: Episode?
    var next: Episode?

    /// Neighbours inside one season. `episodes` must be sorted by `index`.
    /// Falls back to episode numbers when the playing episode is not in the
    /// list (a server-side renumbering, a cached list from another server).
    /// `isEligible` skips episodes that cannot play, such as ones that are not
    /// downloaded during offline playback.
    static func inSeason(
        _ episodes: [Episode],
        around episode: MediaDetails,
        isEligible: (Episode) -> Bool = { _ in true }
    ) -> AdjacentEpisodes {
        if let position = episodes.firstIndex(where: { $0.itemID == episode.itemID }) {
            return AdjacentEpisodes(
                previous: episodes[..<position].last(where: isEligible),
                next: episodes[episodes.index(after: position)...].first(where: isEligible)
            )
        }

        guard let number = episode.index else { return AdjacentEpisodes() }
        return AdjacentEpisodes(
            previous: episodes.last { ($0.index ?? 0) < number && isEligible($0) },
            next: episodes.first { ($0.index ?? 0) > number && isEligible($0) }
        )
    }
}
