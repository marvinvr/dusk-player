import Foundation
import SwiftUI

/// One server's answer to the two requests Home makes of it.
///
/// A server that fails both contributes nothing rather than failing Home; the
/// reason is kept so Home can still report an error when *every* server failed.
/// Declared outside the view model so it stays free of actor isolation and can
/// cross the fan-out's task boundary.
private struct HomeServerPayload: Sendable {
    let hubs: [PlexHub]
    let continueWatching: [PlexItem]
    let failure: String?
}

/// Both of Home's requests to one server, run concurrently. The server is only
/// counted as failed when neither of them came back.
private func loadHomePayload(
    _ service: PlexService,
    _ serverID: String
) async -> HomeServerPayload {
    async let hubs = loadHomeHubs(service, serverID)
    async let continueWatching = loadHomeContinueWatching(service, serverID)

    let hubsResult = await hubs
    let continueWatchingResult = await continueWatching

    let failure: String?
    switch (hubsResult, continueWatchingResult) {
    case let (.failure(error), .failure):
        failure = error.localizedDescription
    default:
        failure = nil
    }

    return HomeServerPayload(
        hubs: (try? hubsResult.get()) ?? [],
        continueWatching: (try? continueWatchingResult.get()) ?? [],
        failure: failure
    )
}

private func loadHomeHubs(
    _ service: PlexService,
    _ serverID: String
) async -> Result<[PlexHub], any Error> {
    do {
        return .success(try await service.getHubs(serverID: serverID))
    } catch {
        return .failure(error)
    }
}

private func loadHomeContinueWatching(
    _ service: PlexService,
    _ serverID: String
) async -> Result<[PlexItem], any Error> {
    do {
        return .success(try await service.getContinueWatching(serverID: serverID))
    } catch {
        return .failure(error)
    }
}

@MainActor @Observable
final class HomeViewModel {
    private var maxRecentlyAddedItems = 10
    /// Upper bound on cinematic hero slides. tvOS only — see `heroItems()`.
    private let heroItemLimit = 10

    private(set) var hubs: [PlexHub] = []
    private(set) var personalizedShelves: [HomePersonalizedShelf] = []
    private(set) var continueWatching: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var error: String?

    private var loadGeneration = 0
    private var recentlyAddedExpansionTask: Task<Void, Never>?
    private var personalizedShelvesTask: Task<Void, Never>?

    private let plexService: PlexService
    private let recommendationEngine: HomeRecommendationEngine

    init(plexService: PlexService) {
        self.plexService = plexService
        self.recommendationEngine = HomeRecommendationEngine(plexService: plexService)
    }

    /// True once Plex has returned anything Home could render.
    var hasLoadedContent: Bool {
        !hubs.isEmpty || !continueWatching.isEmpty || !personalizedShelves.isEmpty
    }

    /// Loads Home from every connected server at once.
    ///
    /// The screen is published again every time a server answers, so the box on
    /// the LAN fills Home immediately and a relayed server folds its content in
    /// when it gets there. The merge is a pure function of the per-server
    /// answers in priority order, so each republish refines the same list
    /// rather than re-deriving a different one.
    func load(maxRecentlyAddedItems: Int? = nil) async {
        if let maxRecentlyAddedItems {
            self.maxRecentlyAddedItems = maxRecentlyAddedItems
        }

        // A load already running is never a reason to skip this one: the most
        // common caller is "another server just connected", and that load has
        // already fanned out to the servers it knew about. The generation below
        // is what keeps the older one from publishing over this one — it is
        // usually a cancelled task that has not reached its next checkpoint yet.
        loadGeneration += 1
        let generation = loadGeneration
        let currentMaxRecentlyAddedItems = self.maxRecentlyAddedItems
        recentlyAddedExpansionTask?.cancel()
        personalizedShelvesTask?.cancel()

        let isInitialLoad = !hasLoadedContent

        if isInitialLoad {
            isLoading = true
            error = nil
        }

        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }

        let serverIDs = plexService.mergeServerIDs
        guard !serverIDs.isEmpty else {
            // The pool is only ever empty before the first connect pass or
            // after a sign-out / Plex Home switch, so anything still on screen
            // belongs to a session that is gone.
            hubs = []
            continueWatching = []
            personalizedShelves = []
            return
        }

