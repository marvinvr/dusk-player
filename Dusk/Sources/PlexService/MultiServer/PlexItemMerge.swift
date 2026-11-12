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
/// Strong movie identities also collapse copies from libraries on one server.
/// Weak identities and same-server TV items retain their own rows.
enum PlexItemMerge {
    /// Movie additions form one timeline across libraries/servers. Interleaving
    /// puts an old library's newest movie ahead of another library's newer ones.
    /// Keep Plex's single-source order and TV's episode/season grouping intact.
    static func hubItems(_ lists: [[PlexItem]], for hub: PlexHub) -> MergedPlexItems {
        let isRecentlyAdded = hub.hubIdentifier?.lowercased().contains(".recentlyadded.") == true
            || hub.title.lowercased().contains("recently added")
        guard lists.count > 1, hub.type == "movie", isRecentlyAdded else {
            return interleave(lists)
        }

        // Explicit offsets preserve source priority and Plex's order for ties
        // (including missing dates). Never substitute update or release dates.
        let sorted = lists.flatMap { $0 }.enumerated().sorted { lhs, rhs in
            let leftDate = lhs.element.addedAt ?? Int.min
            let rightDate = rhs.element.addedAt ?? Int.min
            return leftDate == rightDate ? lhs.offset < rhs.offset : leftDate > rightDate
        }
        let merged = interleave([sorted.map(\.element)])
        return MergedPlexItems(items: merged.items, alternates: alternates(in: lists))
    }

    /// Deduplicates by content key and visits the servers round-robin, so a row
    /// leads with the highest-priority server's newest item but still shows what
    /// the others have without scrolling to the end.
    static func interleave(_ lists: [[PlexItem]]) -> MergedPlexItems {
        let keys = contentKeys(in: lists)
        let alternates = alternates(in: lists)
        var merged: [PlexItem] = []
        merged.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        var placed: [PlexContentKey: [Int]] = [:]
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
                let key = keys[item.id] ?? item.contentKey
                let existing = placed[key, default: []].first { offset in
                    let other = merged[offset]
                    return other.id == item.id || other.serverID != item.serverID
                        || (!item.movieContentKeys.isEmpty && !other.movieContentKeys.isEmpty)
                }
                if let existing {
                    if !item.movieContentKeys.isEmpty, isMoreAdvanced(item, than: merged[existing]) {
                        merged[existing] = item
                    }
                } else {
                    placed[key, default: []].append(merged.count)
                    merged.append(item)
                }
            }
        }

        return MergedPlexItems(items: merged, alternates: alternates)
    }

    /// Strong movie copies include every rating key, including the same server.
    /// TV keeps the existing one-copy-per-server behavior.
    static func alternates(in lists: [[PlexItem]]) -> [PlexContentKey: [PlexItemID]] {
        var alternates: [PlexContentKey: [PlexItemID]] = [:]
        let keys = contentKeys(in: lists)

        for list in lists {
            for item in list {
                let key = keys[item.id] ?? item.contentKey
                guard key.isStrong else { continue }
                var known = alternates[key] ?? []
                guard !known.contains(item.id),
                      (key.isMovie || !known.contains(where: { $0.serverID == item.id.serverID })) else { continue }
                known.append(item.id)
                alternates[key] = known
            }
        }

        return alternates
    }

    /// Merges alternate tables, retaining copy identity and source ordering.
    static func combine(
        _ lhs: [PlexContentKey: [PlexItemID]],
        _ rhs: [PlexContentKey: [PlexItemID]]
    ) -> [PlexContentKey: [PlexItemID]] {
        var combined = lhs
        for (key, ids) in rhs {
            var known = combined[key] ?? []
            for id in ids where !known.contains(id)
                && (key.isMovie || !known.contains(where: { $0.serverID == id.serverID })) {
                known.append(id)
            }
            combined[key] = known
        }
        return combined
    }

    /// Resolve overlapping movie aliases transitively, so a Plex GUID on one
    /// item and an IMDb-only legacy item can identify the same movie.
    static func contentKeys(in lists: [[PlexItem]]) -> [PlexItemID: PlexContentKey] {
        var parents: [PlexContentKey: PlexContentKey] = [:]
        func root(_ key: PlexContentKey) -> PlexContentKey {
            var value = key
            while let parent = parents[value], parent != value { value = parent }
            return value
        }
        for item in lists.flatMap({ $0 }) {
            let primary = root(item.contentKey)
            for alias in item.movieContentKeys {
                let other = root(alias)
                if other != primary { parents[other] = primary }
            }
        }
        return Dictionary(lists.flatMap { $0 }.map { ($0.id, root($0.contentKey)) },
                          uniquingKeysWith: { first, _ in first })
    }

    static func isMoreAdvanced(_ item: PlexItem, than other: PlexItem) -> Bool {
        let watched = (item.viewCount ?? 0) > 0
        let otherWatched = (other.viewCount ?? 0) > 0
        if watched != otherWatched { return watched }
        let progress = Double(item.viewOffset ?? 0) / Double(max(item.duration ?? 1, 1))
        let otherProgress = Double(other.viewOffset ?? 0) / Double(max(other.duration ?? 1, 1))
        return progress > otherProgress
    }
}
