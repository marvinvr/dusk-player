import Foundation
import OSLog
import SwiftUI

private let libraryRecommendationsLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "LibraryRecommendations"
)

@MainActor
@Observable
final class LibraryRecommendationsViewModel {
    private var maxRecentlyAddedItems = 10

    let library: PlexLibrary

    private(set) var hubs: [PlexHub] = []
    private(set) var personalizedShelves: [LibraryPersonalizedShelf] = []
    private(set) var channelShelves: [LibraryVideoChannelShelf] = []
    private(set) var rediscoverItems: [PlexItem] = []
    private(set) var continueWatching: [PlexItem] = []
    private(set) var continueWatchingTitle = "Continue Watching"
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var error: String?

    private let plexService: PlexService
    private let recommendationEngine: LibraryRecommendationEngine
    private let videoShelfLoader: LibraryVideoShelfLoader

    init(library: PlexLibrary, plexService: PlexService) {
        self.library = library
        self.plexService = plexService
        self.recommendationEngine = LibraryRecommendationEngine(
            library: library,
            plexService: plexService
        )
        self.videoShelfLoader = LibraryVideoShelfLoader(
            library: library,
            plexService: plexService
        )
    }

    var isVideoLibrary: Bool {
        library.libraryType == .video
    }

    var hasAnyContent: Bool {
        !hubs.isEmpty ||
        !personalizedShelves.isEmpty ||
        !channelShelves.isEmpty ||
        !rediscoverItems.isEmpty ||
        !continueWatching.isEmpty
    }

    func load(maxRecentlyAddedItems: Int? = nil) async {
        if let maxRecentlyAddedItems {
            self.maxRecentlyAddedItems = maxRecentlyAddedItems
        }

        let isInitialLoad = !hasAnyContent

        if isInitialLoad {
            isLoading = true
            error = nil
        }

        do {
            if isVideoLibrary {
                try await loadVideoLibraryContent(isInitialLoad: isInitialLoad)
            } else {
                try await loadStandardLibraryContent(isInitialLoad: isInitialLoad)
            }

            error = nil
        } catch {
            if isInitialLoad {
                self.error = error.localizedDescription
            }
        }

        hasLoadedOnce = true
        isLoading = false
    }

    /// Movie/show libraries: Plex hubs plus genre-engine personalized shelves.
    private func loadStandardLibraryContent(isInitialLoad: Bool) async throws {
        async let fetchedHubsTask = plexService.getLibraryHubs(
            sectionId: library.key,
            count: hubFetchCount
        )
        async let personalizedShelvesTask = recommendationEngine.loadResult(
            itemsPerShelf: maxRecentlyAddedItems
        )

        let fetchedHubs = try await fetchedHubsTask
        let processedHubs = try await processHubs(fetchedHubs)
        let recommendationResult = (try? await personalizedShelvesTask) ?? .empty
        let filteredPersonalizedShelves = filterPersonalizedShelves(
            recommendationResult.shelves,
            excluding: processedHubs.continueWatching
        )

        if filteredPersonalizedShelves.isEmpty {
            libraryRecommendationsLogger.debug("\(recommendationResult.diagnostics.summary, privacy: .public)")
        }

        apply(isInitialLoad: isInitialLoad) {
            self.hubs = processedHubs.hubs
            self.personalizedShelves = filteredPersonalizedShelves
            self.channelShelves = []
            self.rediscoverItems = []
            self.continueWatching = processedHubs.continueWatching
            self.continueWatchingTitle = processedHubs.continueWatchingTitle
        }
    }

    /// Video libraries skip the genre recommendation engine entirely (its
    /// history/genre scoring is expensive and meaningless for clips) and load
    /// channel rows plus a seeded Rediscover row instead.
    private func loadVideoLibraryContent(isInitialLoad: Bool) async throws {
        async let fetchedHubsTask = plexService.getLibraryHubs(
            sectionId: library.key,
            count: hubFetchCount
        )
        async let videoShelvesTask = videoShelfLoader.load()

        let fetchedHubs = try await fetchedHubsTask
        let processedHubs = try await processHubs(fetchedHubs)
        let videoShelves = await videoShelvesTask

        apply(isInitialLoad: isInitialLoad) {
            self.hubs = processedHubs.hubs
            self.personalizedShelves = []
            self.channelShelves = videoShelves.channelShelves
            self.rediscoverItems = videoShelves.rediscoverItems
            self.continueWatching = processedHubs.continueWatching
            self.continueWatchingTitle = processedHubs.continueWatchingTitle
        }
    }

    private var hubFetchCount: Int {
        max(maxRecentlyAddedItems, 12)
    }

