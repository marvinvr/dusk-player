import Foundation

// The sort and filter vocabulary itself (`LibraryWatchStatus`,
// `LibraryFilterField`, `LibraryFilterChoice`, `LibraryFilter`) is neutral and
// lives in `Domain/LibraryBrowse.swift` and `Providers/Core/CatalogProviding.swift`.

/// Everything the Filters sheet sets, combined with AND.
struct LibraryFilterState: Hashable, Sendable {
    var watchStatus: LibraryWatchStatus = .all
    var choices: [String: LibraryFilterChoice] = [:]
    var toggles: Set<String> = []

    var isEmpty: Bool { watchStatus == .all && choices.isEmpty && toggles.isEmpty }

    /// For the Filters chip: how many filters are on, watch state included.
    var activeCount: Int {
        (watchStatus == .all ? 0 : 1) + choices.count + toggles.count
    }

    /// Everything but the watch state, which `LibraryUnwatchedFilter` and the
    /// chip own.
    var hasFieldFilters: Bool { !choices.isEmpty || !toggles.isEmpty }

    /// The sheet's part of a listing's `LibraryFilter`; the grid adds the
    /// collection, the genre and collection folding.
    var libraryFilter: LibraryFilter {
        LibraryFilter(
            watchStatus: watchStatus,
            choices: choices.mapValues(\.value),
            toggles: toggles
        )
    }
}
