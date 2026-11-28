import Foundation

/// Regroups the rows of `GET /hubs` client-side so Home follows the account's
/// library order.
///
/// PMS returns hubs grouped by library section in its own order and offers no
/// way to ask for a different one (`pinnedContentDirectoryID` is not honoured by
/// shipping servers), so Dusk permutes the rows itself.
enum HomeHubArrangement {
    /// Orders `hubs` by `libraryOrder`, a list of `Library.id`
    /// (`"<serverID>|<key>"`) in effective order.
    ///
    /// The id, not the bare section key: section keys are per-server counters,
    /// so with two servers connected "3" means a different library on each and
    /// keying on it alone would drop one server's rows into the other's block.
    /// A merged row is placed by its representative source — the highest
    /// priority server that contributed to it.
    ///
    /// Layout: global rows (hubs with no resolvable section, e.g. Continue
    /// Watching) keep their server order and stay first; then one contiguous
    /// block per library in `libraryOrder`, each block keeping the server's
    /// row order inside it; then any hub whose section is not in `libraryOrder`
    /// at all, in server order.
    ///
    /// `libraryOrder` must be the effective order of *every* section, including
    /// music and photo libraries that Dusk itself never lists — otherwise their
    /// hubs would be shuffled into the unknown tail. Build it from the
    /// unfiltered `/library/sections` result.
    ///
    /// Filter hubs (`HomeHubFilter`) before arranging. The result is a pure
    /// permutation: no hub is added, dropped, or modified, so an empty
    /// `libraryOrder` simply returns the input untouched.
    static func arrange(hubs: [HomeRow], libraryOrder: [String], libraries: [Library] = []) -> [HomeRow] {
        guard !libraryOrder.isEmpty else { return hubs }

        var rank: [String: Int] = [:]
        for (index, key) in libraryOrder.enumerated() where rank[key] == nil {
            rank[key] = index
        }

        var global: [HomeRow] = []
        var buckets: [[HomeRow]] = Array(repeating: [], count: libraryOrder.count)
        var unknown: [HomeRow] = []

        for hub in hubs {
            guard let libraryID = libraryID(for: hub, libraries: libraries) else {
                global.append(hub)
                continue
            }
            if let index = rank[libraryID] {
                buckets[index].append(hub)
            } else {
                unknown.append(hub)
            }
        }

        return global + buckets.flatMap { $0 } + unknown
    }

    /// Prefer Plex's section metadata. For unscoped library rows, inspect only
    /// the representative server's items: merged rows can contain other servers'
    /// section keys. Never guess between several libraries of the same type.
    private static func libraryID(for hub: HomeRow, libraries: [Library]) -> String? {
        if let libraryID = hub.representativeLibraryID { return libraryID }
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        guard !HomeHubFilter.shouldHide(hub: hub), hub.type != "mixed",
              !identifier.hasPrefix("home.continue"),
              !identifier.hasPrefix("home.ondeck") else { return nil }

        let fields = [hub.hubIdentifier, hub.key].compactMap { $0?.lowercased() }
        let isRecentlyAdded = fields.contains { $0.contains("recentlyadded") }
        let isLibraryRow = isRecentlyAdded || hub.librarySectionTitle?.nilIfEmpty != nil ||
            ["movie.", "tv.", "show.", "season.", "episode.", "library."].contains { identifier.hasPrefix($0) }
        guard isLibraryRow else { return nil }

        let items = hub.items.filter { $0.serverID == hub.representativeServerID }
        let sectionIDs = Set(items.compactMap(\.libraryID))
        if sectionIDs.count == 1, let sectionID = sectionIDs.first {
            return hub.representativeServerID.map { "\($0)|\(sectionID)" } ?? sectionID
        }
        guard sectionIDs.isEmpty else { return nil }

        // Older PMS also has type-wide Recently Added hubs without section
        // metadata. A unique matching library on that server is unambiguous.
        guard isRecentlyAdded else { return nil }
        let type: LibraryKind?
        switch hub.type {
        case "movie": type = items.isAllClips ? .video : .movie
        case "show", "season", "episode": type = .show
        case "clip": type = .video
        default: type = nil
        }
        guard let type else { return nil }
        let candidates = libraries.filter {
            $0.serverID == hub.representativeServerID && $0.libraryType == type
        }
        return candidates.count == 1 ? candidates.first?.id : nil
    }
}