    private func processHubs(
        _ fetchedHubs: [PlexHub]
    ) async throws -> (hubs: [PlexHub], continueWatching: [PlexItem], continueWatchingTitle: String) {
        let baseHubs = fetchedHubs.filter { !shouldHideHub($0) }
        let expandedHubs = try await expandedRecentlyAddedHubs(from: baseHubs)

        let continueWatchingHub = expandedHubs.first(where: isContinueWatchingHub)
        let recommendationHubs = expandedHubs.filter { !isContinueWatchingHub($0) }
        let continueWatchingItems = continueWatchingHub.map(visibleItems(in:)) ?? []
        let continueWatchingTitle = continueWatchingHub.map(normalizedContinueWatchingTitle(for:)) ?? "Continue Watching"

        return (recommendationHubs, continueWatchingItems, continueWatchingTitle)
    }

    private func apply(isInitialLoad: Bool, _ updates: () -> Void) {
        if isInitialLoad {
            updates()
        } else {
            withAnimation(.easeInOut(duration: 0.3), updates)
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

    func visibleItems(in hub: PlexHub) -> [PlexItem] {
        hub.items.filter { !shouldHideItem($0) }
    }

    func inlineItems(in hub: PlexHub) -> [PlexItem] {
        let items = visibleItems(in: hub)

        guard isRecentlyAddedHub(hub) else { return items }
        return Array(items.prefix(maxRecentlyAddedItems))
    }

    var prioritizedHubs: [PlexHub] {
        hubs.filter(isRecentlyAddedHub)
    }

    var secondaryHubs: [PlexHub] {
        hubs.filter { !isRecentlyAddedHub($0) }
    }

    func shouldShowAll(for hub: PlexHub) -> Bool {
        guard hub.key != nil else { return false }

        let visibleCount = visibleItems(in: hub).count

        if isRecentlyAddedHub(hub) {
            return visibleCount > maxRecentlyAddedItems ||
                hub.more == true ||
                (hub.size ?? 0) > maxRecentlyAddedItems
        }

        return hub.more == true || (hub.size ?? visibleCount) > visibleCount
    }

    func normalizedTitle(for hub: PlexHub) -> String {
        guard hub.title.lowercased().contains("recently added") else { return hub.title }

        let suffix = hub.title.replacingOccurrences(
            of: "Recently Added",
            with: "",
            options: [.caseInsensitive]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return suffix.isEmpty ? "Recently added" : "Recently added \(suffix)"
    }

    private func normalizedContinueWatchingTitle(for hub: PlexHub) -> String {
        let title = hub.title.lowercased()

        if title.contains("continue watching") || title.contains("on deck") || title.contains("in progress") || title.contains("inprogress") {
            return "Continue Watching"
        }

        return hub.title
    }

    private func expandedRecentlyAddedHubs(from hubs: [PlexHub]) async throws -> [PlexHub] {
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

    private func isContinueWatchingHub(_ hub: PlexHub) -> Bool {
        let fields = [hub.title, hub.key, hub.hubIdentifier]
            .compactMap { $0?.lowercased() }

        return fields.contains { value in
            value.contains("continue watching") ||
            value.contains("continuewatching") ||
            value.contains("on deck") ||
            value.contains("ondeck") ||
            value.contains("inprogress")
        }
    }

    private func isRecentlyAddedHub(_ hub: PlexHub) -> Bool {
        let normalizedTitle = hub.title.lowercased()

        guard normalizedTitle.contains("recently added") else { return false }

        let itemTypes = Set(visibleItems(in: hub).map(\.type))
        return !itemTypes.isEmpty && itemTypes.isSubset(of: [.movie, .show, .season, .episode, .clip])
    }

    private func shouldHideHub(_ hub: PlexHub) -> Bool {
        let fields = [hub.title, hub.key, hub.hubIdentifier]
            .compactMap { $0?.lowercased() }

        return fields.contains { value in
            value.contains("playlist") || value.contains("playlists")
        }
    }

    private func shouldHideItem(_ item: PlexItem) -> Bool {
        let normalizedKey = item.key.lowercased()

        switch item.type {
        case .artist, .album, .track, .unknown:
            return true
        default:
            return normalizedKey.contains("/playlists/")
        }
    }

    private func filterPersonalizedShelves(
        _ shelves: [LibraryPersonalizedShelf],
        excluding continueWatchingItems: [PlexItem]
    ) -> [LibraryPersonalizedShelf] {
        let excludedRatingKeys = Set(
            continueWatchingItems.flatMap { item in
                [item.ratingKey, item.parentRatingKey, item.grandparentRatingKey]
                    .compactMap { $0 }
            }
        )

        return shelves.compactMap { shelf in
            let filteredItems = shelf.items.filter { !excludedRatingKeys.contains($0.ratingKey) }

            guard filteredItems.count >= min(2, maxRecentlyAddedItems) else { return nil }

            return LibraryPersonalizedShelf(
                genre: shelf.genre,
                title: shelf.title,
                items: filteredItems
            )
        }
    }
}

private extension LibraryRecommendationLoadResult {
    static let empty = LibraryRecommendationLoadResult(
        shelves: [],
        diagnostics: LibraryRecommendationDiagnostics(
            candidateGenreCount: 0,
            historyCount: 0,
            historyGenreCount: 0,
            fallbackViewedCount: 0,
            fallbackGenreCount: 0,
            shelfCount: 0
        )
    )
}
