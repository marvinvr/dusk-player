import Foundation

struct LibraryGenreOption: Hashable, Identifiable, Sendable {
    static let all = LibraryGenreOption(title: "All Genres", value: nil)

    var id: String { value ?? "__all__" }

    let title: String
    let value: String?
}

/// One fetched page and whether the query has more beyond it.
private struct LibraryItemsPage {
    let items: [MediaItem]
    let hasMore: Bool
    /// Locally matched genres only: the server offset the next page's scan
    /// resumes from.
    var nextScanOffset: Int?
}

private struct LibraryItemsQuery: Hashable {
    let genreValue: String?
    let sort: LibrarySortOption
    let filters: LibraryFilterState
}

@MainActor
@Observable
final class LibraryItemsViewModel {
    private let media: MediaService
    let library: Library
    /// When set, every fetch is scoped to this collection (used for the
    /// per-channel grids of video libraries).
    private let collection: MediaCollection?
    private let preferredInitialGenre: LibraryGenreOption?
    private let unwatchedFilterStore: LibraryUnwatchedFilterStore
    private let sortStore: LibrarySortStore

    private(set) var items: [MediaItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private(set) var hasMoreItems = true
    private(set) var availableGenres: [LibraryGenreOption] = [.all]
    private(set) var selectedGenre: LibraryGenreOption = .all
    /// Remembered per library, like the Unwatched filter.
    private(set) var selectedSort: LibrarySortOption = .titleAscending
    /// Remembered per library, so it also applies to the library's genre and
    /// collection grids.
    var showsUnwatchedOnly: Bool { filterState.watchStatus == .unwatched }
    /// The Filters sheet's choices plus the watch state (whose Unwatched value
    /// is remembered per library).
    private(set) var filterState: LibraryFilterState
    /// The Filters sheet's fields, as the library's server lists them.
    private(set) var availableFilterFields: [LibraryFilterField] = []
    @ObservationIgnored private var filterValueCache: [String: [LibraryFilterChoice]] = [:]
    /// Whether the library has collections to browse (and has not switched
    /// them off), which is what puts the Collections chip on the screen.
    private(set) var hasCollections = false
    /// Server offset of `items[0]`. Zero until an A–Z jump lands past the
    /// loaded titles; the grid then holds a window of the list that grows
    /// both ways as it scrolls.
    private(set) var windowStart = 0
    private(set) var isLoadingEarlier = false
    /// The A–Z jump for the current query; nil when it does not apply.
    private(set) var letterIndex: LibraryLetterIndex?
    /// Set by the grid. A window and every page prepended to it span whole
    /// rows, so a jumped-to letter starts a row and the grid never reflows
    /// sideways while scrolling up.
    @ObservationIgnored var gridColumnCount = 1

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
    private var hasLoadedCollectionInfo = false
    /// The library's Collections setting, read before the first page: with
    /// "Hide items which are in collections" the server folds a collection's
    /// titles into the collection itself, but only when asked to.
    private var collectionMode: LibraryCollectionMode?
    /// The genre filter values the server offered. A selected genre that is
    /// one of them is filtered by Plex; anything else is matched locally.
    private var serverGenreValues: Set<String> = []
    private var queryGeneration = 0
    private var jumpGeneration = 0
    private var localScanOffset = 0

    init(
        library: Library,
        media: MediaService,
        collection: MediaCollection? = nil,
        initialGenre: LibraryGenreOption? = nil,
        unwatchedFilterStore: LibraryUnwatchedFilterStore = LibraryUnwatchedFilterStore(),
        sortStore: LibrarySortStore = LibrarySortStore()
    ) {
        self.library = library
        self.media = media
        self.collection = collection
        self.preferredInitialGenre = initialGenre
        self.selectedGenre = initialGenre ?? .all
        self.selectedSort = sortStore.sort(for: library)
        self.sortStore = sortStore
        self.unwatchedFilterStore = unwatchedFilterStore
        self.filterState = LibraryFilterState(
            watchStatus: unwatchedFilterStore.isEnabled(forLibraryID: library.id) ? .unwatched : .all
        )
    }

    /// Every fetch on this screen is scoped to the library's own server.
    var serverID: String? { library.serverID }

    var isVideoLibrary: Bool {
        library.libraryType == .video
    }

    /// Movie and TV libraries have Plex collections; a video library's
    /// collections are its channels, already browsed through their own rows.
    private var supportsCollections: Bool {
        collection == nil && (library.libraryType == .movie || library.libraryType == .show)
    }

    var availableSortFields: [LibrarySortField] {
        media.librarySortFields(for: library)
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
        !items.isEmpty || selectedGenre != .all || !filterState.isEmpty || availableGenres.count > 1
            || hasCollections || !availableFilterFields.isEmpty
    }

    var emptyStateSystemImage: String {
        switch library.libraryType {
        case .video: "play.rectangle.fill"
        case .show: "tv"
        default: "film"
        }
    }

    var emptyStateTitle: String {
        if filterState.hasFieldFilters || ![.all, .unwatched].contains(filterState.watchStatus) {
            return "No matching titles"
        }
        if showsUnwatchedOnly {
            return selectedGenre == .all ? "You're all caught up" : "No unwatched titles"
        }
        guard selectedGenre == .all else { return "No matching titles" }
        return collection == nil ? "This library is empty" : "This collection is empty"
    }

    var emptyStateMessage: String? {
        if filterState.hasFieldFilters || ![.all, .unwatched].contains(filterState.watchStatus) {
            return "Try other filters, or reset them to see everything."
        }
        if showsUnwatchedOnly {
            return selectedGenre == .all
                ? "Everything here has been watched. Turn off Unwatched to see it all."
                : "Try another genre or turn off Unwatched."
        }
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
        await loadCollectionInfoIfNeeded()

        do {
            let page = try await fetchItems(start: 0, query: currentQuery)
            guard generation == queryGeneration else { return }

            items = page.items
            windowStart = 0
            hasMoreItems = page.hasMore
            localScanOffset = page.nextScanOffset ?? 0
        } catch {
            guard generation == queryGeneration else { return }

            items = []
            windowStart = 0
            hasMoreItems = false
            self.error = error.localizedDescription
        }

        guard generation == queryGeneration else { return }
        isLoading = false
        await loadLetterIndex(generation: generation, query: currentQuery)
    }

    var hasEarlierItems: Bool { windowStart > 0 }

    /// Moves the grid to the first title of `entry` and returns the item to
    /// scroll to. A letter already loaded is only scrolled to; any other
    /// replaces the grid with a window starting one page above it, so the
    /// titles just before the letter are there when scrolling up.
    func jump(to entry: LibraryLetterIndex.Entry) async -> MediaItem? {
        guard let letterIndex, let offset = letterIndex.targetOffset(for: entry) else { return nil }
        if offset >= windowStart, offset < windowStart + items.count {
            return items[offset - windowStart]
        }

        jumpGeneration += 1
        let jump = jumpGeneration
        let generation = beginNewQuery()
        let query = currentQuery
        let start = max(0, offset - rowAlignedPageSize)
        isLoading = true
        defer { if generation == queryGeneration { isLoading = false } }
        do {
            let page = try await fetchServerFilteredItems(start: start, size: offset - start + pageSize, query: query)
            guard generation == queryGeneration, jump == jumpGeneration else { return nil }
            items = page.items
            windowStart = start
            hasMoreItems = page.hasMore
            let index = offset - start
            return items.indices.contains(index) ? items[index] : items.last
        } catch {
            guard generation == queryGeneration else { return nil }
            self.error = error.localizedDescription
            return nil
        }
    }

    /// The letter the given loaded item falls under, for highlighting it.
    func letterEntry(for item: MediaItem) -> LibraryLetterIndex.Entry? {
        guard let letterIndex,
              let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        return letterIndex.entry(containing: windowStart + index)
    }

    /// After a jump, nearing the top of the window loads the rows before it.
    /// `willPrepend` runs right before they are inserted: a scroll view holds
    /// its offset when content grows above, so the grid has to shift by the
    /// inserted height or the new rows slide into view.
    func loadEarlierItems(
        whenReady: () async -> Void = {},
        willPrepend: () -> Void
    ) async {
        guard windowStart > 0, !isLoadingEarlier, !isLoading else { return }

        let generation = queryGeneration
        let start = max(0, windowStart - rowAlignedPageSize)
        let query = currentQuery
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }

        guard let page = try? await fetchServerFilteredItems(start: start, size: windowStart - start, query: query),
              generation == queryGeneration else { return }
        await whenReady()
        guard generation == queryGeneration else { return }
        // Titles that moved across the page boundary since must not repeat.
        let loaded = Set(items.map(\.id))
        willPrepend()
        items.insert(contentsOf: page.items.filter { !loaded.contains($0.id) }, at: 0)
        windowStart = start
    }

