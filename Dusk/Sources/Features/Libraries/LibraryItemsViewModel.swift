import Foundation

struct LibraryGenreOption: Hashable, Identifiable, Sendable {
    static let all = LibraryGenreOption(title: "All Genres", value: nil)

    var id: String { value ?? "__all__" }

    let title: String
    let value: String?
}

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case titleAscending
    case titleDescending
    case yearDescending
    case yearAscending
    case releaseDateDescending
    case addedAtDescending
    case durationDescending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .titleAscending:
            "Title A-Z"
        case .titleDescending:
            "Title Z-A"
        case .yearDescending:
            "Year Newest"
        case .yearAscending:
            "Year Oldest"
        case .releaseDateDescending:
            "Release Date Newest"
        case .addedAtDescending:
            "Date Added Newest"
        case .durationDescending:
            "Duration Longest"
        }
    }

    var plexValue: String {
        switch self {
        case .titleAscending:
            "titleSort"
        case .titleDescending:
            "titleSort:desc"
        case .yearDescending:
            "year:desc"
        case .yearAscending:
            "year"
        case .releaseDateDescending:
            "originallyAvailableAt:desc"
        case .addedAtDescending:
            "addedAt:desc"
        case .durationDescending:
            "duration:desc"
        }
    }

    /// The sort choices offered for a library of the given type. Video
    /// libraries lead with upload-date sorts (year is meaningless for clips);
    /// movie/show libraries keep their original options untouched.
    static func options(for libraryType: PlexLibraryType?) -> [LibrarySortOption] {
        switch libraryType {
        case .video:
            [.releaseDateDescending, .addedAtDescending, .titleAscending, .titleDescending, .durationDescending]
        default:
            [.titleAscending, .titleDescending, .yearDescending, .yearAscending]
        }
    }

    static func defaultOption(for libraryType: PlexLibraryType?) -> LibrarySortOption {
        libraryType == .video ? .releaseDateDescending : .titleAscending
    }
}

private struct LibraryItemsQuery: Hashable {
    let genreValue: String?
    let sort: LibrarySortOption
}

@MainActor
@Observable
final class LibraryItemsViewModel {
    private let plexService: PlexService
    let library: PlexLibrary
    /// When set, every fetch is scoped to this collection (used for the
    /// per-channel grids of video libraries).
    private let collection: PlexLibraryCollection?
    private let preferredInitialGenre: LibraryGenreOption?
    private let preferLocalGenreFiltering: Bool

    private(set) var items: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private(set) var hasMoreItems = true
    private(set) var availableGenres: [LibraryGenreOption] = [.all]
    private(set) var selectedGenre: LibraryGenreOption = .all
    private(set) var selectedSort: LibrarySortOption = .titleAscending

    private let pageSize = 50
    private var hasLoadedBrowseOptions = false
    private var queryGeneration = 0
    private var genreMatchCache: [String: Bool] = [:]

    init(
        library: PlexLibrary,
        plexService: PlexService,
        collection: PlexLibraryCollection? = nil,
        initialGenre: LibraryGenreOption? = nil,
        preferLocalGenreFiltering: Bool = false
    ) {
        self.library = library
        self.plexService = plexService
        self.collection = collection
        self.preferredInitialGenre = initialGenre
        self.preferLocalGenreFiltering = preferLocalGenreFiltering
        self.selectedGenre = initialGenre ?? .all
        self.selectedSort = LibrarySortOption.defaultOption(for: library.libraryType)
    }

    var isVideoLibrary: Bool {
        library.libraryType == .video
    }

    var availableSortOptions: [LibrarySortOption] {
        LibrarySortOption.options(for: library.libraryType)
    }

    var defaultSortOption: LibrarySortOption {
        LibrarySortOption.defaultOption(for: library.libraryType)
    }

    var navigationTitle: String {
        if let collection {
            return collection.title
        }

        return selectedGenre == .all ? library.title : selectedGenre.title
    }

    var showsBrowseControls: Bool {
        !items.isEmpty || selectedGenre != .all || availableGenres.count > 1
    }

    var emptyStateTitle: String {
        guard selectedGenre == .all else { return "No matching titles" }
        return collection == nil ? "This library is empty" : "This collection is empty"
    }

    var emptyStateMessage: String? {
        guard selectedGenre != .all else { return nil }
        return "Try another genre or switch back to all titles."
    }

    func loadItems() async {
        await loadBrowseOptionsIfNeeded()

        guard items.isEmpty else { return }
        await reloadItems()
    }

    func reloadItems() async {
        let generation = beginNewQuery()
        isLoading = true
        error = nil

        do {
            let fetched = try await fetchItems(start: 0, query: currentQuery)
            guard generation == queryGeneration else { return }

            items = fetched
            hasMoreItems = fetched.count >= pageSize
        } catch {
            guard generation == queryGeneration else { return }

            items = []
            hasMoreItems = false
            self.error = error.localizedDescription
        }

        guard generation == queryGeneration else { return }
        isLoading = false
    }

    func selectGenre(_ genre: LibraryGenreOption) async {
        guard selectedGenre != genre else { return }
        selectedGenre = genre
        await reloadItems()
    }

