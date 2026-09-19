import Foundation

/// Regroups the rows of `GET /hubs` client-side so Home follows the account's
/// library order.
///
/// PMS returns hubs grouped by library section in its own order and offers no
/// way to ask for a different one (`pinnedContentDirectoryID` is not honoured by
/// shipping servers), so Dusk permutes the rows itself.
enum HomeHubArrangement {
    /// Orders `hubs` by `libraryOrder`, a list of `PlexLibrary.id`
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
    static func arrange(hubs: [PlexHub], libraryOrder: [String]) -> [PlexHub] {
        guard !libraryOrder.isEmpty else { return hubs }

        var rank: [String: Int] = [:]
        for (index, key) in libraryOrder.enumerated() where rank[key] == nil {
            rank[key] = index
        }

        var global: [PlexHub] = []
        var buckets: [[PlexHub]] = Array(repeating: [], count: libraryOrder.count)
        var unknown: [PlexHub] = []

        for hub in hubs {
            guard let libraryID = hub.representativeLibraryID else {
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
}
