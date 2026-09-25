import Foundation
import SwiftUI

/// One server's answer to the two requests Home makes of it.
///
/// A server that fails both contributes nothing rather than failing Home; the
/// reason is kept so Home can still report an error when *every* server failed.
/// Declared outside the view model so it stays free of actor isolation and can
/// cross the fan-out's task boundary.
///
/// `nil` is "this request failed", which is deliberately not the same as an
/// empty list: a server that times out during a refresh keeps the rows it last
/// gave Home instead of dropping out of the merge for that run.
private struct HomeServerPayload: Sendable {
    let hubs: [PlexHub]?
    let continueWatching: [PlexItem]?
    let failure: String?

    /// Fills in whatever this answer is missing from the server's previous one.
    /// A server that has actually left the pool has no previous answer to keep:
    /// `HomeViewModel` forgets it before the merge.
    func merged(onto previous: HomeServerPayload?) -> HomeServerPayload {
        HomeServerPayload(
            hubs: hubs ?? previous?.hubs,
            continueWatching: continueWatching ?? previous?.continueWatching,
            failure: failure
        )
    }

    /// Something Home would render: a row it does not hide, or an item in
    /// Continue Watching.
    var hasVisibleContent: Bool {
        hubs?.contains { !HomeHubFilter.shouldHide(hub: $0) } == true
            || continueWatching?.contains { !HomeHubFilter.shouldHide(item: $0) } == true
    }

    /// Something the cinematic hero would show (`HomeViewModel.heroItems()`).
    /// Its arrival is what reshapes Home, so the first paint waits for it.
    var hasHeroItem: Bool {
        continueWatching?.contains { !HomeHubFilter.shouldHide(item: $0) && !$0.isClip } == true
    }
}

/// Everything Home's load loop reacts to while it merges.
private enum HomeLoadEvent: Sendable {
    case answer(ServerResult<HomeServerPayload>)
    case answersFinished
    case orderSettled
    case firstPaintDeadline
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
        hubs: try? hubsResult.get(),
        continueWatching: try? continueWatchingResult.get(),
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
    /// The running load, owned here instead of by whichever view asked for it.
    /// See `load(maxRecentlyAddedItems:)`.
    private var loadTask: Task<Void, Never>?
    /// The last answer each connected server gave. A refresh where one server
    /// times out reuses its entry rather than merging an empty list for it,
    /// which would make that server's rows blink out and back.
    private var lastPayloads: [String: HomeServerPayload] = [:]
    /// The Plex Home profile `lastPayloads` belongs to. A profile switch leaves
    /// the same servers connected, so the server list alone cannot tell whose
    /// content is being kept.
    private var lastPayloadsProfileID: String?
    /// Set while Home is holding its first paint back. Kept across loads so a
    /// server connecting mid-wait does not restart the clock.
    private var firstPaintGate: HomeFirstPaintGate?
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

