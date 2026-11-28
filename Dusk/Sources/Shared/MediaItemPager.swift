import Foundation

/// Paged loading for a plain Plex listing (a library's collections, a
/// collection's titles): a small first page so the screen paints fast, larger
/// pages after it, fetched as the grid nears the end of what is loaded.
@MainActor
@Observable
final class MediaItemPager {
    typealias Fetch = (_ start: Int, _ size: Int) async throws -> MediaItemPage

    private(set) var items: [MediaItem] = []
    private(set) var totalSize: Int?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoadedOnce = false
    private(set) var hasMore = true
    private(set) var error: String?

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let firstPageSize: Int
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var generation = 0

    init(firstPageSize: Int = 50, pageSize: Int = 100, fetch: @escaping Fetch) {
        self.firstPageSize = firstPageSize
        self.pageSize = pageSize
        self.fetch = fetch
    }

    /// Loads the first page, keeping what is on screen until it lands.
    func reload() async {
        generation += 1
        let current = generation
        isLoading = true
        error = nil

        do {
            let page = try await fetch(0, firstPageSize)
            guard current == generation else { return }
            items = page.items
            totalSize = page.totalSize
            hasMore = page.hasMore
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            if items.isEmpty {
                self.error = error.localizedDescription
            }
            hasMore = false
        }

        guard current == generation else { return }
        isLoading = false
        hasLoadedOnce = true
    }

    func loadIfNeeded() async {
        guard !hasLoadedOnce, !isLoading else { return }
        await reload()
    }

    /// Only the tail is checked: a scan of thousands of loaded items on every
    /// cell appearance is main-thread work that grows with the scroll.
    func loadMoreIfNeeded(currentItem: MediaItem) async {
        guard hasMore, !isLoading, !isLoadingMore,
              items.suffix(pageSize / 2).contains(where: { $0.id == currentItem.id })
        else { return }
        await loadNextPage()
    }

    /// Loads every remaining page (a list sorted on the device needs all of
    /// it).
    func loadRemaining() async {
        while hasMore, !isLoading, !isLoadingMore, !Task.isCancelled {
            let count = items.count
            await loadNextPage()
            if items.count == count { break }
        }
    }

    private func loadNextPage() async {
        guard hasMore, !isLoadingMore else { return }
        let current = generation
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await fetch(items.count, pageSize)
            guard current == generation else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            totalSize = page.totalSize ?? totalSize
            hasMore = page.hasMore && !page.items.isEmpty
        } catch {
            guard current == generation else { return }
            hasMore = false
        }
    }
}
