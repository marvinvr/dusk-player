import SwiftUI

/// One collection an item belongs to, with the collection's other titles.
struct DetailCollectionShelf: Identifiable, Sendable {
    let collection: MediaItem
    let items: [MediaItem]

    var id: MediaItemID { collection.id }
}

/// Loads the "Part of <collection>" rows of a movie or show detail page:
/// the collections the item's server says it is part of
/// (`MediaService.collections(containing:)`), each with its other titles.
@MainActor
@Observable
final class DetailCollectionShelvesModel {
    private(set) var shelves: [DetailCollectionShelf] = []

    @ObservationIgnored private let media: MediaService
    @ObservationIgnored private var loadedContext: String?

    /// A title in more collections than this shows only the first few.
    private static let maxShelves = 3
    private static let itemsPerShelf = 20

    init(media: MediaService) {
        self.media = media
    }

    func load(
        itemID: MediaItemID,
        sectionID: String?,
        tags: [Tag]
    ) async {
        let serverID = itemID.serverID
        let context = "\(itemID.serverID ?? "")|\(itemID.itemID)|\(tags.map(\.tag).joined(separator: ","))"
        guard context != loadedContext else { return }

        let matched: [MediaItem]
        do {
            matched = try await media.collections(containing: itemID, sectionId: sectionID, tags: tags)
        } catch {
            if !Task.isCancelled { shelves = [] }
            return
        }
        guard !matched.isEmpty else {
            if !Task.isCancelled { shelves = [] }
            return
        }

        var loaded: [DetailCollectionShelf] = []
        for collection in matched.prefix(Self.maxShelves) {
            guard let items = try? await media.getCollectionItems(
                itemID: collection.itemID,
                size: Self.itemsPerShelf + 1,
                serverID: serverID
            ).items else { continue }
            let others = items.filter { $0.id != itemID }.prefix(Self.itemsPerShelf)
            if !others.isEmpty {
                loaded.append(DetailCollectionShelf(collection: collection, items: Array(others)))
            }
        }

        guard !Task.isCancelled else { return }
        loadedContext = context
        shelves = loaded
    }
}

/// The "Part of <collection>" rows under a movie or show's detail content.
/// Each row ends in "Show All", which opens the collection page.
struct DetailCollectionShelves: View {
    let itemID: MediaItemID
    let sectionID: String?
    let tags: [Tag]
    private let media: MediaService

    @State private var model: DetailCollectionShelvesModel

    init(itemID: MediaItemID, sectionID: String?, tags: [Tag]?, media: MediaService) {
        self.itemID = itemID
        self.sectionID = sectionID
        self.tags = tags ?? []
        self.media = media
        _model = State(initialValue: DetailCollectionShelvesModel(media: media))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
            ForEach(model.shelves) { shelf in
                MediaItemPosterCarouselSection(
                    title: "Part of \(shelf.collection.title)",
                    items: shelf.items,
                    horizontalPadding: DuskPosterMetrics.detailHorizontalPadding,
                    showAllRoute: .media(type: .collection, id: shelf.collection.id),
                    subtitle: { $0.standardPosterSubtitle },
                    posterURL: { item, width, height in
                        item.posterImageURL(media: media, width: width, height: height)
                    },
                    progress: { $0.posterProgress }
                )
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
        .padding(.top, model.shelves.isEmpty ? 0 : detailSectionSpacing)
        .task(id: tags.map(\.tag).joined(separator: ",") + "|" + (sectionID ?? "")) {
            await model.load(itemID: itemID, sectionID: sectionID, tags: tags)
        }
    }
}
