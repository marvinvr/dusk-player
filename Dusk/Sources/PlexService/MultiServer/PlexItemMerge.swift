import Foundation

/// One merged row: the items to show plus every copy of every piece of content
/// that went into it.
///
/// `alternates` is what playback needs later — the same movie on three servers
/// gives three `PlexItemID`s, in server-priority order — and is handed to
/// `ContentAlternatesIndex` by the caller that owns the service.
struct MergedPlexItems: Sendable {
    let items: [PlexItem]
    let alternates: [PlexContentKey: [PlexItemID]]

    static let empty = MergedPlexItems(items: [], alternates: [:])
}

/// Collapses the same row fetched from several servers into one.
///
/// Every function here takes `lists` in **server-priority order** and is a pure
/// function of them, so the same servers always produce the same row: that is
/// what keeps a progressively rendered screen from reshuffling itself as more
/// servers answer.
///
/// A single list is always returned verbatim. Dusk is a single-server app for
/// most people, and "merging" one server's row must never be able to reorder or
/// drop anything — a heuristic content key (title/year, used when a server sends
/// no guids) can legitimately collide for two different items on one server.
enum PlexItemMerge {
    /// Deduplicates by content key and visits the servers round-robin, so a row
    /// leads with the highest-priority server's newest item but still shows what
    /// the others have without scrolling to the end.
    static func interleave(_ lists: [[PlexItem]]) -> MergedPlexItems {
        let alternates = alternates(in: lists)

        guard lists.count > 1 else {
            return MergedPlexItems(items: lists.first ?? [], alternates: alternates)
        }

        var merged: [PlexItem] = []
        merged.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        var placed: Set<PlexContentKey> = []
        var cursors = [Int](repeating: 0, count: lists.count)
        var didAdvance = true

        while didAdvance {
            didAdvance = false
            for index in lists.indices {
                let list = lists[index]
                guard cursors[index] < list.count else { continue }
                let item = list[cursors[index]]
                cursors[index] += 1
                didAdvance = true
                // A copy that lost the dedupe is consumed rather than skipped:
                // it already contributed its id to `alternates`, and leaving the
                // cursor on it would stall this server's turn.
                if placed.insert(item.contentKey).inserted {
                    merged.append(item)
                }
            }
        }

        return MergedPlexItems(items: merged, alternates: alternates)
    }

    /// Every copy of every piece of content in `lists`, in the order the lists
    /// were given — which is server-priority order, so the first entry is the
    /// copy playback should prefer.
    ///
    /// Only content that is identified by a strong key (a Plex or external id)
    /// is listed, and only once per server: a title/year guess may collapse two
    /// rows on screen, but it must never tell playback that another server's
    /// file — or a second file on the same server — is the one the user asked
    /// for. See `ContentAlternatesIndex`.
    static func alternates(in lists: [[PlexItem]]) -> [PlexContentKey: [PlexItemID]] {
        var alternates: [PlexContentKey: [PlexItemID]] = [:]

        for list in lists {
            for item in list {
                let key = item.contentKey
                guard key.isStrong else { continue }
                var known = alternates[key] ?? []
                guard !known.contains(item.id),
                      !known.contains(where: { $0.serverID == item.id.serverID }) else { continue }
                known.append(item.id)
                alternates[key] = known
            }
        }

        return alternates
    }

    /// Merges two alternate tables, keeping the left one's ordering and the
    /// one-copy-per-server rule.
    static func combine(
        _ lhs: [PlexContentKey: [PlexItemID]],
        _ rhs: [PlexContentKey: [PlexItemID]]
    ) -> [PlexContentKey: [PlexItemID]] {
        var combined = lhs
        for (key, ids) in rhs {
            var known = combined[key] ?? []
            for id in ids where !known.contains(id)
                && !known.contains(where: { $0.serverID == id.serverID }) {
                known.append(id)
            }
            combined[key] = known
        }
        return combined
    }
}