        // The account's library order is a nicety, not a requirement: if it
        // cannot be read, Home keeps each server's own hub order.
        async let orderedSections = plexService.ensureLibraryOrderLoaded()

        var hubsByServer = [[PlexHub]](repeating: [], count: serverIDs.count)
        var continueWatchingByServer = [[PlexItem]](repeating: [], count: serverIDs.count)
        var answered = 0
        var latestHubs: [PlexHub] = []
        var latestContinueWatching: [PlexItem] = []

        var failureCount = 0
        var firstFailure: String?

        for await result in plexService.streamAcrossServers(loadHomePayload) {
            guard !Task.isCancelled, generation == loadGeneration else { return }

            if let failure = result.value.failure {
                failureCount += 1
                firstFailure = firstFailure ?? failure
            }

            hubsByServer[result.rank] = result.value.hubs.filter { !shouldHideHomeHub($0) }
            continueWatchingByServer[result.rank] = result.value.continueWatching
                .filter { !shouldHideHomeItem($0) }
            answered += 1

            let mergedHubs = HubMerge.merge(hubsByServer)
            let mergedContinueWatching = ContinueWatchingMerge.merge(continueWatchingByServer)
            plexService.registerAlternates(mergedHubs.alternates)
            plexService.registerAlternates(mergedContinueWatching.alternates)

            // Ordering only settles once the library order is known, but the
            // first server's rows are worth showing before that: they arrive in
            // the server's own order and are re-arranged on the next republish.
            let libraryOrder = libraryOrderIdentities()
            latestHubs = HomeHubArrangement.arrange(
                hubs: mergedHubs.hubs,
                libraryOrder: libraryOrder
            )
            latestContinueWatching = mergedContinueWatching.items

            publish(
                hubs: latestHubs,
                continueWatching: latestContinueWatching,
                maxRecentlyAddedItems: currentMaxRecentlyAddedItems,
                animated: !isInitialLoad || answered > 1
            )
            if hasLoadedContent {
                error = nil
            }
            isLoading = false
        }

        guard !Task.isCancelled, generation == loadGeneration else { return }

        // An error only when *every* server failed and there is nothing to
        // show. One failing server is reported by the partial-outage note.
        if failureCount == serverIDs.count, !hasLoadedContent {
            error = firstFailure
            return
        }

        // The order may only have landed after the last server answered.
        _ = try? await orderedSections
        let libraryOrder = libraryOrderIdentities()
        if !libraryOrder.isEmpty {
            latestHubs = HomeHubArrangement.arrange(hubs: latestHubs, libraryOrder: libraryOrder)
            publish(
                hubs: latestHubs,
                continueWatching: latestContinueWatching,
                maxRecentlyAddedItems: currentMaxRecentlyAddedItems,
                animated: !isInitialLoad
            )
        }

