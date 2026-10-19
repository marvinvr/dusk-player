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

    /// The running load, owned here rather than by whichever view asked for it.
    /// See `load(maxRecentlyAddedItems:)`.
    private var loadTask: Task<Void, Never>?

    convenience init(library: PlexLibrary, plexService: PlexService) {
        self.init(libraries: [library], plexService: plexService)
    }

    init(libraries: [PlexLibrary], plexService: PlexService) {
        precondition(!libraries.isEmpty, "A recommendations screen needs at least one library")
        self.libraries = libraries
        self.plexService = plexService

        if let snapshot = LibraryRecommendationsSnapshot.cached(for: libraries, profileID: plexService.activeProfileID) {
            restore(snapshot)
        }
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

    /// The one way this screen loads: first appearance and pull-to-refresh both
    /// land here.
    ///
    /// The work runs in an unstructured task owned by the view model and this
    /// method only awaits its value, so cancelling the caller never cancels the
    /// load. `.refreshable` hands its action a task SwiftUI is free to cancel,
    /// and every fetch below swallows its error (`try?`) — a cancelled load
    /// would therefore look exactly like "every library answered with nothing"
    /// and publish a blank screen over good content.
    func load(maxRecentlyAddedItems: Int? = nil) async {
        if let maxRecentlyAddedItems {
            self.maxRecentlyAddedItems = maxRecentlyAddedItems
        }

        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performLoad(generation: generation)
        }
        loadTask = task
        await task.value
    }

    private func performLoad(generation: Int) async {
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

            guard !Task.isCancelled, generation == loadGeneration else { return }
            error = nil
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            if isInitialLoad {
                self.error = error.localizedDescription
            }
        }

        hasLoadedOnce = true
        isLoading = false
        storeSnapshot()
    }

    /// Ends the spinner as soon as there is something to show, while the
    /// slower rows are still loading.
    private func publishFirstPaint() {
        guard hasAnyContent else { return }
        hasLoadedOnce = true
        isLoading = false
    }

    /// Movie/show libraries: Plex hubs plus genre-engine personalized shelves.
    ///
    /// The hub rows are painted the moment they arrive. The personalized
    /// shelves take many section-wide queries — on a library of tens of
    /// thousands of titles that is many seconds — and are added below them
    /// when they are ready instead of holding the whole screen on a spinner.
    /// They only start once the hubs are in: on a large library the server's
    /// database is the bottleneck, and their queries would otherwise queue in
    /// front of the rows the user is waiting for.
    private func loadStandardLibraryContent(isInitialLoad: Bool, generation: Int) async throws {
        let processedHubs = await processHubs(await fetchLibraryHubs())
        guard !Task.isCancelled, generation == loadGeneration else { return }

        let hasHubContent = !processedHubs.hubs.isEmpty || !processedHubs.continueWatching.isEmpty

        // A refresh that came back with nothing is a failed refresh, not an
        // emptied library: keep what is on screen rather than blanking it.
        if isInitialLoad || hasHubContent {
            apply(isInitialLoad: isInitialLoad) {
                self.hubs = processedHubs.hubs
                self.channelShelves = []
                self.rediscoverItems = []
                self.continueWatching = processedHubs.continueWatching
                self.continueWatchingTitle = processedHubs.continueWatchingTitle
                // Shelves already on screen (a refresh) stay until their
                // replacements arrive, minus anything now in Continue Watching.
                self.personalizedShelves = self.filterPersonalizedShelves(
                    self.personalizedShelves,
                    excluding: processedHubs.continueWatching
                )
            }
            publishFirstPaint()
        }

        let recommendationResult = await loadPersonalizedShelves()
        let filteredPersonalizedShelves = filterPersonalizedShelves(
            recommendationResult.shelves,
            excluding: continueWatching
        )

        if filteredPersonalizedShelves.isEmpty {
            libraryRecommendationsLogger.debug("\(recommendationResult.diagnostics.summary, privacy: .public)")
        }

        guard !Task.isCancelled, generation == loadGeneration else { return }
        guard isInitialLoad || !filteredPersonalizedShelves.isEmpty else { return }

        // Added after first paint, so animated in rather than popping.
        apply(isInitialLoad: !hasLoadedOnce) {
            self.personalizedShelves = filteredPersonalizedShelves
        }
    }

    /// Video libraries skip the genre recommendation engine entirely (its
    /// history/genre scoring is expensive and meaningless for clips) and load
    /// channel rows plus a seeded Rediscover row instead.
    private func loadVideoLibraryContent(isInitialLoad: Bool, generation: Int) async throws {
        let processedHubs = await processHubs(await fetchLibraryHubs())
        guard !Task.isCancelled, generation == loadGeneration else { return }

        // Same rules as above: hubs paint first, the channel rows follow, and
        // an empty answer on a refresh keeps the screen.
        if isInitialLoad || !processedHubs.hubs.isEmpty || !processedHubs.continueWatching.isEmpty {
            apply(isInitialLoad: isInitialLoad) {
                self.hubs = processedHubs.hubs
                self.personalizedShelves = []
                self.continueWatching = processedHubs.continueWatching
                self.continueWatchingTitle = processedHubs.continueWatchingTitle
            }
            publishFirstPaint()
        }

        let videoShelves = await loadVideoShelves()
        guard !Task.isCancelled, generation == loadGeneration else { return }
        guard isInitialLoad
            || !videoShelves.channelShelves.isEmpty
            || !videoShelves.rediscoverItems.isEmpty else {
            return
        }

        apply(isInitialLoad: !hasLoadedOnce) {
            self.channelShelves = videoShelves.channelShelves
            self.rediscoverItems = videoShelves.rediscoverItems
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

    /// How many libraries load their rows at the same time. A type tab can
    /// cover a dozen libraries; one after another, their rows took minutes on
    /// large libraries, all at once they would swamp a server.
    private static let concurrentLibraryLoads = 3

    /// Runs `load` for every library, a few at a time, and returns the results
    /// in library order.
    private func loadPerLibrary<Result: Sendable>(
        _ load: @escaping @Sendable @MainActor (PlexLibrary) async -> Result
    ) async -> [Result] {
        let libraries = self.libraries

        return await withTaskGroup(of: (Int, Result).self) { group in
            var results: [Result?] = Array(repeating: nil, count: libraries.count)

            for (index, library) in libraries.enumerated() {
                if index >= Self.concurrentLibraryLoads, let (done, result) = await group.next() {
                    results[done] = result
                }
                group.addTask { (index, await load(library)) }
            }
            for await (index, result) in group {
                results[index] = result
            }
            return results.compactMap { $0 }
        }
    }

    private func loadPersonalizedShelves() async -> LibraryRecommendationLoadResult {
        let service = plexService
        let itemsPerShelf = maxRecentlyAddedItems
        let results = await loadPerLibrary { library in
            let engine = LibraryRecommendationEngine(library: library, plexService: service)
            return (try? await engine.loadResult(itemsPerShelf: itemsPerShelf)) ?? .empty
        }
        return LibraryRecommendationLoadResult.merging(results)
    }

    private func loadVideoShelves() async -> (
        channelShelves: [LibraryChannelRow],
        rediscoverItems: [PlexItem]
    ) {
        let service = plexService
        let results = await loadPerLibrary { library in
            (library, await LibraryVideoShelfLoader(library: library, plexService: service).load())
        }

        let channelRows = results.flatMap { library, result in
            result.channelShelves.map { LibraryChannelRow(library: library, shelf: $0) }
        }
        return (channelRows, PlexItemMerge.interleave(results.map(\.1.rediscoverItems)).items)
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

    private func storeSnapshot() {
        guard hasAnyContent else { return }
        LibraryRecommendationsSnapshot.store(
            LibraryRecommendationsSnapshot(
                hubs: hubs,
                personalizedShelves: personalizedShelves,
                channelShelves: channelShelves,
                rediscoverItems: rediscoverItems,
                continueWatching: continueWatching,
                continueWatchingTitle: continueWatchingTitle
            ),
            for: libraries,
            profileID: plexService.activeProfileID
        )
    }

    private func restore(_ snapshot: LibraryRecommendationsSnapshot) {
        hubs = snapshot.hubs
        personalizedShelves = snapshot.personalizedShelves
        channelShelves = snapshot.channelShelves
        rediscoverItems = snapshot.rediscoverItems
        continueWatching = snapshot.continueWatching
        continueWatchingTitle = snapshot.continueWatchingTitle
        hasLoadedOnce = true
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
            // The row was already fetched at `hubFetchCount`, which covers what
            // the screen shows; only a short row that has more is fetched again.
            // On a large library every hub request is a section-wide query.
            guard isRecentlyAddedHub(hub), hub.isPageable,
                  visibleItems(in: hub).count < maxRecentlyAddedItems,
                  hub.hasMoreOnAnySource else {
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

/// The last rows a recommendations screen showed, kept for the app's lifetime
/// so a screen that is rebuilt — a second server connecting re-keys the type
/// tab, a library is opened again from the list — paints at once and refreshes
/// underneath instead of starting from a spinner.
@MainActor
struct LibraryRecommendationsSnapshot {
    let hubs: [PlexHub]
    let personalizedShelves: [LibraryPersonalizedShelf]
    let channelShelves: [LibraryChannelRow]
    let rediscoverItems: [PlexItem]
    let continueWatching: [PlexItem]
    let continueWatchingTitle: String

    private static var cache: [String: LibraryRecommendationsSnapshot] = [:]

    /// Keyed on the profile as well: Continue Watching and the personalized
    /// rows belong to whoever is signed in, not to the library.
    private static func key(for libraries: [PlexLibrary], profileID: String?) -> String {
        ([profileID ?? ""] + libraries.map(\.id)).joined(separator: "|")
    }

    static func cached(for libraries: [PlexLibrary], profileID: String?) -> LibraryRecommendationsSnapshot? {
        cache[key(for: libraries, profileID: profileID)]
    }

    static func store(_ snapshot: LibraryRecommendationsSnapshot, for libraries: [PlexLibrary], profileID: String?) {
        cache[key(for: libraries, profileID: profileID)] = snapshot
    }
}
