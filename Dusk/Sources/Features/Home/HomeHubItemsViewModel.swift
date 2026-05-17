import Foundation

@MainActor
@Observable
final class HomeHubItemsViewModel {
    let hub: PlexHub

    private let plexService: PlexService

    private(set) var items: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var error: String?

    init(hub: PlexHub, plexService: PlexService) {
        self.hub = hub
        self.plexService = plexService
    }

    var navigationTitle: String {
        normalizedTitle(for: hub.title)
    }

    func loadItems() async {
        guard items.isEmpty else { return }
        await reloadItems()
    }

    func reloadItems() async {
        isLoading = true
        error = nil

        do {
            if let hubKey = hub.key {
                items = try await plexService.getHubItems(hubKey: hubKey)
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func setWatched(_ watched: Bool, for item: PlexItem) async {
        do {
            try await plexService.setWatched(watched, ratingKey: item.ratingKey)
            await reloadItems()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func posterURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(plexService: plexService, width: width, height: height)
    }

    func progress(for item: PlexItem) -> Double? {
        item.posterProgress
    }

    func subtitle(for item: PlexItem) -> String? {
        item.standardPosterSubtitle
    }

    private func normalizedTitle(for title: String) -> String {
        guard title.lowercased().contains("recently added") else { return title }

        let suffix = title.replacingOccurrences(
            of: "Recently Added",
            with: "",
            options: [.caseInsensitive]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return suffix.isEmpty ? "Recently added" : "Recently added \(suffix)"
    }
}
