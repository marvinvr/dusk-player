import Foundation

/// The neutral sorts and filters as `/Items` parameters
/// (docs/jellyfin/02-jellyfin-api-mapping.md §3, 04 §9 and §21 row 4), and the
/// Filters sheet's fields. Pure, so the mapping is tested without a server.
///
/// One base query serves the page, the count and the A–Z table: they must
/// agree, or the letter offsets point at the wrong titles.
enum JellyfinBrowseVocabulary {
    // MARK: Item types

    /// What a library of `kind` lists.
    nonisolated static func itemTypes(for kind: LibraryKind?) -> [JellyfinItemKind] {
        switch kind {
        case .movie: [.movie]
        case .show: [.series]
        case .video: [.video]
        case .photo: [.photo, .video]
        default: [.movie, .series, .video]
        }
    }

    /// The fields a grid card reads. Lists are slim unless asked (02 §0);
    /// `Genres` feeds the local genre match, the counts the show badges.
    nonisolated static let listFields: [JellyfinItemField] = [
        .providerIDs, .genres, .childCount, .recursiveItemCount, .dateCreated,
    ]

    // MARK: Base query

    /// The library listing under `filter`, without paging or sort.
    /// `collectionMembers` are the item ids of the picked collection
    /// (`choices["collection"]`), resolved by the caller: a BoxSet is
    /// server-wide, so its titles are matched inside this library by id.
    nonisolated static func baseQuery(
        libraryID: String,
        kind: LibraryKind?,
        filter: LibraryFilter,
        collectionMembers: [String]? = nil
    ) -> JellyfinItemQuery {
        var query = JellyfinItemQuery()
        query.parentID = filter.collectionID ?? libraryID
        query.recursive = true
        query.includeItemTypes = itemTypes(for: kind)
        query.fields = listFields
        if let genre = filter.genre {
            query.genres = [genre]
        }
        switch filter.watchStatus {
        case .all: break
        // A film in progress is still unwatched, as on Plex; a show is
        // watched once every episode is.
        case .unwatched: query.isPlayed = false
        case .watched: query.isPlayed = true
        case .inProgress: query.filters = [.isResumable]
        }
        // In key order, so the query (and the letter cache key) is stable.
        // Director and actor share `personIds`; picked together, director wins.
        for (parameter, value) in filter.choices.sorted(by: { $0.key < $1.key }) {
            apply(parameter: parameter, value: value, to: &query)
        }
        if let collectionMembers {
            query.ids = collectionMembers
        }
        return query
    }

    nonisolated static func apply(parameter: String, value: String, to query: inout JellyfinItemQuery) {
        switch FilterParameter(rawValue: parameter) {
        case .decade:
            if let start = Int(value) {
                query.years = Array(start...(start + 9))
            }
        case .year:
            if let year = Int(value) {
                query.years = [year]
            }
        case .contentRating:
            query.officialRatings = [value]
        case .resolution:
            switch Resolution(rawValue: value) {
            case .uhd: query.is4K = true
            case .hd:
                query.isHD = true
                query.is4K = false
            case .sd: query.isHD = false
            case nil: break
            }
        case .studio:
            query.studioIDs = [value]
        case .director:
            query.personIDs = [value]
            query.personTypes = [.director]
        case .actor:
            query.personIDs = [value]
            query.personTypes = [.actor, .guestStar]
        case .collection, nil:
            // The collection is matched by id (`collectionMembers`).
            break
        }
    }

    // MARK: Sorts

    /// Plex's sorts minus "Your Rating": Jellyfin has no numeric user rating
    /// (04 §21 row 5).
    nonisolated static func sortFields(for kind: LibraryKind?) -> [LibrarySortField] {
        LibrarySortField.fields(for: kind).filter { $0 != .userRating }
    }

    nonisolated static func sortKey(_ field: LibrarySortField) -> JellyfinSortKey {
        switch field {
        case .title: .sortName
        case .releaseDate: .premiereDate
        case .year: .productionYear
        case .addedAt: .dateCreated
        case .lastEpisodeAdded: .dateLastContentAdded
        case .userRating: .sortName
        case .criticRating: .criticRating
        case .audienceRating: .communityRating
        case .duration: .runtime
        case .lastViewed: .datePlayed
        case .random: .random
        }
    }

    /// The sort keys and one order per key. Every sort but title and random
    /// breaks ties on the sort name, so pages stay stable; nil is the
    /// title-sorted listing Plex's `/all` also defaults to.
    nonisolated static func apply(sort: LibrarySortOption?, to query: inout JellyfinItemQuery) {
        let sort = sort ?? .titleAscending
        let order: JellyfinSortOrder = sort.isDescending ? .descending : .ascending
        switch sort.field {
        case .random:
            query.sortBy = [.random]
        case .title:
            query.sortBy = [.sortName]
            query.sortOrders = [order]
        default:
            query.sortBy = [sortKey(sort.field), .sortName]
            query.sortOrders = [order, .ascending]
        }
    }

