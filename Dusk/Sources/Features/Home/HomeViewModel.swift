import Foundation
import SwiftUI

@MainActor @Observable
final class HomeViewModel {
    private var maxRecentlyAddedItems = 10

    private(set) var hubs: [PlexHub] = []
    private(set) var personalizedShelves: [HomePersonalizedShelf] = []
    private(set) var continueWatching: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var error: String?

    private var isLoadInFlight = false
    private var loadGeneration = 0
    private var recentlyAddedExpansionTask: Task<Void, Never>?
    private var personalizedShelvesTask: Task<Void, Never>?

    private let plexService: PlexService
    private let recommendationEngine: HomeRecommendationEngine

    init(plexService: PlexService) {
        self.plexService = plexService
        self.recommendationEngine = HomeRecommendationEngine(plexService: plexService)
    }

    func load(maxRecentlyAddedItems: Int? = nil) async {
        if let maxRecentlyAddedItems {
            self.maxRecentlyAddedItems = maxRecentlyAddedItems
        }

        guard !isLoadInFlight else { return }

        isLoadInFlight = true
        loadGeneration += 1
        let generation = loadGeneration
        let currentMaxRecentlyAddedItems = self.maxRecentlyAddedItems
        recentlyAddedExpansionTask?.cancel()
        personalizedShelvesTask?.cancel()

        let isInitialLoad = hubs.isEmpty && continueWatching.isEmpty && personalizedShelves.isEmpty

        if isInitialLoad {
            isLoading = true
            error = nil
        }

        defer {
            isLoadInFlight = false
            isLoading = false
        }

        do {
            async let fetchedHubs = plexService.getHubs()
            async let fetchedOnDeck = plexService.getContinueWatching()

            let baseHubs = try await fetchedHubs.filter { !shouldHideHomeHub($0) }
            let newContinueWatching = try await fetchedOnDeck.filter { !shouldHideHomeItem($0) }
            let adjustedPersonalizedShelves = filterPersonalizedShelves(
                personalizedShelves,
                excluding: newContinueWatching,
                maxRecentlyAddedItems: currentMaxRecentlyAddedItems
            )

            if isInitialLoad {
                hubs = baseHubs
                continueWatching = newContinueWatching
                personalizedShelves = adjustedPersonalizedShelves
            } else {
                withAnimation(.easeInOut(duration: 0.3)) {
                    hubs = baseHubs
                    continueWatching = newContinueWatching
                    personalizedShelves = adjustedPersonalizedShelves
                }
            }

            error = nil
            startRecentlyAddedExpansion(
                from: baseHubs,
                generation: generation,
                maxRecentlyAddedItems: currentMaxRecentlyAddedItems
            )
            startPersonalizedShelvesLoad(
                excluding: newContinueWatching,
                generation: generation,
                maxRecentlyAddedItems: currentMaxRecentlyAddedItems
            )
        } catch {
            // On refresh, only show error if we have no existing data
            if isInitialLoad {
                self.error = error.localizedDescription
            }
        }
    }

    func setWatched(_ watched: Bool, for item: PlexItem) async {
        do {
            try await plexService.setWatched(watched, ratingKey: item.ratingKey)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeFromContinueWatching(_ item: PlexItem) async {
        // Optimistically drop the item so the hero updates immediately, then
        // reconcile with the server's refreshed Continue Watching hub.
        let removedRatingKey = item.ratingKey
        withAnimation(.easeInOut(duration: 0.3)) {
            continueWatching.removeAll { $0.ratingKey == removedRatingKey }
        }

        do {
            try await plexService.removeFromContinueWatching(ratingKey: removedRatingKey)
            await load()
        } catch {
            self.error = error.localizedDescription
            // Restore the optimistic removal if the server rejected the request.
            await load()
        }
    }

    func posterURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(plexService: plexService, width: width, height: height)
    }

    func landscapeImageURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        item.landscapeImageURL(plexService: plexService, width: width, height: height)
    }

    func progress(for item: PlexItem) -> Double? {
        item.posterProgress
    }

    func displayTitle(for item: PlexItem) -> String {
        item.continueWatchingDisplayTitle
    }

    func displaySubtitle(for item: PlexItem) -> String? {
        item.continueWatchingDisplaySubtitle
    }

