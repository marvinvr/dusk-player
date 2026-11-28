import Foundation

/// A Plex collection (manual or smart): its own metadata plus its titles,
/// paged in the collection's sort order or the sort picked for it (see
/// `CollectionSort`). Everything is read from the
/// collection's server.
@MainActor
@Observable
final class CollectionDetailViewModel {
    private let plexService: PlexService
    private let sortStore: CollectionSortStore
    let id: MediaItemID
    let pager: MediaItemPager

    private(set) var collection: MediaItem?
    private(set) var isLoading = false
    private(set) var error: String?
    /// `nil` is the collection's own order.
    private(set) var selectedSort: LibrarySortOption?
    /// The server ignored `sort=` on this collection, so every title is
    /// loaded and sorted here.
    private(set) var sortsOnDevice = false
    /// The sorted titles while `sortsOnDevice`; `nil` until they are loaded.
    private(set) var deviceSortedItems: [MediaItem]?

    /// What the pager sends as `sort=`; read by its fetch closure.
    @ObservationIgnored private let serverSort: ServerSort
    @ObservationIgnored private var itemsGeneration = 0

    @MainActor
    private final class ServerSort {
        var value: String?
    }

    init(id: MediaItemID, plexService: PlexService, sortStore: CollectionSortStore = CollectionSortStore()) {
        self.id = id
        self.plexService = plexService
        self.sortStore = sortStore
        let selectedSort = sortStore.sort(for: id)
        self.selectedSort = selectedSort
        let ratingKey = id.ratingKey
        let serverID = id.serverID
        let serverSort = ServerSort()
        serverSort.value = selectedSort?.plexValue
        self.serverSort = serverSort
        self.pager = MediaItemPager { [plexService] start, size in
            try await plexService.getCollectionItems(
                ratingKey: ratingKey,
                start: start,
                size: size,
                sort: serverSort.value,
                serverID: serverID
            )
        }
    }

    var serverID: String? { id.serverID }
    var items: [MediaItem] {
        guard sortsOnDevice, selectedSort != nil else { return pager.items }
        return deviceSortedItems ?? []
    }

    /// Titles are still being loaded to be sorted on the device.
    var isSortingOnDevice: Bool {
        sortsOnDevice && selectedSort != nil && deviceSortedItems == nil
    }

    var availableSortFields: [LibrarySortField] {
        CollectionSort.fields(forSubtype: collection?.subtype)
    }

    /// Only offered once there is something to reorder.
    var showsSortMenu: Bool {
        (pager.totalSize ?? collection?.childCount ?? items.count) > 1
    }

    var sortTitle: String {
        selectedSort?.title ?? CollectionSort.defaultTitle
    }

    var title: String { collection?.title ?? "" }

    var summary: String? { collection?.summary?.nilIfEmpty }

    /// Clip collections browse in 16:9 frame grabs like their library.
    var showsLandscapeItems: Bool {
        collection?.subtype == "clip" || (!items.isEmpty && items.allSatisfy(\.isClip))
    }

    /// `Smart Collection · 12 movies · 1977–2019`. The year span is only
    /// given once every title is loaded, so it never understates the range.
    var metadataLine: String? {
        guard let collection else { return nil }
        var parts = [collection.isSmartCollection ? "Smart Collection" : "Collection"]

        if let count = itemCountLabel {
            parts.append(count)
        }

        if !pager.hasMore {
            let years = items.compactMap(\.year)
            if let first = years.min(), let last = years.max() {
                parts.append(first == last ? String(first) : "\(first)–\(last)")
            }
        }

        return parts.joined(separator: " · ")
    }

    /// The collection's own count, else the server's page total. A smart
    /// collection's `childCount` can lag behind what its filter matches.
    private var itemCountLabel: String? {
        guard let collection else { return nil }
        let count = pager.totalSize ?? collection.childCount
        return count.map { MediaItem.collectionCountLabel($0, subtype: collection.subtype) }
    }

    /// Movies (and clips) can be played straight from the collection; a show
    /// collection is a shelf of shows, each with its own seasons, so it only
    /// browses.
    var isPlayable: Bool {
        !playableItems.isEmpty
    }

    private var playableItems: [MediaItem] {
        items.filter { $0.type == .movie || $0.isClip }
    }

    /// What Play starts: the title already in progress, else the first one
    /// not yet watched, else the first title.
    var nextUp: MediaItem? {
        let playable = playableItems
        return playable.first(where: \.isPartiallyWatched)
            ?? playable.first(where: { !$0.isWatched })
            ?? playable.first
    }

    var playButtonTitle: String {
        guard let nextUp else { return "Play" }
        if nextUp.isPartiallyWatched {
            return "Resume \(nextUp.title)"
        }
        return nextUp.id == playableItems.first?.id ? "Play" : "Play \(nextUp.title)"
    }

    /// The loaded titles as a list to play through (Play continues with the
    /// next title in the collection's order).
    var playThrough: PlaybackListContext? {
        PlaybackListContext(title: title, plexItems: playableItems)
    }

    /// Shuffle plays every loaded title in a random order fixed for the
    /// session, from the beginning of the first.
    func shuffledQueue() -> PlaybackQueue? {
        let items = playableItems.map(PlaybackQueueItem.init(item:))
        guard !items.isEmpty else { return nil }
        var queue = PlaybackQueue(source: .list(title: title), items: items.shuffled(), isShuffled: true)
        queue.move(to: 0)
        return queue
    }

    func load() async {
        guard collection == nil, !isLoading else { return }
        isLoading = true
        error = nil

        async let items: Void = loadItems()
        do {
            collection = try await plexService.getCollection(ratingKey: id.ratingKey, serverID: serverID)
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
        await items
        isLoading = false
    }

    /// Re-reads watch state after playback or a return to the foreground.
    func refresh() async {
        guard collection != nil else { return }
        await loadItems()
    }

    func selectSort(_ sort: LibrarySortOption?) async {
        guard sort != selectedSort else { return }
        selectedSort = sort
        sortStore.setSort(sort, for: id)
        deviceSortedItems = nil
        await loadItems()
    }

    /// The first page in the chosen order. Plex is asked to sort it; when
    /// the page shows the server ignored that, the whole collection is
    /// loaded and sorted here, and stays that way for this collection.
    private func loadItems() async {
        itemsGeneration += 1
        let generation = itemsGeneration
        let sort = selectedSort
        serverSort.value = sortsOnDevice ? nil : sort?.plexValue
        await pager.reload()
        guard generation == itemsGeneration, let sort else { return }

        if !sortsOnDevice {
            guard !CollectionSort.follows(pager.items, sort: sort) else { return }
            sortsOnDevice = true
        }
        await pager.loadRemaining()
        guard generation == itemsGeneration else { return }
        deviceSortedItems = CollectionSort.sorted(pager.items, by: sort)
    }

    func loadMoreIfNeeded(currentItem: MediaItem) async {
        await pager.loadMoreIfNeeded(currentItem: currentItem)
    }

    func setWatched(_ watched: Bool, for item: MediaItem) async {
        try? await plexService.setWatchedAcrossServers(watched, id: item.id)
        await loadItems()
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        // A collection without its own background borrows its first title's.
        let path = collection?.art ?? items.first(where: { $0.art != nil })?.art ?? collection?.thumb
        return plexService.imageURL(for: path, serverID: serverID, width: width, height: height)
    }

    func posterURL(for item: MediaItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(plexService: plexService, width: width, height: height)
    }

    func subtitle(for item: MediaItem) -> String? {
        item.standardPosterSubtitle
    }
}
