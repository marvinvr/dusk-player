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
    static func merge(_ lists: [[PlexItem]]) -> MergedPlexItems {
        let alternates = PlexItemMerge.alternates(in: lists)

        // One server: Plex already ordered this row, and re-sorting it here
        // would change what a single-server install has always shown.
        guard lists.count > 1 else {
            return MergedPlexItems(items: lists.first ?? [], alternates: alternates)
        }

        var representatives: [PlexContentKey: Candidate] = [:]
        var order: [PlexContentKey] = []

        for (rank, list) in lists.enumerated() {
            for item in list {
                let key = item.contentKey
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
                let left = lhs.element.item.lastViewedAt ?? 0
                let right = rhs.element.item.lastViewedAt ?? 0
                if left != right { return left > right }
                return lhs.offset < rhs.offset
            }
            .map(\.element.item)

        return MergedPlexItems(items: sorted, alternates: alternates)
    }

    /// The copy that best represents a title: the one played most recently,
    /// then the one furthest in, then the one on the highest-priority server.
    private struct Candidate {
        let item: PlexItem
        let rank: Int

        func wins(over other: Candidate) -> Bool {
            let lastViewedAt = item.lastViewedAt ?? 0
            let otherLastViewedAt = other.item.lastViewedAt ?? 0
            if lastViewedAt != otherLastViewedAt { return lastViewedAt > otherLastViewedAt }

            let offset = item.viewOffset ?? 0
            let otherOffset = other.item.viewOffset ?? 0
            if offset != otherOffset { return offset > otherOffset }

            return rank < other.rank
        }
    }
}