        startRecentlyAddedExpansion(
            from: latestHubs,
            generation: generation,
            maxRecentlyAddedItems: currentMaxRecentlyAddedItems
        )
        startPersonalizedShelvesLoad(
            excluding: latestContinueWatching,
            generation: generation,
            maxRecentlyAddedItems: currentMaxRecentlyAddedItems
        )
    }

    private func libraryOrderIdentities() -> [String] {
        plexService.libraryOrder.orderedSectionIdentities
    }

    private func publish(
        hubs newHubs: [PlexHub],
        continueWatching newContinueWatching: [PlexItem],
        maxRecentlyAddedItems: Int,
        animated: Bool
    ) {
        let adjustedShelves = filterPersonalizedShelves(
            personalizedShelves,
            excluding: newContinueWatching,
            maxRecentlyAddedItems: maxRecentlyAddedItems
        )

        let updates = {
            self.hubs = newHubs
            self.continueWatching = newContinueWatching
            self.personalizedShelves = adjustedShelves
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.3), updates)
        } else {
            updates()
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

    func removeFromContinueWatching(_ item: PlexItem) async {
        // Optimistically drop the item so the hero updates immediately, then
        // reconcile with the server's refreshed Continue Watching hub.
        let removedID = item.id
        withAnimation(.easeInOut(duration: 0.3)) {
            continueWatching.removeAll { $0.id == removedID }
        }

        // The row shows one copy of a title that may be in progress on several
        // servers. Dismissing it is a statement about the content, not about
        // that copy, so every connected copy is dismissed — otherwise the title
        // reappears from another server on the next load.
        var failure: (any Error)?
        for target in plexService.alternates.instances(of: removedID)
        where plexService.pool.connection(for: target.serverID) != nil {
            do {
                try await plexService.removeFromContinueWatching(
                    ratingKey: target.ratingKey,
                    serverID: target.serverID
                )
            } catch {
                failure = failure ?? error
            }
        }

        if let failure {
            self.error = failure.localizedDescription
        }
        // Reconcile with the servers' refreshed Continue Watching hub, which
        // also restores the optimistic removal if it was rejected.
        await load()
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
        let items = continueWatching.filter { !$0.isClip }

        #if os(tvOS)
        // The tvOS hero is full-bleed, so every backdrop is fetched and decoded
        // at the full display resolution (1920×1080) and the whole set is
        // prefetched eagerly. Cap the rotation so a long continue-watching list
        // cannot pin dozens of full-screen bitmaps in memory. iOS keeps the
        // unbounded list — its backdrops are banner-sized.
        return Array(items.prefix(heroItemLimit))
        #else
        return items
        #endif
    }

    func heroEpisodeTitle(for item: PlexItem) -> String? {
        guard item.type == .episode else { return nil }
        return item.title == displayTitle(for: item) ? nil : item.title
    }

    func heroBackgroundURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        plexService.imageURL(
            for: heroBackgroundPath(for: item),
            serverID: item.serverID,
            width: width,
            height: height
        )
    }

    func heroTitleLogoURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        plexService.imageURL(
            for: item.clearLogo,
            serverID: item.serverID,
            width: width,
            height: height
        )
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

    /// A merged row is pageable when any of its sources is, and its total size
    /// is the sum across servers — otherwise a row merged from two servers of
    /// six items each would never offer "Show All".
    func shouldShowAll(for hub: PlexHub, maxRecentlyAddedItems: Int) -> Bool {
        guard isRecentlyAddedHub(hub), hub.isPageable else { return false }

        let visibleCount = visibleItems(in: hub).count
        return visibleCount > maxRecentlyAddedItems ||
            hub.hasMoreOnAnySource ||
            hub.totalSourceSize > maxRecentlyAddedItems
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
        guard baseHubs.contains(where: { isRecentlyAddedHub($0) && $0.isPageable }) else {
            return
        }

        recentlyAddedExpansionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let expandedHubs = await expandedRecentlyAddedHubs(
                from: baseHubs,
                maxRecentlyAddedItems: maxRecentlyAddedItems
            )

            guard !Task.isCancelled, generation == loadGeneration else { return }

            withAnimation(.easeInOut(duration: 0.3)) {
                hubs = expandedHubs
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

    /// Re-fetches each Recently Added row at the size Home actually shows,
    /// following every contributing server's own hub key and re-merging. A row
    /// whose expansion comes back empty keeps the items it already had.
    private func expandedRecentlyAddedHubs(
        from hubs: [PlexHub],
        maxRecentlyAddedItems: Int
    ) async -> [PlexHub] {
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

    private func shouldHideHomeHub(_ hub: PlexHub) -> Bool {
        HomeHubFilter.shouldHide(hub: hub)
    }

    private func shouldHideHomeItem(_ item: PlexItem) -> Bool {
        HomeHubFilter.shouldHide(item: item)
    }

    /// Drops anything already in Continue Watching from the personalized rows.
    ///
    /// Matching is on `PlexItemID` (an episode's show is identified by its
    /// grandparent key *on that episode's server*, because rating keys alias
    /// across servers) plus the cross-server content key, so the same film in
    /// progress on one server is not recommended from another.
    private func filterPersonalizedShelves(
        _ shelves: [HomePersonalizedShelf],
        excluding continueWatchingItems: [PlexItem],
        maxRecentlyAddedItems: Int
    ) -> [HomePersonalizedShelf] {
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
