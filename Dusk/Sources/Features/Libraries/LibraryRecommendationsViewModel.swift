import Foundation
import OSLog
import SwiftUI

private let libraryRecommendationsLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "LibraryRecommendations"
)

/// One channel row plus the library it belongs to, so "Show All" opens that
/// library's collection rather than whichever library happened to be first.
struct LibraryChannelRow: Identifiable, Sendable {
    let library: PlexLibrary
    let shelf: LibraryVideoChannelShelf

    var id: String { "\(library.id)|\(shelf.id)" }
}

/// The recommendations screen for one library **or for every library of one
/// type**, across servers.
///
/// A type tab (Movies, TV Shows, Videos) lands here with all of that type's
/// libraries: their hub rows are merged the same way Home merges `/hubs`, so
/// "Recently Added" is one row spanning both servers instead of two rows the
/// user has to compare. With a single library nothing is merged and the screen
/// behaves exactly as it did before.
@MainActor
@Observable
final class LibraryRecommendationsViewModel {
    private var maxRecentlyAddedItems = 10

    /// Every library this screen covers, in the account's order. Never empty.
    let libraries: [PlexLibrary]

    /// The library that stands in for the screen: its type drives the layout
    /// and it is what a single-library screen browses into.
    var library: PlexLibrary { libraries[0] }

    var isMultiLibrary: Bool { libraries.count > 1 }

    private(set) var hubs: [PlexHub] = []
    private(set) var personalizedShelves: [LibraryPersonalizedShelf] = []
    private(set) var channelShelves: [LibraryChannelRow] = []
    private(set) var rediscoverItems: [PlexItem] = []
    private(set) var continueWatching: [PlexItem] = []
    private(set) var continueWatchingTitle = "Continue Watching"
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var error: String?

    private let plexService: PlexService

    /// Bumped by every load. A load that is overtaken — a second server
    /// connects, or the user marks something watched mid-load — must not
    /// publish its older result over the newer one.
    private var loadGeneration = 0

    convenience init(library: PlexLibrary, plexService: PlexService) {
        self.init(libraries: [library], plexService: plexService)
    }

    init(libraries: [PlexLibrary], plexService: PlexService) {
        precondition(!libraries.isEmpty, "A recommendations screen needs at least one library")
        self.libraries = libraries
        self.plexService = plexService
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

        loadGeneration += 1
        let generation = loadGeneration
        let isInitialLoad = !hasAnyContent

        if isInitialLoad {
            isLoading = true
            error = nil
        }

        do {
            if isVideoLibrary {
                try await loadVideoLibraryContent(isInitialLoad: isInitialLoad, generation: generation)
            } else {
                try await loadStandardLibraryContent(isInitialLoad: isInitialLoad, generation: generation)
            }

            guard generation == loadGeneration else { return }
            error = nil
        } catch {
            guard generation == loadGeneration else { return }
            if isInitialLoad {
                self.error = error.localizedDescription
            }
        }

        hasLoadedOnce = true
        isLoading = false
    }

