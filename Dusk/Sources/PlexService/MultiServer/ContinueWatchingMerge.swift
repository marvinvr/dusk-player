import Foundation

/// Merges the Continue Watching row across servers.
///
/// Unlike a hub row, this one must not interleave: the user thinks of it as one
/// chronological list of what they were watching, so the copies of a title
/// collapse into a single representative and the whole row is re-sorted by when
/// it was last played. Which *copy* represents the title matters, because that
/// is the progress Plex will resume from.
enum ContinueWatchingMerge {
    /// - Parameter lists: one entry per connected server, in priority order.
    static func merge(_ lists: [[MediaItem]]) -> MergedPlexItems {
        let alternates = MediaItemMerge.alternates(in: lists)
        let keys = MediaItemMerge.contentKeys(in: lists)

        // One server: Plex already ordered this row, and re-sorting it here
        // would change what a single-server install has always shown.
        guard lists.count > 1 else {
            return MediaItemMerge.interleave(lists)
        }

        var representatives: [ContentKey: Candidate] = [:]
        var order: [ContentKey] = []

        for (rank, list) in lists.enumerated() {
            for item in MediaItemMerge.interleave([list]).items {
                var key = keys[item.id] ?? item.contentKey
                if let existing = representatives[key], existing.item.serverID == item.serverID,
                   existing.item.id != item.id, !key.isStrong, item.movieContentKeys.isEmpty {
                    key = .instance(item.id)
                }
                let candidate = Candidate(item: item, rank: rank)
                guard let existing = representatives[key] else {
                    representatives[key] = candidate
                    order.append(key)
                    continue
                }
                if candidate.wins(over: existing) {
                    representatives[key] = candidate
                }
            }
        }

        // Newest first. Ties keep the order the servers were visited in, so the
        // row does not shuffle between two refreshes of the same content.
        let sorted = order
            .compactMap { representatives[$0] }
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.item.lastPlayedAt ?? 0
                let right = rhs.element.item.lastPlayedAt ?? 0
                if left != right { return left > right }
                return lhs.offset < rhs.offset
            }
            .map(\.element.item)

        return MergedPlexItems(items: sorted, alternates: alternates)
    }

    /// Movies use the most advanced copy. TV uses recency, then offset and
    /// server priority, as before.
    private struct Candidate {
        let item: MediaItem
        let rank: Int

        func wins(over other: Candidate) -> Bool {
            if !item.movieContentKeys.isEmpty, !other.item.movieContentKeys.isEmpty {
                return MediaItemMerge.isMoreAdvanced(item, than: other.item)
            }
            let lastPlayedAt = item.lastPlayedAt ?? 0
            let otherLastViewedAt = other.item.lastPlayedAt ?? 0
            if lastPlayedAt != otherLastViewedAt { return lastPlayedAt > otherLastViewedAt }

            let offset = item.resumeOffsetMs ?? 0
            let otherOffset = other.item.resumeOffsetMs ?? 0
            if offset != otherOffset { return offset > otherOffset }

            return rank < other.rank
        }
    }
}
