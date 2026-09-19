import Foundation

/// Merged search groups plus the alternates found while merging them.
struct MergedSearchResults: Sendable {
    let groups: [PlexSearchResult]
    let alternates: [PlexContentKey: [PlexItemID]]

    static let empty = MergedSearchResults(groups: [], alternates: [:])
}

/// Collapses `/hubs/search` groups from several servers into one result list.
///
/// Search is fanned out and republished every time a server answers, so this is
/// called repeatedly with a growing set of lists. It is a pure function of them
/// for that reason: the order a user is already reading must not depend on
/// which server happened to answer first.
enum SearchMerge {
    /// - Parameter lists: one entry per connected server, in priority order.
    static func merge(_ lists: [[PlexSearchResult]]) -> MergedSearchResults {
        guard lists.count > 1 else {
            let groups = lists.first ?? []
            return MergedSearchResults(
                groups: groups,
                alternates: PlexItemMerge.alternates(in: groups.map(\.items))
            )
        }

        var groupedResults: [String: [PlexSearchResult]] = [:]
        var order: [String] = []

        for list in lists {
            for group in list {
                let key = group.id
                if groupedResults[key] == nil {
                    order.append(key)
                }
                groupedResults[key, default: []].append(group)
            }
        }

        var merged: [PlexSearchResult] = []
        var alternates: [PlexContentKey: [PlexItemID]] = [:]

        for key in order {
            guard let group = groupedResults[key], let representative = group.first else { continue }
            let mergedItems = PlexItemMerge.interleave(group.map(\.items))
            alternates = PlexItemMerge.combine(alternates, mergedItems.alternates)
            merged.append(
                PlexSearchResult(
                    title: representative.title,
                    type: representative.type,
                    items: mergedItems.items
                )
            )
        }

        return MergedSearchResults(groups: merged.filter { !$0.items.isEmpty }, alternates: alternates)
    }
}
