import Foundation

// The neutral vocabulary of a library grid's sort and filter menus
// (docs/jellyfin/04-architecture.md §9). Each provider maps these onto its own
// query; `LibraryFilter` carries them to `CatalogProviding`.

/// What a library grid can be sorted by. Each provider maps a field onto its
/// own sort (the Plex catalog sends `titleSort`, …); the raw values are stored per
/// library (`LibrarySortStore`) and must never change.
enum LibrarySortField: String, CaseIterable, Identifiable, Sendable {
    case title
    case releaseDate
    case year
    case addedAt
    /// Shows only: when the newest episode arrived.
    case lastEpisodeAdded
    case userRating
    case criticRating
    case audienceRating
    case duration
    case lastViewed
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: "Title"
        case .releaseDate: "Release Date"
        case .year: "Year"
        case .addedAt: "Date Added"
        case .lastEpisodeAdded: "Episode Added"
        case .userRating: "Your Rating"
        case .criticRating: "Critic Rating"
        case .audienceRating: "Audience Rating"
        case .duration: "Duration"
        case .lastViewed: "Last Watched"
        case .random: "Random"
        }
    }

    /// Title reads A to Z; everything else starts with the newest, highest
    /// or longest.
    var defaultsToDescending: Bool { self != .title }

    /// Random has no order to flip.
    var hasDirection: Bool { self != .random }

    /// The menu's two order choices, descending first.
    var directionTitles: (descending: String, ascending: String) {
        switch self {
        case .title: ("Z to A", "A to Z")
        case .releaseDate, .year, .addedAt, .lastEpisodeAdded: ("Newest First", "Oldest First")
        case .userRating, .criticRating, .audienceRating: ("Highest First", "Lowest First")
        case .duration: ("Longest First", "Shortest First")
        case .lastViewed: ("Most Recent First", "Least Recent First")
        case .random: ("", "")
        }
    }

    /// The fields offered for a library of the given type. Video libraries
    /// lead with upload-date sorts (year is meaningless for clips).
    static func fields(for libraryType: LibraryKind?) -> [LibrarySortField] {
        switch libraryType {
        case .video:
            [.releaseDate, .addedAt, .title, .duration, .lastViewed, .random]
        case .show:
            [.title, .releaseDate, .year, .addedAt, .lastEpisodeAdded, .userRating, .criticRating,
             .audienceRating, .lastViewed, .random]
        default:
            [.title, .releaseDate, .year, .addedAt, .userRating, .criticRating, .audienceRating,
             .duration, .lastViewed, .random]
        }
    }
}

/// A grid sort: a field and its direction.
struct LibrarySortOption: Hashable, Identifiable, Sendable {
    let field: LibrarySortField
    let isDescending: Bool

    init(_ field: LibrarySortField, descending: Bool? = nil) {
        self.field = field
        isDescending = field.hasDirection ? (descending ?? field.defaultsToDescending) : false
    }

    static let titleAscending = LibrarySortOption(.title, descending: false)
    static let titleDescending = LibrarySortOption(.title, descending: true)

    var id: String { rawValue }

    /// Stored per library: `"<field>"` or `"<field>:desc"`. The names of the
    /// fixed sorts that came before still read.
    var rawValue: String {
        isDescending ? "\(field.rawValue):desc" : field.rawValue
    }

    init?(rawValue: String) {
        let legacy: [String: LibrarySortOption] = [
            "titleAscending": .titleAscending,
            "titleDescending": .titleDescending,
            "yearDescending": LibrarySortOption(.year, descending: true),
            "yearAscending": LibrarySortOption(.year, descending: false),
            "releaseDateDescending": LibrarySortOption(.releaseDate, descending: true),
            "addedAtDescending": LibrarySortOption(.addedAt, descending: true),
            "durationDescending": LibrarySortOption(.duration, descending: true),
        ]
        if let sort = legacy[rawValue] {
            self = sort
            return
        }
        let parts = rawValue.split(separator: ":", maxSplits: 1)
        guard let field = parts.first.flatMap({ LibrarySortField(rawValue: String($0)) }) else { return nil }
        self.init(field, descending: parts.count > 1 && parts[1] == "desc")
    }

    /// The sort chip's label: "Title A to Z", "Date Added", "Random".
    var title: String {
        guard field.hasDirection, field == .title else { return field.title }
        return "Title " + (isDescending ? field.directionTitles.descending : field.directionTitles.ascending)
    }

    /// Title sorts list the library alphabetically, which is what the A–Z
    /// jump needs.
    var isTitleSort: Bool { field == .title }

    static func fields(for libraryType: LibraryKind?) -> [LibrarySortField] {
        LibrarySortField.fields(for: libraryType)
    }

    static func defaultOption(for libraryType: LibraryKind?) -> LibrarySortOption {
        libraryType == .video ? LibrarySortOption(.releaseDate) : .titleAscending
    }
}

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

    static func options(for libraryType: LibraryKind?) -> [LibraryWatchStatus] {
        libraryType == .show ? [.all, .unwatched, .watched] : allCases
    }
}

/// A field of the Filters sheet. The provider lists the ones a library
/// offers, in the sheet's order (`CatalogProviding.filterFields`). Genre has
/// its own menu and watch state its own section, so neither is a field.
struct LibraryFilterField: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Pick one of the values the provider lists for `source`, an opaque
        /// handle of the provider's (Plex: the field's values path).
        case values(source: String)
        /// On or off.
        case toggle
    }

    /// The provider's id for the field, also the key of a picked value in
    /// `LibraryFilter` (Plex: the query parameter, `decade`, `hdr`, …).
    let parameter: String
    let title: String
    let kind: Kind

    var id: String { parameter }
}

/// A value picked for a `.values` field.
struct LibraryFilterChoice: Identifiable, Hashable, Sendable {
    /// The provider's value, as `LibraryFilter.choices` sends it back. Plex's
    /// is percent-decoded here and encoded once when the query is built.
    let value: String
    let title: String

    var id: String { value }

    init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}
