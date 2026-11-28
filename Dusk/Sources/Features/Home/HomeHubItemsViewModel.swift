import Foundation

@MainActor
@Observable
final class HomeHubItemsViewModel {
    let hub: HomeRow

    private let media: MediaService

    private(set) var items: [MediaItem] = []
    private(set) var isLoading = false
    private(set) var error: String?

    init(hub: HomeRow, media: MediaService) {
        self.hub = hub
        self.media = media
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
        let merged = await media.mergedHubItems(for: hub)
        media.registerAlternates(merged.alternates)
        // A global row (Home's Recently Added, Continue Watching) keeps out the
        // libraries the server excludes from Home, as on Home itself. A
        // library's own row (also opened here) keeps all its titles.
        if hub.resolvedLibrarySectionID == nil {
            items = await media.loadedHiddenLibraryFilter(for: .home).filtering(merged.items)
        } else {
            items = merged.items
        }

        isLoading = false
    }

    func setWatched(_ watched: Bool, for item: MediaItem) async {
        do {
            try await media.setWatchedAcrossServers(watched, id: item.id)
            await reloadItems()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func posterURL(for item: MediaItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(media: media, width: width, height: height)
    }

    func progress(for item: MediaItem) -> Double? {
        item.posterProgress
    }

    func subtitle(for item: MediaItem) -> String? {
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

        return suffix.isEmpty ? "Recently Added" : "Recently Added \(suffix)"
    }
}
