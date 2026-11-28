import Foundation

/// A movie or TV library's Plex collections, manual and smart alike, paged
/// in the server's order (title).
@MainActor
@Observable
final class LibraryCollectionsViewModel {
    private let media: MediaService
    let library: Library
    var serverProductName: String { media.serverProductName(for: library.serverID) }
    let pager: MediaItemPager

    init(library: Library, media: MediaService) {
        self.library = library
        self.media = media
        let sectionID = library.key
        let serverID = library.serverID
        self.pager = MediaItemPager { [media] start, size in
            try await media.getCollections(
                sectionId: sectionID,
                start: start,
                size: size,
                serverID: serverID
            )
        }
    }

    var items: [MediaItem] { pager.items }

    var navigationTitle: String { "Collections" }

    func load() async {
        await pager.loadIfNeeded()
    }

    func reload() async {
        await pager.reload()
    }

    func loadMoreIfNeeded(currentItem: MediaItem) async {
        await pager.loadMoreIfNeeded(currentItem: currentItem)
    }

    func posterURL(for item: MediaItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(media: media, width: width, height: height)
    }

    func subtitle(for item: MediaItem) -> String? {
        item.collectionCountLabel
    }
}
