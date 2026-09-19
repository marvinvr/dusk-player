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

    /// Pages the row on **every** server that contributed to it and re-merges,
    /// so "Show All" on a merged row is the full row rather than the primary
    /// server's share of it.
    func reloadItems() async {
        isLoading = true
        error = nil

        // A source that fails contributes nothing rather than failing the page:
        // one unreachable server must not hide the other's half of the row.
        let merged = await plexService.mergedHubItems(for: hub)
        plexService.registerAlternates(merged.alternates)
        items = merged.items

        isLoading = false
    }

    func setWatched(_ watched: Bool, for item: PlexItem) async {
        do {
            try await plexService.setWatchedAcrossServers(watched, id: item.id)
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
