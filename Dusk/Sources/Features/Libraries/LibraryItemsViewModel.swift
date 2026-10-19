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

/// Remembers the last sort picked per library (`PlexLibrary.id`),
/// device-local. A stored sort the library type no longer offers falls back
/// to the type's default.
struct LibrarySortStore {
    static let keyPrefix = "librarySort."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func sort(for library: PlexLibrary) -> LibrarySortOption {
        let options = LibrarySortOption.options(for: library.libraryType)
        guard let stored = defaults.string(forKey: Self.key(forLibraryID: library.id))
            .flatMap(LibrarySortOption.init(rawValue:)),
            options.contains(stored) else {
            return LibrarySortOption.defaultOption(for: library.libraryType)
        }
        return stored
    }

    func setSort(_ sort: LibrarySortOption, for library: PlexLibrary) {
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

/// One fetched page and whether the query has more beyond it.
private struct LibraryItemsPage {
    let items: [PlexItem]
    let hasMore: Bool
    /// Locally matched genres only: the server offset the next page's scan
    /// resumes from.
    var nextScanOffset: Int?
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
    private let sortStore: LibrarySortStore

    private(set) var items: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private(set) var hasMoreItems = true
    private(set) var availableGenres: [LibraryGenreOption] = [.all]
    private(set) var selectedGenre: LibraryGenreOption = .all
    /// Remembered per library.
    private(set) var selectedSort: LibrarySortOption = .titleAscending

    /// The first page is small so it lands fast; later pages are larger
    /// because on a big library every page costs the server a section-wide
    /// query, however few items it returns.
    private let firstPageSize = 50
    private let pageSize = 100
    /// A locally matched genre scans the library in pages of this size, and at
    /// most this many pages per grid page, so a rare genre can never turn one
    /// scroll into a walk over tens of thousands of titles.
    private let localScanPageSize = 200
    private let maxLocalScanPagesPerLoad = 10
    private var hasLoadedBrowseOptions = false
    /// The genre filter values the server offered. A selected genre that is
    /// one of them is filtered by Plex; anything else is matched locally.
    private var serverGenreValues: Set<String> = []
    private var queryGeneration = 0
    private var localScanOffset = 0

    init(
        library: PlexLibrary,
        plexService: PlexService,
        collection: PlexLibraryCollection? = nil,
        initialGenre: LibraryGenreOption? = nil,
        sortStore: LibrarySortStore = LibrarySortStore()
    ) {
        self.library = library
        self.plexService = plexService
        self.collection = collection
        self.preferredInitialGenre = initialGenre
        self.selectedGenre = initialGenre ?? .all
        self.selectedSort = sortStore.sort(for: library)
        self.sortStore = sortStore
    }

    /// Every fetch on this screen is scoped to the library's own server.
    var serverID: String? { library.serverID }

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
        guard items.isEmpty else {
            await loadBrowseOptionsIfNeeded()
            return
        }

        // A preselected genre has to be matched to the server's genre filter
        // before the first page, or it would be scanned for locally. Without
        // one, the first page does not wait for the genre list.
        if selectedGenre != .all {
            await loadBrowseOptionsIfNeeded()
            await reloadItems()
        } else {
            async let browseOptions: Void = loadBrowseOptionsIfNeeded()
            await reloadItems()
            await browseOptions
        }
    }

    func reloadItems() async {
        let generation = beginNewQuery()
        isLoading = true
        error = nil

        do {
            let page = try await fetchItems(start: 0, query: currentQuery)
            guard generation == queryGeneration else { return }

            items = page.items
            hasMoreItems = page.hasMore
            localScanOffset = page.nextScanOffset ?? 0
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
        sortStore.setSort(sort, for: library)
        await reloadItems()
    }

    func setWatched(_ watched: Bool, for item: PlexItem) async {
        do {
            try await plexService.setWatchedAcrossServers(
                watched,
                id: PlexItemID(serverID: item.serverID ?? serverID, ratingKey: item.ratingKey)
            )
            await reloadItems()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(currentItem: PlexItem) async {
        // Only the tail is searched: with thousands of titles loaded, a scan
        // of the whole list on every cell appearance is main-thread work that
        // grows with the scroll. Half a page ahead keeps wide tvOS/iPad grids
        // from reaching the end before the next page lands.
        guard hasMoreItems, !isLoadingMore,
              items.suffix(pageSize / 2).contains(where: { $0.id == currentItem.id })
        else { return }

        let generation = queryGeneration
        let start = items.count
        let query = currentQuery

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await fetchItems(start: start, query: query)
            guard generation == queryGeneration else { return }

            items.append(contentsOf: page.items)
            hasMoreItems = page.hasMore
            localScanOffset = page.nextScanOffset ?? localScanOffset
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

    private func fetchItems(start: Int, query: LibraryItemsQuery) async throws -> LibraryItemsPage {
        if let genreValue = query.genreValue, !serverGenreValues.contains(genreValue) {
            return try await fetchLocallyFilteredItems(
                scanOffset: start == 0 ? 0 : localScanOffset,
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

    private func fetchServerFilteredItems(start: Int, query: LibraryItemsQuery) async throws -> LibraryItemsPage {
        var filters = baseFilters

        if let genreValue = query.genreValue {
            filters["genre"] = genreValue
        }

        let size = start == 0 ? firstPageSize : pageSize
        let items = try await plexService.getLibraryItems(
            sectionId: library.key,
            start: start,
            size: size,
            sort: query.sort.plexValue,
            filters: filters,
            serverID: serverID
        )
        return LibraryItemsPage(items: items, hasMore: items.count >= size)
    }

    /// A genre the server has no filter value for (a genre inferred from item
    /// tags): the library is scanned page by page in the chosen sort and
    /// matched on the genre tags the listing already carries, resuming where
    /// the previous page stopped.
    private func fetchLocallyFilteredItems(
        scanOffset: Int,
        query: LibraryItemsQuery,
        genre: LibraryGenreOption
    ) async throws -> LibraryItemsPage {
        let wanted = scanOffset == 0 ? firstPageSize : pageSize
        var matchedItems: [PlexItem] = []
        var offset = scanOffset

        for _ in 0..<maxLocalScanPagesPerLoad {
            let fetchedItems = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: offset,
                size: localScanPageSize,
                sort: query.sort.plexValue,
                filters: baseFilters,
                serverID: serverID
            )
            offset += fetchedItems.count

            matchedItems.append(contentsOf: fetchedItems.filter { item in
                LibraryGenreSupport.containsGenre(item.genres ?? [], matching: genre)
            })

            if fetchedItems.count < localScanPageSize {
                return LibraryItemsPage(items: matchedItems, hasMore: false, nextScanOffset: offset)
            }
            if matchedItems.count >= wanted {
                break
            }
        }

        return LibraryItemsPage(items: matchedItems, hasMore: true, nextScanOffset: offset)
    }

    private func loadBrowseOptionsIfNeeded() async {
        guard !hasLoadedBrowseOptions else { return }
        hasLoadedBrowseOptions = true

        do {
            var loadedGenres = try await LibraryGenreSupport.loadGenreOptions(
                sectionId: library.key,
                serverID: serverID,
                plexService: plexService
            )
            serverGenreValues = Set(loadedGenres.compactMap(\.value))

            // A genre handed in from a recommendation row may be an item tag
            // ("Thriller") rather than the server's filter value: resolve it to
            // the server's own option so Plex filters it.
            if selectedGenre != .all,
               let serverGenre = LibraryGenreSupport.serverOption(matching: selectedGenre, in: loadedGenres) {
                selectedGenre = serverGenre
            } else if let preferredInitialGenre,
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
}
