import Foundation

/// The library grid's "Unwatched" filter: which Plex parameter narrows a
/// section to unwatched titles, and the per-library on/off choice.
///
/// Movie and video sections filter on the item itself (`unwatched=1`, so a
/// movie in progress still counts as unwatched). Show sections filter on their
/// episodes (`unwatchedLeaves=1`): a show stays listed while any episode is
/// unwatched and drops out once every episode is. These are the parameters
/// Plex's own clients send for the "Unplayed" filter.
enum LibraryUnwatchedFilter {
    static func parameterName(for libraryType: LibraryKind?) -> String {
        libraryType == .show ? "unwatchedLeaves" : "unwatched"
    }

    /// The query filters for one grid fetch: collection scoping, the
    /// unwatched filter, and (when Plex filters it) the genre.
    static func serverFilters(
        libraryType: LibraryKind?,
        collectionKey: String?,
        unwatchedOnly: Bool,
        genreValue: String?
    ) -> [String: String] {
        var filters: [String: String] = [:]
        if let collectionKey {
            filters["collection"] = collectionKey
        }
        if unwatchedOnly {
            filters[parameterName(for: libraryType)] = "1"
        }
        if let genreValue {
            filters["genre"] = genreValue
        }
        return filters
    }
}

/// Remembers the Unwatched choice per library (`Library.id`, so two
/// servers' "Movies" sections keep their own). Device-local, like every
/// other browse preference; it applies to every grid of that library
/// (all titles, a genre, a collection).
struct LibraryUnwatchedFilterStore {
    static let keyPrefix = "libraryUnwatchedOnly."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// - Parameter libraryID: `Library.id` (`"<serverID>|<key>"`).
    func isEnabled(forLibraryID libraryID: String) -> Bool {
        defaults.bool(forKey: Self.key(forLibraryID: libraryID))
    }

    func setEnabled(_ isEnabled: Bool, forLibraryID libraryID: String) {
        if isEnabled {
            defaults.set(true, forKey: Self.key(forLibraryID: libraryID))
        } else {
            defaults.removeObject(forKey: Self.key(forLibraryID: libraryID))
        }
    }

    static func key(forLibraryID libraryID: String) -> String {
        keyPrefix + libraryID
    }
}

/// Remembers the last sort picked per library (`Library.id`), device-local
/// like the Unwatched choice. A stored sort the library type no longer offers
/// falls back to the type's default.
struct LibrarySortStore {
    static let keyPrefix = "librarySort."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func sort(for library: Library) -> LibrarySortOption {
        let fields = LibrarySortOption.fields(for: library.libraryType)
        guard let stored = defaults.string(forKey: Self.key(forLibraryID: library.id))
            .flatMap(LibrarySortOption.init(rawValue:)),
            fields.contains(stored.field) else {
            return LibrarySortOption.defaultOption(for: library.libraryType)
        }
        return stored
    }

    func setSort(_ sort: LibrarySortOption, for library: Library) {
        if sort == LibrarySortOption.defaultOption(for: library.libraryType) {
            defaults.removeObject(forKey: Self.key(forLibraryID: library.id))
        } else {
            defaults.set(sort.rawValue, forKey: Self.key(forLibraryID: library.id))
        }
    }

    static func key(forLibraryID libraryID: String) -> String {
        keyPrefix + libraryID
    }
}
