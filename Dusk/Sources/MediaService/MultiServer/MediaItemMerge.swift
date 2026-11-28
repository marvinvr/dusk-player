import Foundation

/// One merged row: the items to show plus every copy of every piece of content
/// that went into it.
///
/// `alternates` is what playback needs later — the same movie on three servers
/// gives three `MediaItemID`s, in server-priority order — and is handed to
/// `ContentAlternatesIndex` by the caller that owns the service.
struct MergedPlexItems: Sendable {
    let items: [MediaItem]
    let alternates: [ContentKey: [MediaItemID]]

    static let empty = MergedPlexItems(items: [], alternates: [:])
}

/// Collapses the same row fetched from several servers into one.
///
/// Every function here takes `lists` in **server-priority order** and is a pure
/// function of them, so the same servers always produce the same row: that is
/// what keeps a progressively rendered screen from reshuffling itself as more
/// servers answer.
///
/// Strong identities (a Plex GUID or external id) also collapse copies from
/// libraries on one server — the same show filed under "Kids TV" and "TV" is
/// one entry on Home. Weak (title/numbering) identities on one server keep
/// their own rows: a guess is not enough to hide a library's item.
enum MediaItemMerge {
    /// Movie additions form one timeline across libraries/servers. Interleaving
    /// puts an old library's newest movie ahead of another library's newer ones.
    /// Keep Plex's single-source order and TV's episode/season grouping intact.
    static func hubItems(_ lists: [[MediaItem]], for hub: HomeRow) -> MergedPlexItems {
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
    static func interleave(_ lists: [[MediaItem]]) -> MergedPlexItems {
        let keys = contentKeys(in: lists)
        let alternates = alternates(in: lists)
        var merged: [MediaItem] = []
        merged.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        var placed: [ContentKey: [Int]] = [:]
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
                    return other.id == item.id || other.serverID != item.serverID || key.isStrong
                        || (!item.movieContentKeys.isEmpty && !other.movieContentKeys.isEmpty)
                }
                if let existing {
                    let other = merged[existing]
                    if !item.movieContentKeys.isEmpty {
                        if isMoreAdvanced(item, than: other) { merged[existing] = item }
                    } else if other.id != item.id, other.serverID == item.serverID,
                              isMoreRecentlyWatched(item, than: other) {
                        // Same episode/show in two libraries of one server: keep
                        // the copy the user actually watched last. Across servers
                        // the priority server's copy keeps the slot, as before.
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

    /// Every rating key of a strong identity, including copies in other
    /// libraries of the same server.
    static func alternates(in lists: [[MediaItem]]) -> [ContentKey: [MediaItemID]] {
        var alternates: [ContentKey: [MediaItemID]] = [:]
        let keys = contentKeys(in: lists)

        for list in lists {
            for item in list {
                let key = keys[item.id] ?? item.contentKey
                guard key.isStrong else { continue }
                var known = alternates[key] ?? []
                guard !known.contains(item.id) else { continue }
                known.append(item.id)
                alternates[key] = known
            }
        }

        return alternates
    }

    /// Merges alternate tables, retaining copy identity and source ordering.
    static func combine(
        _ lhs: [ContentKey: [MediaItemID]],
        _ rhs: [ContentKey: [MediaItemID]]
    ) -> [ContentKey: [MediaItemID]] {
        var combined = lhs
        for (key, ids) in rhs {
            var known = combined[key] ?? []
            for id in ids where !known.contains(id)
                && (key.isStrong || !known.contains(where: { $0.serverID == id.serverID })) {
                known.append(id)
            }
            combined[key] = known
        }
        return combined
    }

    /// Resolve overlapping movie aliases transitively, so a Plex GUID on one
    /// item and an IMDb-only legacy item can identify the same movie.
    static func contentKeys(in lists: [[MediaItem]]) -> [MediaItemID: ContentKey] {
        var parents: [ContentKey: ContentKey] = [:]
        func root(_ key: ContentKey) -> ContentKey {
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

    static func isMoreAdvanced(_ item: MediaItem, than other: MediaItem) -> Bool {
        let watched = (item.playCount ?? 0) > 0
        let otherWatched = (other.playCount ?? 0) > 0
        if watched != otherWatched { return watched }
        let progress = Double(item.resumeOffsetMs ?? 0) / Double(max(item.duration ?? 1, 1))
        let otherProgress = Double(other.resumeOffsetMs ?? 0) / Double(max(other.duration ?? 1, 1))
        return progress > otherProgress
    }

    /// Most recently played first, then furthest along.
    static func isMoreRecentlyWatched(_ item: MediaItem, than other: MediaItem) -> Bool {
        let lastPlayedAt = item.lastPlayedAt ?? 0
        let otherLastViewedAt = other.lastPlayedAt ?? 0
        if lastPlayedAt != otherLastViewedAt { return lastPlayedAt > otherLastViewedAt }
        return (item.resumeOffsetMs ?? 0) > (other.resumeOffsetMs ?? 0)
    }
}
