import Foundation
import TVServices

/// Principal class of the tvOS Top Shelf extension. Renders the "Continue
/// Watching" snapshot the main app writes into the shared App Group container.
///
/// The extension is intentionally dumb: it performs no networking and holds no
/// Plex auth. It reads a precomputed snapshot (self-authenticating image URLs +
/// ready-to-open `dusk://` deep links) and maps it to a sectioned shelf. The
/// system re-invokes `loadTopShelfContent` whenever the app calls
/// `TVTopShelfContentProvider.topShelfContentDidChange()`.
final class TopShelfContentProvider: TVTopShelfContentProvider {
    /// 16:9 art reads best for resumable episodes/movies, matching the system
    /// "Up Next" presentation.
    private static let imageShape: TVTopShelfSectionedItem.ImageShape = .hdtv

    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        guard let snapshot = TopShelfSnapshotStore.load(),
              !snapshot.entries.isEmpty else {
            completionHandler(nil)
            return
        }

        let items = snapshot.entries.map(Self.makeItem(from:))
        let collection = TVTopShelfItemCollection(items: items)
        collection.title = "Continue Watching"

        let content = TVTopShelfSectionedContent(sections: [collection])
        completionHandler(content)
    }

    private static func makeItem(from entry: TopShelfEntry) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: entry.ratingKey)
        item.title = entry.title
        item.imageShape = imageShape

        if let imageURLString = entry.imageURLString,
           let imageURL = URL(string: imageURLString) {
            item.setImageURL(imageURL, for: .screenScale1x)
            item.setImageURL(imageURL, for: .screenScale2x)
        }

        if let progress = entry.playbackProgress {
            item.playbackProgress = max(0, min(progress, 1))
        }

        if let actionURL = URL(string: entry.actionURLString) {
            let action = TVTopShelfAction(url: actionURL)
            // Both a plain select and the remote's Play button resume the item,
            // so "go up and start a show" works with a single click.
            item.displayAction = action
            item.playAction = action
        }

        return item
    }
}