    // MARK: Filters sheet

    /// The field ids, which are also the keys of `LibraryFilter.choices`.
    enum FilterParameter: String, CaseIterable, Sendable {
        case decade, year, contentRating, resolution, studio, collection, director, actor

        var title: String {
            switch self {
            case .decade: "Decade"
            case .year: "Year"
            case .contentRating: "Content Rating"
            case .resolution: "Resolution"
            case .studio: "Studio"
            case .collection: "Collection"
            case .director: "Director"
            case .actor: "Actor"
            }
        }
    }

    /// The resolution choices: `is4K` / `isHD` are all the server filters.
    enum Resolution: String, CaseIterable, Sendable {
        case uhd = "4k"
        case hd
        case sd

        var title: String {
            switch self {
            case .uhd: "4K"
            case .hd: "HD"
            case .sd: "SD"
            }
        }
    }

    /// The sheet's fields for a library of `kind`, in Plex's order. HDR, Dolby
    /// Vision and audio language have no server filter and are not offered
    /// (04 §21 row 4); neither has resolution on a show, as on Plex.
    nonisolated static func filterParameters(for kind: LibraryKind?, includesCollection: Bool) -> [FilterParameter] {
        let all: [FilterParameter]
        switch kind {
        case .show: all = [.year, .contentRating, .studio, .collection, .director, .actor]
        case .video: all = [.decade, .year, .resolution]
        default: all = [.decade, .year, .contentRating, .resolution, .studio, .collection, .director, .actor]
        }
        return all.filter { includesCollection || $0 != .collection }
    }

    /// The opaque `.values(source:)` handle: `filterChoices(for:)` is given
    /// only the field, so the library and its kind ride along.
    struct ChoiceSource: Equatable, Sendable {
        let libraryID: String
        let kind: LibraryKind?
        let parameter: FilterParameter

        var encoded: String { [libraryID, kind?.rawValue ?? "", parameter.rawValue].joined(separator: "|") }

        init(libraryID: String, kind: LibraryKind?, parameter: FilterParameter) {
            self.libraryID = libraryID
            self.kind = kind
            self.parameter = parameter
        }

        init?(encoded: String) {
            let parts = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty, let parameter = FilterParameter(rawValue: parts[2]) else {
                return nil
            }
            self.init(libraryID: parts[0], kind: LibraryKind(rawValue: parts[1]), parameter: parameter)
        }
    }

    nonisolated static func field(_ parameter: FilterParameter, libraryID: String, kind: LibraryKind?) -> LibraryFilterField {
        LibraryFilterField(
            parameter: parameter.rawValue,
            title: parameter.title,
            kind: .values(source: ChoiceSource(libraryID: libraryID, kind: kind, parameter: parameter).encoded)
        )
    }

    /// Decades of the listed years, newest first ("2020s").
    nonisolated static func decadeChoices(years: [Int]) -> [LibraryFilterChoice] {
        Set(years.map { $0 / 10 * 10 }).sorted(by: >)
            .map { LibraryFilterChoice(value: String($0), title: "\($0)s") }
    }

    nonisolated static func yearChoices(years: [Int]) -> [LibraryFilterChoice] {
        Set(years).sorted(by: >).map { LibraryFilterChoice(value: String($0), title: String($0)) }
    }

    // MARK: A–Z

    /// The letters whose `nameLessThan` counts bound each bucket.
    nonisolated static let letters: [String] = (UnicodeScalar("A").value...UnicodeScalar("Z").value)
        .compactMap { UnicodeScalar($0).map { String(Character($0)) } }

    /// The A–Z table from `nameLessThan` counts: `below[L]` titles sort before
    /// `L`, so a letter's size is the next letter's count minus its own;
    /// numbers and symbols (`#`) are everything before "A", and "Z" keeps the
    /// rest. Exact offsets into the `SortName` listing, like Plex's
    /// `/firstCharacter` (04 §9).
    nonisolated static func letterCounts(below: [String: Int], total: Int) -> [LibraryLetterCount] {
        var rows: [LibraryLetterCount] = []
        guard let first = letters.first, let numbers = below[first] else { return [] }
        if numbers > 0 { rows.append(LibraryLetterCount(key: "#", size: numbers)) }
        for (index, letter) in letters.enumerated() {
            guard let start = below[letter] else { return [] }
            let end = index + 1 < letters.count ? below[letters[index + 1]] : total
            guard let end else { return [] }
            if end > start { rows.append(LibraryLetterCount(key: letter, size: end - start)) }
        }
        return rows
    }
}
