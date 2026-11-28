import Foundation

/// The grid's watch-state filter. Unwatched is also the one-tap chip and is
/// remembered per library; the others last for the screen.
enum LibraryWatchStatus: String, CaseIterable, Identifiable, Sendable {
    case all
    case unwatched
    case inProgress
    case watched

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .unwatched: "Unwatched"
        case .inProgress: "In Progress"
        case .watched: "Watched"
        }
    }

    /// Plex's parameter for it. Movies and videos filter the item itself;
    /// shows filter on their episodes (`unwatchedLeaves`), so a show is
    /// "watched" once every episode is. Plex has no in-progress filter for
    /// show sections.
    func serverFilter(libraryType: LibraryKind?) -> (name: String, value: String)? {
        let unwatchedName = LibraryUnwatchedFilter.parameterName(for: libraryType)
        switch self {
        case .all: return nil
        case .unwatched: return (unwatchedName, "1")
        case .watched: return (unwatchedName, "0")
        case .inProgress: return libraryType == .show ? nil : ("inProgress", "1")
        }
    }

    static func options(for libraryType: LibraryKind?) -> [LibraryWatchStatus] {
        libraryType == .show ? [.all, .unwatched, .watched] : allCases
    }
}

/// One of Plex's section filters the Filters sheet offers, in the sheet's
/// order. Only the ones the section's `/filters` lists are shown.
struct LibraryFilterField: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Pick one of the values Plex lists at `path`.
        case values(path: String)
        /// On or off (`hdr=1`).
        case toggle
    }

    /// Plex's parameter name (`decade`, `audioLanguage`, `hdr`, …).
    let parameter: String
    let title: String
    let kind: Kind

    var id: String { parameter }

    /// Which of Plex's filters the sheet offers, with Dusk's titles. Genre
    /// has its own menu; watch state its own section.
    static let offered: [(parameter: String, title: String)] = [
        ("decade", "Decade"),
        ("year", "Year"),
        ("contentRating", "Content Rating"),
        ("resolution", "Resolution"),
        ("hdr", "HDR"),
        ("dovi", "Dolby Vision"),
        ("audioLanguage", "Audio Language"),
        ("studio", "Studio"),
        ("network", "Network"),
        ("collection", "Collection"),
        ("director", "Director"),
        ("actor", "Actor"),
    ]

    /// The offered fields among a section's `/filters` rows.
    static func fields(from filters: [PlexLibraryFilter], includesCollection: Bool) -> [LibraryFilterField] {
        let byName = Dictionary(filters.map { ($0.filter, $0) }, uniquingKeysWith: { first, _ in first })
        return offered.compactMap { offered in
            guard includesCollection || offered.parameter != "collection",
                  let filter = byName[offered.parameter] else { return nil }
            let kind: Kind = filter.filterType == "boolean" ? .toggle : .values(path: filter.key)
            return LibraryFilterField(parameter: offered.parameter, title: offered.title, kind: kind)
        }
    }
}

/// A value picked for a `.values` field.
struct LibraryFilterChoice: Identifiable, Hashable, Sendable {
    /// The query value. Plex percent-encodes some keys (`Not%20Rated`);
    /// this is decoded, and encoded once when the query is built.
    let value: String
    let title: String

    var id: String { value }

    init(value: String, title: String) {
        self.value = value
        self.title = title
    }

    init(_ value: PlexLibraryFilterValue) {
        self.value = value.key.removingPercentEncoding ?? value.key
        self.title = value.title
    }
}

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

    func serverFilters(libraryType: LibraryKind?) -> [String: String] {
        var filters: [String: String] = [:]
        if let status = watchStatus.serverFilter(libraryType: libraryType) {
            filters[status.name] = status.value
        }
        for (parameter, choice) in choices {
            filters[parameter] = choice.value
        }
        for parameter in toggles {
            filters[parameter] = "1"
        }
        return filters
    }
}