    func selectSort(_ sort: LibrarySortOption) async {
        guard selectedSort != sort else { return }
        selectedSort = sort
        await reloadItems()
    }

    func setWatched(_ watched: Bool, for item: PlexItem) async {
        do {
            try await plexService.setWatched(watched, ratingKey: item.ratingKey)
            await reloadItems()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(currentItem: PlexItem) async {
        guard hasMoreItems, !isLoadingMore,
              let index = items.firstIndex(where: { $0.id == currentItem.id }),
              index >= items.count - 10
        else { return }

        let generation = queryGeneration
        let start = items.count
        let query = currentQuery

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let fetched = try await fetchItems(start: start, query: query)
            guard generation == queryGeneration else { return }

            items.append(contentsOf: fetched)
            hasMoreItems = fetched.count >= pageSize
        } catch {
            guard generation == queryGeneration else { return }
            hasMoreItems = false
        }
    }

    func posterURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(plexService: plexService, width: width, height: height)
    }

    func progress(for item: PlexItem) -> Double? {
        item.posterProgress
    }

    func subtitle(for item: PlexItem) -> String? {
        item.standardPosterSubtitle
    }

    private var currentQuery: LibraryItemsQuery {
        LibraryItemsQuery(genreValue: selectedGenre.value, sort: selectedSort)
    }

    private func beginNewQuery() -> Int {
        queryGeneration += 1
        hasMoreItems = true
        isLoadingMore = false
        return queryGeneration
    }

    private func fetchItems(start: Int, query: LibraryItemsQuery) async throws -> [PlexItem] {
        if query.genreValue != nil, preferLocalGenreFiltering {
            return try await fetchLocallyFilteredItems(
                start: start,
                query: query,
                genre: selectedGenre
            )
        }

        return try await fetchServerFilteredItems(start: start, query: query)
    }

    /// Filters that apply to every fetch on this screen (collection scoping).
    private var baseFilters: [String: String] {
        guard let collection else { return [:] }
        return ["collection": collection.key]
    }

    private func fetchServerFilteredItems(start: Int, query: LibraryItemsQuery) async throws -> [PlexItem] {
        var filters = baseFilters

        if let genreValue = query.genreValue {
            filters["genre"] = genreValue
        }

        return try await plexService.getLibraryItems(
            sectionId: library.key,
            start: start,
            size: pageSize,
            sort: query.sort.plexValue,
            filters: filters
        )
    }

    private func fetchLocallyFilteredItems(
        start: Int,
        query: LibraryItemsQuery,
        genre: LibraryGenreOption
    ) async throws -> [PlexItem] {
        let totalCount = try await plexService.getLibraryItemCount(
            sectionId: library.key,
            filters: baseFilters
        )
        guard totalCount > 0 else { return [] }

        var matchedItems: [PlexItem] = []
        let neededMatchCount = start + pageSize
        let serverPageSize = pageSize
        let pageCount = Int(ceil(Double(totalCount) / Double(serverPageSize)))

        guard pageCount > 0 else { return [] }

        for page in 0..<pageCount {
            let fetchedItems = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: page * serverPageSize,
                size: serverPageSize,
                sort: query.sort.plexValue,
                filters: baseFilters
            )

            guard !fetchedItems.isEmpty else { break }

            for item in fetchedItems {
                guard await itemMatchesGenre(item, genre: genre) else { continue }
                matchedItems.append(item)

                if matchedItems.count >= neededMatchCount {
                    return Array(matchedItems.dropFirst(start).prefix(pageSize))
                }
            }

            if fetchedItems.count < serverPageSize {
                break
            }
        }

        guard matchedItems.count > start else { return [] }
        return Array(matchedItems.dropFirst(start).prefix(pageSize))
    }

    private func loadBrowseOptionsIfNeeded() async {
        guard !hasLoadedBrowseOptions else { return }
        hasLoadedBrowseOptions = true

        do {
            var loadedGenres = try await LibraryGenreSupport.loadGenreOptions(
                sectionId: library.key,
                plexService: plexService
            )

            if let preferredInitialGenre,
               preferredInitialGenre != .all,
               !loadedGenres.contains(preferredInitialGenre) {
                loadedGenres.insert(preferredInitialGenre, at: min(1, loadedGenres.count))
            }

            availableGenres = loadedGenres
        } catch {
            if let preferredInitialGenre, preferredInitialGenre != .all {
                availableGenres = [.all, preferredInitialGenre]
            } else {
                availableGenres = [.all]
            }
        }
    }

    private func itemMatchesGenre(
        _ item: PlexItem,
        genre: LibraryGenreOption
    ) async -> Bool {
        let cacheKey = "\(genre.id)|\(item.ratingKey)"

        if let cached = genreMatchCache[cacheKey] {
            return cached
        }

        let matches: Bool

        if let genres = item.genres,
           LibraryGenreSupport.containsGenre(genres, matching: genre) {
            matches = true
        } else if let details = try? await plexService.getMediaDetails(ratingKey: item.ratingKey),
                  let genres = details.genres {
            matches = LibraryGenreSupport.containsGenre(genres, matching: genre)
        } else {
            matches = false
        }

        genreMatchCache[cacheKey] = matches
        return matches
    }
}
