import Foundation

/// How a photo library's root is browsed: Plex's folder hierarchy, or every
/// photo in the library by date.
enum PhotoBrowseMode: String, CaseIterable, Identifiable {
    case albums
    case timeline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .albums: "Albums"
        case .timeline: "Timeline"
        }
    }
}

/// One photo grid: a library root (albums or timeline) or an album.
///
/// A grid is a sequence of paged queries walked in order: an album level lists
/// its sub-albums first and then its photos, the timeline is a single query.
/// Nothing is ever loaded beyond what the scroll reaches, so a library of tens
/// of thousands of photos costs one page per screenful.
@MainActor
@Observable
final class PhotoBrowserViewModel {
    private let media: MediaService
    let library: Library
    let album: PhotoAlbumRoute?

    private(set) var mode: PhotoBrowseMode
    private(set) var albums: [PhotoItem] = []
    /// Photos and clips, in grid order. The viewer pages through this list.
    private(set) var items: [PhotoItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?

    private var stages: [PhotoQuery] = []
    private var stageIndex = 0
    private var stageOffset = 0
    private var generation = 0

    /// The first page is small so the grid paints fast; later pages are larger
    /// because each costs the server a section query however few rows it returns.
    private let firstPageSize = 60
    private let pageSize = 150

    init(library: Library, album: PhotoAlbumRoute? = nil, media: MediaService) {
        self.library = library
        self.album = album
        self.media = media
        mode = album == nil
            ? UserDefaults.standard.string(forKey: Self.modeKey(for: library))
                .flatMap(PhotoBrowseMode.init(rawValue:)) ?? .albums
            : .albums
    }

    var navigationTitle: String {
        album?.title ?? library.title
    }

    /// Only a library root offers Albums / Timeline.
    var showsModePicker: Bool {
        album == nil
    }

    var hasMore: Bool {
        stageIndex < stages.count
    }

    var isEmpty: Bool {
        albums.isEmpty && items.isEmpty
    }

    var emptyStateTitle: String {
        album == nil ? "This library is empty" : "This album is empty"
    }

    /// Photos only; clips are skipped by the slideshow.
    var hasPhotos: Bool {
        items.contains { $0.kind == .photo }
    }

    func loadIfNeeded() async {
        guard isEmpty, !isLoading else { return }
        await reload()
    }

    func selectMode(_ newMode: PhotoBrowseMode) async {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey(for: library))
        await reload()
    }

    func reload() async {
        generation += 1
        let currentGeneration = generation
        stages = makeStages()
        stageIndex = 0
        stageOffset = 0
        albums = []
        items = []
        error = nil
        isLoading = true
        defer {
            if currentGeneration == generation { isLoading = false }
        }

        do {
            // Keep going while the grid would have no photos to show and the
            // albums so far fit on one screen: an album level whose few
            // sub-albums come back in one page also shows its first photos.
            repeat {
                try await loadNextPage(generation: currentGeneration, size: firstPageSize)
            } while currentGeneration == generation && hasMore && items.isEmpty && albums.count < firstPageSize
        } catch {
            guard currentGeneration == generation else { return }
            self.error = error.localizedDescription
        }
    }

    /// Called as cells appear; only the tail of the list being filled counts.
    func loadMoreIfNeeded(currentItem: PhotoItem) async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let tail = items.isEmpty ? albums.suffix(30) : items.suffix(60)
        guard tail.contains(where: { $0.id == currentItem.id }) else { return }
        await loadMore()
    }

    /// The viewer asks for more as it nears the end of what is loaded.
    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let currentGeneration = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        // A failed page ends the walk rather than retrying on every cell.
        do {
            try await loadNextPage(generation: currentGeneration, size: pageSize)
        } catch {
            guard currentGeneration == generation else { return }
            stageIndex = stages.count
        }
    }

    func thumbnailURL(for item: PhotoItem, side: CGFloat) -> URL? {
        media.photoThumbnailURL(for: item, side: Int(side.rounded(.up)))
    }

    func route(for albumItem: PhotoItem) -> AppNavigationRoute {
        .photoAlbum(PhotoAlbumRoute(library: library, itemID: albumItem.itemID, title: albumItem.title))
    }

    // MARK: - Paging

    private func makeStages() -> [PhotoQuery] {
        if let album {
            return [.albums(parent: album.itemID), .media(parent: album.itemID)]
        }
        switch mode {
        case .albums: return [.albums(parent: nil), .media(parent: nil)]
        case .timeline: return [.timeline]
        }
    }

    private func loadNextPage(generation currentGeneration: Int, size: Int) async throws {
        guard hasMore else { return }
        let query = stages[stageIndex]
        let page = try await media.getPhotoItems(
            sectionId: library.key,
            query: query,
            start: stageOffset,
            size: size,
            serverID: library.serverID
        )
        guard currentGeneration == generation else { return }

        if case .albums = query {
            albums.append(contentsOf: page.items.filter(\.isAlbum))
        } else {
            items.append(contentsOf: page.items.filter { !$0.isAlbum })
        }

        stageOffset += size
        let isExhausted = page.items.isEmpty
            || page.totalSize.map { stageOffset >= $0 } ?? (page.items.count < size)
        if isExhausted {
            stageIndex += 1
            stageOffset = 0
        }
    }

    private static func modeKey(for library: Library) -> String {
        "photoBrowseMode.\(library.id)"
    }
}