    /// Movie/show libraries: Plex hubs plus genre-engine personalized shelves.
    private func loadStandardLibraryContent(isInitialLoad: Bool, generation: Int) async throws {
        async let fetchedHubsTask = fetchLibraryHubs()
        async let personalizedShelvesTask = loadPersonalizedShelves()

        let processedHubs = await processHubs(await fetchedHubsTask)
        let recommendationResult = await personalizedShelvesTask
        let filteredPersonalizedShelves = filterPersonalizedShelves(
            recommendationResult.shelves,
            excluding: processedHubs.continueWatching
        )

        if filteredPersonalizedShelves.isEmpty {
            libraryRecommendationsLogger.debug("\(recommendationResult.diagnostics.summary, privacy: .public)")
        }

        guard generation == loadGeneration else { return }

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
    private func loadVideoLibraryContent(isInitialLoad: Bool, generation: Int) async throws {
        async let fetchedHubsTask = fetchLibraryHubs()
        async let videoShelvesTask = loadVideoShelves()

        let processedHubs = await processHubs(await fetchedHubsTask)
        let videoShelves = await videoShelvesTask

        guard generation == loadGeneration else { return }

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

    /// `/hubs/sections/{id}` for every library this screen covers, all at once,
    /// each routed to its own server. A library that fails contributes nothing
    /// rather than failing the screen.
    private func fetchLibraryHubs() async -> [[PlexHub]] {
        let service = plexService
        let count = hubFetchCount
        let libraries = self.libraries

        return await withTaskGroup(of: (Int, [PlexHub]).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    let hubs = (try? await service.getLibraryHubs(
                        sectionId: library.key,
                        count: count,
                        serverID: library.serverID
                    )) ?? []
                    return (index, hubs)
                }
            }

            var results: [(Int, [PlexHub])] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func loadPersonalizedShelves() async -> LibraryRecommendationLoadResult {
        var results: [LibraryRecommendationLoadResult] = []
        for library in libraries {
            let engine = LibraryRecommendationEngine(library: library, plexService: plexService)
            let result = (try? await engine.loadResult(itemsPerShelf: maxRecentlyAddedItems)) ?? .empty
            results.append(result)
        }
        return LibraryRecommendationLoadResult.merging(results)
    }

    private func loadVideoShelves() async -> (
        channelShelves: [LibraryChannelRow],
        rediscoverItems: [PlexItem]
    ) {
        var channelRows: [LibraryChannelRow] = []
        var rediscoverLists: [[PlexItem]] = []

        for library in libraries {
            let loader = LibraryVideoShelfLoader(library: library, plexService: plexService)
            let result = await loader.load()
            channelRows.append(
                contentsOf: result.channelShelves.map {
                    LibraryChannelRow(library: library, shelf: $0)
                }
            )
            rediscoverLists.append(result.rediscoverItems)
        }

        return (channelRows, PlexItemMerge.interleave(rediscoverLists).items)
    }

    /// Merges each library's rows into one set, then expands the Recently Added
    /// rows and splits Continue Watching out of them.
    private func processHubs(
        _ fetchedHubs: [[PlexHub]]
    ) async -> (hubs: [PlexHub], continueWatching: [PlexItem], continueWatchingTitle: String) {
        let filtered = fetchedHubs.map { $0.filter { !shouldHideHub($0) } }
        // One list per library here, not per server: merging rows of two
        // libraries of the same type is exactly what a type tab is for.
        let merged = HubMerge.merge(filtered, mode: .libraryType)
        plexService.registerAlternates(merged.alternates)

        let expandedHubs = await expandedRecentlyAddedHubs(from: merged.hubs)

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
            try await plexService.setWatchedAcrossServers(watched, id: item.id)
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

    /// A merged row is pageable when any of its libraries is, and its size is
    /// the sum across them.
    func shouldShowAll(for hub: PlexHub) -> Bool {
        guard hub.isPageable else { return false }

        let visibleCount = visibleItems(in: hub).count
        let totalSize = hub.totalSourceSize

        if isRecentlyAddedHub(hub) {
            return visibleCount > maxRecentlyAddedItems ||
                hub.hasMoreOnAnySource ||
                totalSize > maxRecentlyAddedItems
        }

        return hub.hasMoreOnAnySource || max(totalSize, visibleCount) > visibleCount
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

    /// Re-fetches each Recently Added row at the size the screen shows,
    /// following every contributing library's own hub key and re-merging.
    private func expandedRecentlyAddedHubs(from hubs: [PlexHub]) async -> [PlexHub] {
        var expandedHubs: [PlexHub] = []
        expandedHubs.reserveCapacity(hubs.count)

        for hub in hubs {
            guard isRecentlyAddedHub(hub), hub.isPageable else {
                expandedHubs.append(hub)
                continue
            }

            let merged = await plexService.mergedHubItems(
                for: hub,
                size: maxRecentlyAddedItems
            )
            guard !merged.items.isEmpty else {
                expandedHubs.append(hub)
                continue
            }

            plexService.registerAlternates(merged.alternates)
            expandedHubs.append(hub.replacingItems(merged.items))
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

    /// Drops anything already in Continue Watching. Matching is on
    /// `PlexItemID` (rating keys alias across servers) plus the cross-server
    /// content key, so a film in progress on one server is not recommended
    /// from another.
    private func filterPersonalizedShelves(
        _ shelves: [LibraryPersonalizedShelf],
        excluding continueWatchingItems: [PlexItem]
    ) -> [LibraryPersonalizedShelf] {
        var excludedIDs: Set<PlexItemID> = []
        var excludedContentKeys: Set<PlexContentKey> = []

        for item in continueWatchingItems {
            for ratingKey in [item.ratingKey, item.parentRatingKey, item.grandparentRatingKey]
                .compactMap({ $0 }) {
                excludedIDs.insert(PlexItemID(serverID: item.serverID, ratingKey: ratingKey))
            }
            excludedContentKeys.insert(item.contentKey)
        }

        return shelves.compactMap { shelf in
            let filteredItems = shelf.items.filter {
                !excludedIDs.contains($0.id) && !excludedContentKeys.contains($0.contentKey)
            }

            guard filteredItems.count >= min(2, maxRecentlyAddedItems) else { return nil }

            return LibraryPersonalizedShelf(
                genre: shelf.genre,
                title: shelf.title,
                items: filteredItems,
                showAllLibrary: shelf.showAllLibrary
            )
        }
    }
}

extension LibraryRecommendationLoadResult {
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

    /// Folds several libraries' results into one screen's worth of rows.
    ///
    /// Rows for the same genre collapse into a single row whose items are
    /// interleaved and deduplicated by content key — two libraries both
    /// offering "More Thrillers" is exactly the duplication the type tab exists
    /// to remove. A merged row loses its "Show All" link because there is no
    /// single library list behind it any more.
    static func merging(_ results: [LibraryRecommendationLoadResult]) -> LibraryRecommendationLoadResult {
        guard results.count > 1 else { return results.first ?? .empty }

        var shelvesByGenre: [String: [LibraryPersonalizedShelf]] = [:]
        var order: [String] = []

        for result in results {
            for shelf in result.shelves {
                if shelvesByGenre[shelf.id] == nil {
                    order.append(shelf.id)
                }
                shelvesByGenre[shelf.id, default: []].append(shelf)
            }
        }

        let shelves = order.compactMap { id -> LibraryPersonalizedShelf? in
            guard let group = shelvesByGenre[id], let representative = group.first else { return nil }
            guard group.count > 1 else { return representative }
            return LibraryPersonalizedShelf(
                genre: representative.genre,
                title: representative.title,
                items: PlexItemMerge.interleave(group.map(\.items)).items,
                showAllLibrary: nil
            )
        }

        return LibraryRecommendationLoadResult(
            shelves: shelves,
            diagnostics: LibraryRecommendationDiagnostics(
                candidateGenreCount: results.map(\.diagnostics.candidateGenreCount).reduce(0, +),
                historyCount: results.map(\.diagnostics.historyCount).reduce(0, +),
                historyGenreCount: results.map(\.diagnostics.historyGenreCount).reduce(0, +),
                fallbackViewedCount: results.map(\.diagnostics.fallbackViewedCount).reduce(0, +),
                fallbackGenreCount: results.map(\.diagnostics.fallbackGenreCount).reduce(0, +),
                shelfCount: shelves.count
            )
        )
    }
}
