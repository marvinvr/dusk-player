import TVServices

/// Builds the Top Shelf from the snapshot the app leaves in the App Group
/// container (`TopShelfStore`). No snapshot, or nothing in it, returns nil and
/// tvOS falls back to the app's static Top Shelf image.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        completionHandler(Self.content())
    }

    private static func content() -> (any TVTopShelfContent)? {
        guard let snapshot = TopShelfStore.loadSnapshot(),
              let imagesDirectory = TopShelfStore.imagesDirectory else {
            return nil
        }

        let sections = snapshot.sections.compactMap { section -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? in
            let items = section.items.map { item(for: $0, imagesDirectory: imagesDirectory) }
            guard !items.isEmpty else { return nil }
            let collection = TVTopShelfItemCollection(items: items)
            collection.title = section.title
            return collection
        }

        guard !sections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: sections)
    }

    private static func item(
        for entry: TopShelfSnapshot.Item,
        imagesDirectory: URL
    ) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: entry.id)
        item.title = entry.title
        item.imageShape = entry.isLandscape ? .hdtv : .poster
        if let progress = entry.progress {
            item.playbackProgress = progress
        }

        // One cached file covers both scales; it is fetched at the 2x size.
        let imageURL = imagesDirectory.appending(path: entry.imageFileName, directoryHint: .notDirectory)
        item.setImageURL(imageURL, for: .screenScale1x)
        item.setImageURL(imageURL, for: .screenScale2x)

        item.playAction = TVTopShelfAction(url: entry.playURL)
        item.displayAction = TVTopShelfAction(url: entry.displayURL)
        return item
    }
}