    func subtitle(for item: PlexItem) -> String? {
        item.standardPosterSubtitle
    }

    func heroItems() -> [PlexItem] {
        // In-progress clips stay out of the cinematic hero rotation: their 16:9
        // frame grabs read poorly as full-bleed backdrops. They still surface in
        // the Videos tab's Continue Watching row.
        continueWatching.filter { !$0.isClip }
    }

    func heroEpisodeTitle(for item: PlexItem) -> String? {
        guard item.type == .episode else { return nil }
        return item.title == displayTitle(for: item) ? nil : item.title
    }

    func heroBackgroundURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: heroBackgroundPath(for: item), width: width, height: height)
    }

    func heroTitleLogoURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: item.clearLogo, width: width, height: height)
    }

    func heroMetadata(for item: PlexItem) -> [String] {
        var parts: [String] = []

        switch item.type {
        case .episode:
            if let label = MediaTextFormatter.seasonEpisodeLabel(
                season: item.parentIndex,
                episode: item.index
            ) {
                parts.append(label)
            }
        case .movie:
            if let year = item.year {
                parts.append(String(year))
            }
        default:
            break
        }

        if let durationText = heroDurationText(for: item) {
            parts.append(durationText)
        }

        return parts
    }

    func heroSummary(for item: PlexItem) -> String? {
        guard let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return nil
        }

        return summary
    }

    func heroProgressLabel(for item: PlexItem) -> String? {
        guard let duration = item.duration, duration > 0 else { return nil }

        if let offset = item.viewOffset, offset > 0 {
            let resume = MediaTextFormatter.playbackDuration(milliseconds: offset)
            let remaining = MediaTextFormatter.playbackDuration(
                milliseconds: max(duration - offset, 0)
            )

            switch (resume, remaining) {
            case let (resume?, remaining?) where !remaining.isEmpty:
                return "Resume from \(resume) • \(remaining) left"
            case let (resume?, _):
                return "Resume from \(resume)"
            default:
                return nil
            }
        }

        return MediaTextFormatter.playbackDuration(milliseconds: duration)
    }

    func heroPrimaryActionTitle(for item: PlexItem) -> String {
        if let offset = item.viewOffset,
           offset > 0,
           let resumeText = MediaTextFormatter.playbackDuration(milliseconds: offset) {
            return "Resume from \(resumeText)"
        }

        return "Play"
    }

    func visibleItems(in hub: PlexHub) -> [PlexItem] {
        hub.items.filter { !shouldHideHomeItem($0) }
    }

    func inlineItems(in hub: PlexHub, maxRecentlyAddedItems: Int) -> [PlexItem] {
        let items = visibleItems(in: hub)

        guard isRecentlyAddedHub(hub) else { return items }
        return Array(items.prefix(maxRecentlyAddedItems))
    }

    func shouldShowAll(for hub: PlexHub, maxRecentlyAddedItems: Int) -> Bool {
        guard isRecentlyAddedHub(hub), hub.key != nil else { return false }

        let visibleCount = visibleItems(in: hub).count
        return visibleCount > maxRecentlyAddedItems ||
            hub.more == true ||
            (hub.size ?? 0) > maxRecentlyAddedItems
    }

    /// A hub renders as a 16:9 video carousel when every visible item in it is
    /// a clip. Mixed or non-clip hubs keep the standard 2:3 poster layout.
    func isVideoHub(_ hub: PlexHub) -> Bool {
        visibleItems(in: hub).isAllClips
    }

    func isRecentlyAddedHub(_ hub: PlexHub) -> Bool {
        let normalizedTitle = hub.title.lowercased()

        guard normalizedTitle.contains("recently added") else { return false }

        let itemTypes = Set(visibleItems(in: hub).map(\.type))
        return !itemTypes.isEmpty && itemTypes.isSubset(of: [.movie, .show, .season, .episode, .clip])
    }

    func showAllRoute(for shelf: HomePersonalizedShelf) -> AppNavigationRoute? {
        guard let library = shelf.showAllLibrary else { return nil }
        return .libraryGenre(library: library, genre: shelf.genre)
    }

    private func startRecentlyAddedExpansion(
        from baseHubs: [PlexHub],
        generation: Int,
        maxRecentlyAddedItems: Int
    ) {
        guard baseHubs.contains(where: { isRecentlyAddedHub($0) && $0.key != nil }) else {
            return
        }

        recentlyAddedExpansionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let expandedHubs = try await expandedRecentlyAddedHubs(
                    from: baseHubs,
                    maxRecentlyAddedItems: maxRecentlyAddedItems
                )

                guard !Task.isCancelled, generation == loadGeneration else { return }

                withAnimation(.easeInOut(duration: 0.3)) {
                    hubs = expandedHubs
                }
            } catch {
                guard !Task.isCancelled, generation == loadGeneration else { return }
                // Keep the base hub payload visible if a follow-up expansion request fails.
            }
        }
    }

    private func startPersonalizedShelvesLoad(
        excluding continueWatchingItems: [PlexItem],
        generation: Int,
        maxRecentlyAddedItems: Int
    ) {
        personalizedShelvesTask = Task { @MainActor [weak self] in
            guard let self else { return }

            guard let loadedShelves = try? await recommendationEngine.loadShelves(
                itemsPerShelf: maxRecentlyAddedItems
            ) else {
                return
            }

            let newPersonalizedShelves = filterPersonalizedShelves(
                loadedShelves,
                excluding: continueWatchingItems,
                maxRecentlyAddedItems: maxRecentlyAddedItems
            )

            guard !Task.isCancelled, generation == loadGeneration else { return }

            withAnimation(.easeInOut(duration: 0.3)) {
                personalizedShelves = newPersonalizedShelves
            }
        }
    }

    private func expandedRecentlyAddedHubs(
        from hubs: [PlexHub],
        maxRecentlyAddedItems: Int
    ) async throws -> [PlexHub] {
        var expandedHubs: [PlexHub] = []
        expandedHubs.reserveCapacity(hubs.count)

        for hub in hubs {
            guard isRecentlyAddedHub(hub), let hubKey = hub.key else {
                expandedHubs.append(hub)
                continue
            }

            let items = try await plexService.getHubItems(
                hubKey: hubKey,
                size: maxRecentlyAddedItems
            )

            expandedHubs.append(
                PlexHub(
                    key: hub.key,
                    title: hub.title,
                    type: hub.type,
                    hubIdentifier: hub.hubIdentifier,
                    size: hub.size,
                    more: hub.more,
                    items: items
                )
            )
        }

        return expandedHubs
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

    private func filterPersonalizedShelves(
        _ shelves: [HomePersonalizedShelf],
        excluding continueWatchingItems: [PlexItem],
        maxRecentlyAddedItems: Int
    ) -> [HomePersonalizedShelf] {
        let excludedRatingKeys = Set(
            continueWatchingItems.flatMap { item in
                [item.ratingKey, item.parentRatingKey, item.grandparentRatingKey]
                    .compactMap { $0 }
            }
        )

        return shelves.compactMap { shelf in
            let filteredItems = shelf.items.filter { !excludedRatingKeys.contains($0.ratingKey) }

            guard filteredItems.count >= min(2, maxRecentlyAddedItems) else { return nil }

            return HomePersonalizedShelf(
                libraryType: shelf.libraryType,
                genre: shelf.genre,
                title: shelf.title,
                items: filteredItems,
                showAllLibrary: shelf.showAllLibrary
            )
        }
    }

    private func heroDurationText(for item: PlexItem) -> String? {
        guard let duration = item.duration, duration > 0 else { return nil }

        if let offset = item.viewOffset, offset > 0 {
            let remaining = max(duration - offset, 0)
            guard let remainingText = MediaTextFormatter.playbackDuration(milliseconds: remaining) else {
                return nil
            }
            return remaining > 0 ? "\(remainingText) left" : remainingText
        }

        return MediaTextFormatter.playbackDuration(milliseconds: duration)
    }

    private func heroBackgroundPath(for item: PlexItem) -> String? {
        switch item.type {
        case .episode:
            return item.grandparentArt ?? item.art ?? item.banner ?? item.thumb ?? item.grandparentThumb
        case .season:
            return item.art ?? item.banner ?? item.thumb ?? item.parentThumb
        default:
            return item.preferredLandscapePath
        }
    }
}
