import Foundation

@MainActor
@Observable
final class LibraryItemsViewModel {
    private let plexService: PlexService
    let library: PlexLibrary

    private(set) var items: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private(set) var hasMoreItems = true

    private let pageSize = 50

    init(library: PlexLibrary, plexService: PlexService) {
        self.library = library
        self.plexService = plexService
    }

    func loadItems() async {
        guard items.isEmpty else { return }
        isLoading = true
        error = nil
        do {
            let fetched = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: 0,
                size: pageSize
            )
            items = fetched
            hasMoreItems = fetched.count >= pageSize
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadMoreIfNeeded(currentItem: PlexItem) async {
        guard hasMoreItems, !isLoadingMore,
              let index = items.firstIndex(where: { $0.id == currentItem.id }),
              index >= items.count - 10
        else { return }

        isLoadingMore = true
        do {
            let fetched = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: items.count,
                size: pageSize
            )
            items.append(contentsOf: fetched)
            hasMoreItems = fetched.count >= pageSize
        } catch {
            // Silently ignore pagination errors — user can scroll again to retry
        }
        isLoadingMore = false
    }

    func posterURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: item.preferredPosterPath, width: width, height: height)
    }

    func progress(for item: PlexItem) -> Double? {
        guard let offset = item.viewOffset, offset > 0,
              let duration = item.duration, duration > 0
        else { return nil }
        return Double(offset) / Double(duration)
    }

    func subtitle(for item: PlexItem) -> String? {
        switch item.type {
        case .movie:
            return item.year.map(String.init)
        case .show:
            if let childCount = item.childCount {
                return "\(childCount) season\(childCount == 1 ? "" : "s")"
            }
            return item.year.map(String.init)
        default:
            return item.year.map(String.init)
        }
    }
}
