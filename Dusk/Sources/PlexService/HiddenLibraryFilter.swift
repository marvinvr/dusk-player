import Foundation

/// Drops the content of libraries the account has hidden.
///
/// Hidden is the plex.tv `pinnedSources[].isHidden` flag (Settings › Libraries ›
/// Hidden Libraries, or the same switch in Plex Web), read through
/// `LibraryOrderStore.hiddenLibraryFilter`. A hidden library is gone from Dusk
/// completely, so everything that can surface items from more than one library
/// — Home hubs and Continue Watching, search, hub paging, a person's titles,
/// recommendations, Siri — runs its results through this.
///
/// Matching is on `"<serverID>|<librarySectionID>"`, the `Library.id`
/// shape: section keys are per-server counters. An item or hub that does not
/// say which section it belongs to is kept, because there is nothing to match
/// it against.
///
/// The server's own per-library Visibility (`Library.visibility`) adds to
/// this for Home and search only — see `Scope`.
struct HiddenLibraryFilter: Sendable {
    /// Where the filter is applied. The account flag hides a library in every
    /// scope; the server's Visibility setting only keeps a library's titles
    /// out of Home (and search), never out of its own tab, like Plex Web.
    enum Scope: Sendable {
        /// Library lists, a library's own rows, person pages, copies.
        case everywhere
        /// Every Home row, Continue Watching, recommendations, the Top Shelf.
        case home
        /// Search and Siri.
        case search
    }

    let hiddenLibraryIDs: Set<String>

    static let none = HiddenLibraryFilter(hiddenLibraryIDs: [])

    init(hiddenLibraryIDs: Set<String>) {
        self.hiddenLibraryIDs = hiddenLibraryIDs
    }

    /// The account-hidden libraries plus the sections whose server-side
    /// Visibility excludes them from `scope`.
    init(accountHiddenIDs: Set<String>, sections: [Library], scope: Scope) {
        let serverExcluded: [Library]
        switch scope {
        case .everywhere:
            serverExcluded = []
        case .home:
            serverExcluded = sections.filter { $0.visibility != .included }
        case .search:
            serverExcluded = sections.filter { $0.visibility == .excludedFromHomeAndSearch }
        }
        hiddenLibraryIDs = accountHiddenIDs.union(serverExcluded.map(\.id))
    }

    func hides(serverID: String?, librarySectionID: String?) -> Bool {
        guard !hiddenLibraryIDs.isEmpty,
              let serverID = serverID?.nilIfEmpty,
              let librarySectionID = librarySectionID?.nilIfEmpty else { return false }
        return hiddenLibraryIDs.contains("\(serverID)|\(librarySectionID)")
    }

    func hides(_ library: Library) -> Bool {
        hiddenLibraryIDs.contains(library.id)
    }

    func hides(_ item: MediaItem) -> Bool {
        hides(serverID: item.serverID, librarySectionID: item.librarySectionID)
    }

    func filtering(_ items: [MediaItem]) -> [MediaItem] {
        guard !hiddenLibraryIDs.isEmpty else { return items }
        return items.filter { !hides($0) }
    }

    /// Drops the rows of hidden libraries, and the hidden libraries' items from
    /// global rows (Recently Added, Continue Watching, search groups). A global
    /// row left with nothing in it is dropped too. Expects one server's
    /// unmerged hubs: a merged row has no single `serverID`.
    func filtering(_ hubs: [HomeRow]) -> [HomeRow] {
        guard !hiddenLibraryIDs.isEmpty else { return hubs }
        return hubs.compactMap { hub in
            guard !hides(serverID: hub.serverID, librarySectionID: hub.resolvedLibrarySectionID) else {
                return nil
            }
            let items = filtering(hub.items)
            guard items.count != hub.items.count else { return hub }
            return items.isEmpty ? nil : hub.replacingItems(items)
        }
    }
}