    /// The one way Home loads: first mount, tab return, scene activation,
    /// player dismissal and pull-to-refresh all land here.
    ///
    /// The work runs in an **unstructured task owned by the view model** and
    /// this method only awaits its value. Cancelling the caller therefore never
    /// cancels the load: `.refreshable` hands its action a task SwiftUI is free
    /// to cancel (a body rebuild, the refresh control going away), and a load
    /// cut off half way would leave Home showing the merge of whichever servers
    /// happened to answer first. Awaiting the value still keeps the pull-to-
    /// refresh spinner up until the merged screen is actually on screen.
    ///
    /// A load already running is never a reason to skip this one: the most
    /// common caller is "another server just connected", and that load has
    /// already fanned out to the servers it knew about. It is superseded rather
    /// than joined, and the generation is what keeps it from publishing over
    /// this one.
    func load(maxRecentlyAddedItems: Int? = nil) async {
        if let maxRecentlyAddedItems {
            self.maxRecentlyAddedItems = maxRecentlyAddedItems
        }

        loadGeneration += 1
        let generation = loadGeneration
        let currentMaxRecentlyAddedItems = self.maxRecentlyAddedItems
        recentlyAddedExpansionTask?.cancel()
        personalizedShelvesTask?.cancel()
        loadTask?.cancel()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performLoad(
                generation: generation,
                maxRecentlyAddedItems: currentMaxRecentlyAddedItems
            )
        }
        loadTask = task
        await task.value
    }

    /// Loads Home from every connected server at once.
    ///
    /// **First load.** Nothing is on screen yet, so the first paint is held back
    /// by `HomeFirstPaintGate` until the merge is unlikely to change shape: a
    /// short grace for the other servers and the library order to catch up,
    /// longer only while a server that had Continue Watching last time is still
    /// missing, never longer than the gate's cap. The loading view stays up in
    /// the meantime. After that paint, whatever is still outstanding folds in
    /// as it lands.
    ///
    /// **Any later load** — a tab return, a pull-to-refresh, another server
    /// connecting — publishes the merge in one go once every server has
    /// answered: a merge missing the servers that have not answered yet is a
    /// smaller screen than the one already there, and swapping between the two
    /// is what made refreshing look like content jumping between servers.
    ///
    /// Either way the merge is a pure function of the per-server answers in
    /// priority order, so each publish refines the same list rather than
    /// re-deriving a different one.
    private func performLoad(generation: Int, maxRecentlyAddedItems currentMaxRecentlyAddedItems: Int) async {
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
            lastPayloads = [:]
            firstPaintGate = nil
            hubs = []
            continueWatching = []
            personalizedShelves = []
            return
        }

        // Whatever a server that has left the pool contributed goes with it;
        // only a server still in the pool, for the profile that fetched it, may
        // keep its last answer.
        let profileID = plexService.activeProfileID
        if profileID != lastPayloadsProfileID {
            lastPayloads = [:]
            lastPayloadsProfileID = profileID
            firstPaintGate = nil
        }
        lastPayloads = lastPayloads.filter { serverIDs.contains($0.key) }

        // The gate outlives a load that another server's connect supersedes, so
        // the cap counts from when Home started waiting, not from this load.
        var gate: HomeFirstPaintGate?
        var rememberedHeroServerIDs: Set<String> = []
        if isInitialLoad {
            let firstPaintGate = firstPaintGate ?? HomeFirstPaintGate(startedAt: .now)
            self.firstPaintGate = firstPaintGate
            gate = firstPaintGate
            rememberedHeroServerIDs = HomeContinueWatchingMemory.serverIDs(profileID: profileID)
        }

        // One loop reacts to everything the first paint depends on: each
        // server's answer, the library order, and the gate's deadline.
        let (events, eventSink) = AsyncStream.makeStream(of: HomeLoadEvent.self)
        let service = plexService
        let answers = service.streamAcrossServers(loadHomePayload)
        let answersTask = Task {
            for await result in answers {
                eventSink.yield(.answer(result))
            }
            eventSink.yield(.answersFinished)
        }
        // The account's library order is a nicety, not a requirement: if it
        // cannot be read, Home keeps each server's own hub order.
        let orderTask = Task {
            _ = try? await service.ensureLibraryOrderLoaded()
            eventSink.yield(.orderSettled)
        }
        var deadlineTask: Task<Void, Never>?
        var scheduledDeadline: ContinuousClock.Instant?
        defer {
            answersTask.cancel()
            orderTask.cancel()
            deadlineTask?.cancel()
            eventSink.finish()
        }

        let loadServerIDs = Set(serverIDs)
        var payloadsByRank = [HomeServerPayload?](repeating: nil, count: serverIDs.count)
        var answersFinished = false
        var orderSettled = false
        var hasPainted = !isInitialLoad
        var firstContentAt: ContinuousClock.Instant?

        var failureCount = 0
        var firstFailure: String?

        for await event in events {
            guard !Task.isCancelled, generation == loadGeneration else { return }

            switch event {
            case let .answer(result):
                if let failure = result.value.failure {
                    failureCount += 1
                    firstFailure = firstFailure ?? failure
                }

                let payload = result.value.merged(onto: lastPayloads[result.serverID])
                lastPayloads[result.serverID] = payload
                payloadsByRank[result.rank] = payload

                // Past its first paint, a first load folds late servers in as
                // they land. A load that started with content on screen
                // publishes once, below.
                if isInitialLoad, hasPainted {
                    publishMerge(
                        of: payloadsByRank,
                        maxRecentlyAddedItems: currentMaxRecentlyAddedItems,
                        animated: true
                    )
                }
            case .answersFinished:
                answersFinished = true
            case .orderSettled:
                orderSettled = true
            case .firstPaintDeadline:
                break
            }

            let hasContent = payloadsByRank.contains { $0?.hasVisibleContent == true }

            if let gate, !hasPainted {
                if hasContent, firstContentAt == nil {
                    firstContentAt = .now
                }

                let answered = Set(zip(serverIDs, payloadsByRank).compactMap { $1 == nil ? nil : $0 })
                let outstanding = loadServerIDs
                    .subtracting(answered)
                    .union(serversStillConnecting(excluding: loadServerIDs))

                let decision = gate.decide(
                    now: .now,
                    hasContent: hasContent,
                    hasHero: payloadsByRank.contains { $0?.hasHeroItem == true },
                    firstContentAt: firstContentAt,
                    isSettled: outstanding.isEmpty && orderSettled,
                    isAwaitingRememberedHero: !outstanding.isDisjoint(with: rememberedHeroServerIDs)
                )

                switch decision {
                case .paint:
                    publishMerge(
                        of: payloadsByRank,
                        maxRecentlyAddedItems: currentMaxRecentlyAddedItems,
                        animated: false
                    )
                    hasPainted = true
                    firstPaintGate = nil
                    error = nil
                    isLoading = false
                case let .wait(until: deadline):
                    if let deadline, deadline != scheduledDeadline {
                        scheduledDeadline = deadline
                        deadlineTask?.cancel()
                        deadlineTask = Task {
                            try? await Task.sleep(until: deadline, clock: .continuous)
                            guard !Task.isCancelled else { return }
                            eventSink.yield(.firstPaintDeadline)
                        }
                    }
                }
            }

            // Done once every server and the order are in — and, on a first
            // load, once the gate has let something through. A merge with
            // nothing in it has nothing to hold back.
            if answersFinished, orderSettled, hasPainted || !hasContent {
                break
            }
        }

        guard !Task.isCancelled, generation == loadGeneration else { return }

        // An error only when *every* server failed and there is nothing to
        // show. One failing server is reported by the partial-outage note.
        if failureCount == serverIDs.count, !hasLoadedContent {
            error = firstFailure
            return
        }

        // On a refresh this is the run's only publish; on a first load it
        // settles the library order the first paint may not have had yet.
        let merged = publishMerge(
            of: payloadsByRank,
            maxRecentlyAddedItems: currentMaxRecentlyAddedItems,
            animated: hasLoadedContent
        )
        firstPaintGate = nil
        if hasLoadedContent {
            error = nil
        }

        HomeContinueWatchingMemory.remember(
            Set(zip(serverIDs, payloadsByRank).compactMap { $1?.hasHeroItem == true ? $0 : nil }),
            profileID: profileID
        )

        startRecentlyAddedExpansion(
            from: merged.hubs,
            generation: generation,
            maxRecentlyAddedItems: currentMaxRecentlyAddedItems
        )
        startPersonalizedShelvesLoad(
            excluding: merged.continueWatching,
            generation: generation,
            maxRecentlyAddedItems: currentMaxRecentlyAddedItems
        )
    }

    /// Enabled servers the pool is still bringing up that this load did not fan
    /// out to. When one connects, the content revision changes and a new load
    /// replaces this one; until then the first paint may wait for it.
    private func serversStillConnecting(excluding loadServerIDs: Set<String>) -> Set<String> {
        let pool = plexService.pool
        return pool.knownServerIDs.filter { serverID in
            guard !loadServerIDs.contains(serverID), pool.isEnabled(serverID) else { return false }
            switch pool.state(for: serverID) {
            case .idle, .connecting:
                return true
            default:
                return false
            }
        }
    }

    @discardableResult
    private func publishMerge(
        of payloads: [HomeServerPayload?],
        maxRecentlyAddedItems: Int,
        animated: Bool
    ) -> (hubs: [PlexHub], continueWatching: [PlexItem]) {
        let merged = mergedScreen(from: payloads)
        publish(
            hubs: merged.hubs,
            continueWatching: merged.continueWatching,
            maxRecentlyAddedItems: maxRecentlyAddedItems,
            animated: animated
        )
        return merged
    }

    /// Folds the answers in hand into the screen, in the account's library
    /// order. Servers that have not answered contribute nothing, so calling it
    /// again with one more answer refines the same list.
    private func mergedScreen(
        from payloads: [HomeServerPayload?]
    ) -> (hubs: [PlexHub], continueWatching: [PlexItem]) {
        var hubsByServer: [[PlexHub]] = []
        var continueWatchingByServer: [[PlexItem]] = []
        hubsByServer.reserveCapacity(payloads.count)
        continueWatchingByServer.reserveCapacity(payloads.count)

        for payload in payloads {
            hubsByServer.append((payload?.hubs ?? []).filter { !shouldHideHomeHub($0) })
            continueWatchingByServer.append(
                (payload?.continueWatching ?? []).filter { !shouldHideHomeItem($0) }
            )
        }

        let mergedHubs = HubMerge.merge(hubsByServer)
        let mergedContinueWatching = ContinueWatchingMerge.merge(continueWatchingByServer)
        plexService.registerAlternates(mergedHubs.alternates)
        plexService.registerAlternates(mergedContinueWatching.alternates)

        return (
            HomeHubArrangement.arrange(
                hubs: mergedHubs.hubs,
                libraryOrder: libraryOrderIdentities()
            ),
            mergedContinueWatching.items
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
