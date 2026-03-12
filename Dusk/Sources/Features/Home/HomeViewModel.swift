import Foundation

@MainActor @Observable
final class HomeViewModel {
    private(set) var hubs: [PlexHub] = []
    private(set) var continueWatching: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var error: String?

    private let plexService: PlexService

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    func load() async {
        isLoading = true
        error = nil

        do {
            async let fetchedHubs = plexService.getHubs()
            async let fetchedOnDeck = plexService.getContinueWatching()

            hubs = try await fetchedHubs.filter { !shouldHideHomeHub($0) }
            continueWatching = try await fetchedOnDeck.filter { !shouldHideHomeItem($0) }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Resolve the best poster URL for an item.
    func posterURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: item.preferredPosterPath, width: width, height: height)
    }

    /// Resolve the best landscape artwork URL for continue watching cards.
    func landscapeImageURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: item.preferredLandscapePath, width: width, height: height)
    }

    /// Progress fraction (0–1) for partially watched items. Nil if unwatched.
    func progress(for item: PlexItem) -> Double? {
        guard let offset = item.viewOffset, offset > 0,
              let duration = item.duration, duration > 0 else { return nil }
        return Double(offset) / Double(duration)
    }

    /// Display title for continue watching items.
    /// Episodes show the series title; movies just show the title.
    func displayTitle(for item: PlexItem) -> String {
        if item.type == .episode, let show = item.grandparentTitle {
            return show
        }
        return item.title
    }

    /// Subtitle for continue watching: natural-language episode label or year.
    func displaySubtitle(for item: PlexItem) -> String? {
        if item.type == .episode {
            return formatEpisode(season: item.parentIndex, episode: item.index) ?? item.title
        }
        return item.year.map(String.init)
    }

    func visibleItems(in hub: PlexHub) -> [PlexItem] {
        hub.items.filter { !shouldHideHomeItem($0) }
    }

    private func formatEpisode(season: Int?, episode: Int?) -> String? {
        switch (season, episode) {
        case let (s?, e?):
            return "Season \(s) · Episode \(e)"
        case let (nil, e?):
            return "Episode \(e)"
        default:
            return nil
        }
    }

    private func shouldHideHomeHub(_ hub: PlexHub) -> Bool {
        let fields = [hub.title, hub.key, hub.hubIdentifier]
            .compactMap { $0?.lowercased() }

        return fields.contains(where: { value in
            value.contains("continue watching") ||
            value.contains("continuewatching") ||
            value.contains("on deck") ||
            value.contains("ondeck") ||
            value.contains("playlist") ||
            value.contains("playlists")
        })
    }

    private func shouldHideHomeItem(_ item: PlexItem) -> Bool {
        let normalizedKey = item.key.lowercased()

        switch item.type {
        case .artist, .album, .track, .unknown:
            return true
        default:
            return normalizedKey.contains("/playlists/")
        }
    }
}
