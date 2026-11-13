import SwiftUI

/// One collection an item belongs to, with the collection's other titles.
struct DetailCollectionShelf: Identifiable, Sendable {
    let collection: PlexItem
    let items: [PlexItem]

    var id: PlexItemID { collection.id }
}

/// Loads the "Part of <collection>" rows of a movie or show detail page.
///
/// An item's `Collection` tags carry the collection's tag id (the collection
/// item's `index`) and title, not its rating key, so the section's collection
/// listing is read once to find the collection items behind them. Smart
/// collections never tag their titles, so they have no row here; they are
/// still browsable from the library.
@MainActor
@Observable
final class DetailCollectionShelvesModel {
    private(set) var shelves: [DetailCollectionShelf] = []

    @ObservationIgnored private let plexService: PlexService
    @ObservationIgnored private var loadedContext: String?

    /// A title in more collections than this shows only the first few.
    private static let maxShelves = 3
    private static let itemsPerShelf = 20
    /// Collections read to resolve the tags. Sections with more than this
    /// fall back to matching the tags by title within what was read.
    private static let collectionScanSize = 500

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    func load(
        itemID: PlexItemID,
        sectionID: String?,
        tags: [PlexTag]
    ) async {
        guard let sectionID, !tags.isEmpty else {
            shelves = []
            return
        }
        let serverID = itemID.serverID
        let context = "\(itemID.serverID ?? "")|\(itemID.ratingKey)|\(tags.map(\.tag).joined(separator: ","))"
        guard context != loadedContext else { return }

        guard await plexService.collectionMode(sectionId: sectionID, serverID: serverID) != .disabled,
              let page = try? await plexService.getCollections(
                  sectionId: sectionID,
                  size: Self.collectionScanSize,
                  serverID: serverID
              ) else {
            if !Task.isCancelled { shelves = [] }
            return
        }

        let matched = tags.compactMap { tag in
            page.items.first { collection in
                if let tagID = tag.id, let index = collection.index { return tagID == index }
                return collection.title.caseInsensitiveCompare(tag.tag) == .orderedSame
            }
        }

        var loaded: [DetailCollectionShelf] = []
        for collection in matched.prefix(Self.maxShelves) {
            guard let items = try? await plexService.getCollectionItems(
                ratingKey: collection.ratingKey,
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
    let itemID: PlexItemID
    let sectionID: String?
    let tags: [PlexTag]
    private let plexService: PlexService

    @State private var model: DetailCollectionShelvesModel

    init(itemID: PlexItemID, sectionID: String?, tags: [PlexTag]?, plexService: PlexService) {
        self.itemID = itemID
        self.sectionID = sectionID
        self.tags = tags ?? []
        self.plexService = plexService
        _model = State(initialValue: DetailCollectionShelvesModel(plexService: plexService))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
            ForEach(model.shelves) { shelf in
                PlexItemPosterCarouselSection(
                    title: "Part of \(shelf.collection.title)",
                    items: shelf.items,
                    horizontalPadding: DuskPosterMetrics.detailHorizontalPadding,
                    showAllRoute: .media(type: .collection, id: shelf.collection.id),
                    subtitle: { $0.standardPosterSubtitle },
                    posterURL: { item, width, height in
                        item.posterImageURL(plexService: plexService, width: width, height: height)
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