    private var rowAlignedPageSize: Int {
        let columns = max(gridColumnCount, 1)
        return max(pageSize / columns, 1) * columns
    }

    private func loadLetterIndex(generation: Int, query: LibraryItemsQuery) async {
        letterIndex = nil
        // Only the server's own filters line up with its counts: a locally
        // matched genre has no offsets to jump to.
        guard query.sort.isTitleSort, !isVideoLibrary, !items.isEmpty,
              query.genreValue.map(serverGenreValues.contains) ?? true
        else { return }

        guard let characters = try? await media.libraryLetterCounts(
            in: library,
            filter: libraryFilter(for: query, includingGenre: true)
        ), generation == queryGeneration else { return }

        let index = LibraryLetterIndex(characters: characters, descending: query.sort == .titleDescending)
        letterIndex = index.isUseful ? index : nil
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

    func setShowsUnwatchedOnly(_ unwatchedOnly: Bool) async {
        guard showsUnwatchedOnly != unwatchedOnly else { return }
        var state = filterState
        state.watchStatus = unwatchedOnly ? .unwatched : .all
        await applyFilters(state)
    }

    var watchStatusOptions: [LibraryWatchStatus] {
        LibraryWatchStatus.options(for: library.libraryType)
    }

    func applyFilters(_ state: LibraryFilterState) async {
        guard state != filterState else { return }
        if (state.watchStatus == .unwatched) != showsUnwatchedOnly {
            unwatchedFilterStore.setEnabled(state.watchStatus == .unwatched, forLibraryID: library.id)
        }
        filterState = state
        await reloadItems()
    }

    /// Clears every filter, the remembered Unwatched choice included. Genre
    /// has its own menu and stays.
    func resetFilters() async {
        await applyFilters(LibraryFilterState())
    }

    /// The values a field offers, sorted as the server lists them (Plex:
    /// decades newest first, names alphabetically). Cached for the screen.
    func filterValues(for field: LibraryFilterField) async -> [LibraryFilterChoice] {
        guard case .values = field.kind else { return [] }
        if let cached = filterValueCache[field.parameter] { return cached }
        guard let choices = try? await media.libraryFilterChoices(for: field, in: library) else {
            return []
        }
        filterValueCache[field.parameter] = choices
        return choices
    }

    func setWatched(_ watched: Bool, for item: MediaItem) async {
        do {
            try await media.setWatchedAcrossServers(
                watched,
                id: MediaItemID(serverID: item.serverID ?? serverID, itemID: item.itemID)
            )
            await reloadItems()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(currentItem: MediaItem) async {
        // Only the tail is searched: with thousands of titles loaded, a scan
        // of the whole list on every cell appearance is main-thread work that
        // grows with the scroll. Half a page ahead keeps wide tvOS/iPad grids
        // from reaching the end before the next page lands.
        guard hasMoreItems, !isLoadingMore,
              items.suffix(pageSize / 2).contains(where: { $0.id == currentItem.id })
        else { return }

        let generation = queryGeneration
        let start = windowStart + items.count
        let query = currentQuery

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await fetchItems(start: start, query: query)
            guard generation == queryGeneration else { return }

            let loaded = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !loaded.contains($0.id) })
            hasMoreItems = page.hasMore
            localScanOffset = page.nextScanOffset ?? localScanOffset
        } catch {
            guard generation == queryGeneration else { return }
            hasMoreItems = false
        }
    }

