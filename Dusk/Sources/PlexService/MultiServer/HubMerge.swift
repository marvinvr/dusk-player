import Foundation

/// Merged hub rows plus the alternates found while merging them.
struct MergedPlexHubs: Sendable {
    let hubs: [PlexHub]
    let alternates: [PlexContentKey: [PlexItemID]]

    static let empty = MergedPlexHubs(hubs: [], alternates: [:])
}

/// Collapses "Recently Added Movies" on three servers into one row.
///
/// The hard part is deciding that two rows *are* the same row. Plex names a
/// per-library hub `"<type>.<name>.<sectionID>"`, and the section id is a
/// per-server counter, so the suffix has to go before the identifiers can be
/// compared — but stripping it also makes every movie library on one server
/// look like the same row, which is why the library itself is part of the key
/// and why two rows from the same server never merge in `.home` mode.
/// Everything else (row order, which library a row belongs to) is left to
/// `HomeHubArrangement`, which runs on the merged rows.
enum HubMerge {
    /// What "the same row" means for this merge.
    enum Mode {
        /// `GET /hubs`, one list per server. A row only merges with the *same
        /// library on another server* — same row kind, same library type, same
        /// library title — and never with another row of the same server, which
        /// would silently drop a whole library's rows off Home.
        case home
        /// `GET /hubs/sections/{id}`, one list per library. A type tab exists to
        /// show every library of that type as one screen, so rows of the same
        /// kind merge across libraries whether or not they share a server.
        case libraryType
    }

    /// - Parameter lists: one entry per connected server (`.home`) or per
    ///   library (`.libraryType`), in priority order.
    static func merge(_ lists: [[PlexHub]], mode: Mode = .home) -> MergedPlexHubs {
        // One source: nothing to collapse, and `PlexHub.sources` already carries
        // that server, so "Show All" keeps working unchanged.
        guard lists.count > 1 else {
            let hubs = lists.first ?? []
            return MergedPlexHubs(
                hubs: hubs,
                alternates: PlexItemMerge.alternates(in: hubs.map(\.items))
            )
        }

        var groups: [[PlexHub]] = []
        var identities: [String] = []
        var groupsByKey: [String: [Int]] = [:]

        for list in lists {
            for hub in list {
                let key = mergeKey(for: hub, mode: mode)
                let existing = groupsByKey[key] ?? []
                if let index = existing.first(where: { canMerge(hub, into: groups[$0], mode: mode) }) {
                    groups[index].append(hub)
                    continue
                }
                groups.append([hub])
                // Rows that could not join an existing group of the same key are
                // still separate rows, so their identity has to differ too.
                identities.append(existing.isEmpty ? key : "\(key)#\(existing.count)")
                groupsByKey[key] = existing + [groups.count - 1]
            }
        }

        var merged: [PlexHub] = []
        var alternates: [PlexContentKey: [PlexItemID]] = [:]

        for (index, group) in groups.enumerated() {
            guard let representative = group.first else { continue }
            let mergedItems = PlexItemMerge.interleave(group.map(\.items))
            alternates = PlexItemMerge.combine(alternates, mergedItems.alternates)
            merged.append(
                representative.merged(
                    items: mergedItems.items,
                    sources: group.flatMap(\.sources),
                    identity: identities[index]
                )
            )
        }

        return MergedPlexHubs(hubs: merged, alternates: alternates)
    }

    /// Identity of a row: the hub identifier without its per-server section
    /// suffix plus the row's type, and — on Home — the library the row belongs
    /// to, because that suffix is the only thing that told two libraries of the
    /// same type apart. Rows with no identifier (some servers omit it on
    /// `/hubs/sections`) fall back to the title.
    static func mergeKey(for hub: PlexHub, mode: Mode = .home) -> String {
        let type = hub.type ?? "-"
        let base: String

        if let hubIdentifier = hub.hubIdentifier?.nilIfEmpty {
            var components = hubIdentifier.split(separator: ".").map(String.init)
            if let last = components.last, !last.isEmpty, last.allSatisfy(\.isNumber) {
                components.removeLast()
            }
            let stripped = components.joined(separator: ".").nilIfEmpty ?? hubIdentifier
            base = "id:\(stripped.lowercased())|\(type)"
        } else {
            base = "title:\(normalized(hub.title))|\(type)"
        }

        guard mode == .home else { return base }
        return "\(base)|\(libraryKey(for: hub))"
    }

    /// Which library a Home row belongs to, as something comparable across
    /// servers: its title. A row with no library (Continue Watching and friends)
    /// is global and merges on the identifier alone; a library row whose title
    /// the server did not send cannot be matched up safely, so it keeps its own
    /// server and section and simply never merges.
    private static func libraryKey(for hub: PlexHub) -> String {
        guard let sectionID = hub.resolvedLibrarySectionID else { return "global" }
        guard let title = hub.librarySectionTitle?.nilIfEmpty else {
            return "section:\(hub.serverID ?? "-")|\(sectionID)"
        }
        return "library:\(normalized(title))"
    }

    /// Two rows of the same server are two different rows on Home, whatever
    /// their identifiers say.
    private static func canMerge(_ hub: PlexHub, into group: [PlexHub], mode: Mode) -> Bool {
        guard mode == .home else { return true }
        return !group.contains { $0.serverID == hub.serverID }
    }

    private static func normalized(_ value: String) -> String {
        String(
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        )
    }
}

extension PlexHub {
    /// The server whose row stands in for a merged row: its own server, or the
    /// highest-priority contributing source. `HomeHubArrangement` uses it to
    /// find the library a merged row belongs to.
    var representativeServerID: String? {
        serverID ?? sources.first?.serverID
    }

    /// The `PlexLibrary.id` this row belongs to, or nil for a global row such as
    /// Continue Watching. Section keys are per-server counters, so the server
    /// has to be part of it.
    var representativeLibraryID: String? {
        guard let sectionID = resolvedLibrarySectionID else { return nil }
        guard let serverID = representativeServerID else { return sectionID }
        return "\(serverID)|\(sectionID)"
    }

    /// True when at least one contributing server can page this row.
    var isPageable: Bool {
        sources.contains { $0.key?.nilIfEmpty != nil }
    }

    /// True when any contributing server says it has more than it sent.
    var hasMoreOnAnySource: Bool {
        sources.contains { $0.more == true }
    }

    /// How many items the row has in total across its servers. Deduplication
    /// means the merged row can hold fewer, never more.
    var totalSourceSize: Int {
        sources.reduce(0) { $0 + ($1.size ?? 0) }
    }
}