    func posterURL(for item: MediaItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(media: media, width: width, height: height)
    }

    func progress(for item: MediaItem) -> Double? {
        item.posterProgress
    }

    func subtitle(for item: MediaItem) -> String? {
        item.standardPosterSubtitle
    }

    private var currentQuery: LibraryItemsQuery {
        LibraryItemsQuery(
            genreValue: selectedGenre.value,
            sort: selectedSort,
            filters: filterState
        )
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

    /// The query's filters the server applies; the genre is left out when it
    /// is matched locally instead.
    private func libraryFilter(for query: LibraryItemsQuery, includingGenre: Bool) -> LibraryFilter {
        var filter = query.filters.libraryFilter
        filter.collectionID = collection?.key
        filter.genre = includingGenre ? query.genreValue : nil
        // Only the plain browse folds titles into their collections, like
        // Plex Web: a filtered grid lists the matching titles themselves.
        filter.foldsCollections = collectionMode == .hideItems && query.genreValue == nil && query.filters.isEmpty
        return filter
    }

    /// Reads the Collections setting and whether there is anything to browse.
    /// Both reads are cheap and the setting is cached per section, so this
    /// only costs the first open of a library a round trip.
    private func loadCollectionInfoIfNeeded() async {
        guard supportsCollections, !hasLoadedCollectionInfo else { return }

        async let mode = media.collectionMode(sectionId: library.key, serverID: serverID)
        async let firstCollection = try? media.getCollections(
            sectionId: library.key,
            size: 1,
            serverID: serverID
        )
        let resolvedMode = await mode
        collectionMode = resolvedMode
        let page = await firstCollection
        hasCollections = resolvedMode != .disabled && page?.items.isEmpty == false
        // A read cut short by a cancelled task is retried on the next load.
        hasLoadedCollectionInfo = !Task.isCancelled
    }

    private func fetchServerFilteredItems(
        start: Int,
        size requestedSize: Int? = nil,
        query: LibraryItemsQuery
    ) async throws -> LibraryItemsPage {
        let size = requestedSize ?? (start == 0 ? firstPageSize : pageSize)
        let items = try await media.libraryItems(
            in: library,
            start: start,
            size: size,
            sort: query.sort,
            filter: libraryFilter(for: query, includingGenre: true)
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
        let baseFilter = libraryFilter(for: query, includingGenre: false)
        let wanted = scanOffset == 0 ? firstPageSize : pageSize
        var matchedItems: [MediaItem] = []
        var offset = scanOffset

        for _ in 0..<maxLocalScanPagesPerLoad {
            let fetchedItems = try await media.libraryItems(
                in: library,
                start: offset,
                size: localScanPageSize,
                sort: query.sort,
                filter: baseFilter
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

        // A video library's collections are its channels, browsed through
        // their own rows; a collection grid is one already.
        async let filterFields = try? media.libraryFilterFields(in: library, includesCollection: supportsCollections)
        await loadGenreOptions()
        if let fields = await filterFields {
            availableFilterFields = fields
        }
    }

    private func loadGenreOptions() async {

        do {
            var loadedGenres = try await LibraryGenreSupport.loadGenreOptions(
                sectionId: library.key,
                serverID: serverID,
                media: media
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
