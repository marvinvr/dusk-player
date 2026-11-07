import Foundation

@MainActor
@Observable
final class LiveTVViewModel {
    private let plexService: PlexService
    /// The user's IPTV sources, shown after the Plex channels.
    private let iptvService: IPTVService?

    private(set) var provider: PlexLiveTVProvider?
    private(set) var channels: [PlexLiveChannel] = []
    private(set) var lineup: PlexLiveTVLineup?
    private(set) var nowPlayingLineup: PlexLiveTVLineup?
    /// 0 is "Now" (the next `LiveTVGuideWindow.lookahead` hours), 1 and up
    /// are whole days after today. An offset, not a date: a date picked at
    /// launch went stale on an Apple TV that keeps the app running for days.
    private(set) var selectedDayOffset = 0
    private(set) var isLoading = false
    private(set) var isLoadingNowPlaying = false
    private(set) var error: String?

    /// The full guide as fetched; `lineup` is it trimmed to the window.
    private var fetchedLineup: PlexLiveTVLineup?
    private var loadedWindow: LiveTVGuideWindow?
    private var loadedAt: Date?
    private var loadedDayOffset: Int?
    /// A load asked for while another ran, e.g. a date picked mid-refresh.
    /// It used to be dropped, leaving the guide on the old date.
    private var reloadRequested = false
    /// The Plex Home profile the provider was found for.
    private var discoveredProfileID: String?

    /// Whether a connected server has a DVR or an IPTV source is set up.
    /// Drives the tab.
    var isAvailable: Bool { provider != nil || hasIPTVSources }

    var hasIPTVSources: Bool { iptvService?.hasSources == true }

    /// Each loaded IPTV source, trimmed to the selected guide window like the
    /// Plex lineup. Read live so "Now" drops ended programmes as time passes.
    var iptvLineups: [IPTVSourceLineup] {
        guard let iptvService else { return [] }
        let window = Self.displayWindow(forDayOffset: selectedDayOffset)
        return iptvService.lineups.map { loaded in
            IPTVSourceLineup(
                source: loaded.source,
                lineup: loaded.lineup.restricted(to: window),
                guideError: loaded.guideError
            )
        }
    }

    /// Whether anything (Plex or IPTV) has a guide to show.
    var hasGuide: Bool { lineup != nil || !(iptvService?.lineups.isEmpty ?? true) }

    var isLoadingAny: Bool { isLoading || iptvService?.isLoading == true }

    /// The Plex error, or else the first IPTV source error, for when there is
    /// no guide at all to show.
    var guideError: String? {
        if let error { return error }
        guard let iptvService else { return nil }
        return iptvService.sources.lazy.compactMap { iptvService.sourceErrors[$0.id] }.first
    }

    private let discoveryRetryDelay: Duration

    init(
        plexService: PlexService,
        iptvService: IPTVService? = nil,
        discoveryRetryDelay: Duration = .seconds(2)
    ) {
        self.plexService = plexService
        self.iptvService = iptvService
        self.discoveryRetryDelay = discoveryRetryDelay
    }

    /// Runs whenever the set of connected servers changes, on its own task so
    /// slow library loads never hold it up. Keeps asking, backing off, until
    /// either a server has a DVR or every connected server has said it has
    /// none: one slow or failed `/media/providers` is not "no Live TV", and
    /// latching it hid the tab for the whole session (1.7.2).
    func discover() async {
        resetIfProfileChanged()
        guard provider == nil else { return }

        var delay = discoveryRetryDelay
        while !Task.isCancelled {
            switch await discoverOnce() {
            case .found, .none:
                return
            case .inconclusive:
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, Self.discoveryMaxRetryDelay)
            }
        }
    }

    /// One discovery pass. Only a found DVR changes anything, and it is kept
    /// for the session: a later pass that fails (or overlaps this one), or a
    /// server that briefly drops out while it reconnects, must not take the
    /// tab away under the user.
    private func discoverOnce() async -> LiveTVDiscovery {
        let profileID = plexService.serverContentRevision.profileID
        let result = await plexService.discoverLiveTVProvider()
        if case .found(let found) = result,
           provider == nil,
           profileID == plexService.serverContentRevision.profileID {
            provider = found
            discoveredProfileID = profileID
        }
        return result
    }

    /// A different Plex Home member sees different servers and DVRs.
    private func resetIfProfileChanged() {
        guard provider != nil,
              discoveredProfileID != plexService.serverContentRevision.profileID else { return }
        provider = nil
        channels = []
        lineup = nil
        fetchedLineup = nil
        nowPlayingLineup = nil
        loadedWindow = nil
        loadedAt = nil
        loadedDayOffset = nil
    }

    /// The provider, discovering it first when no pass has found one yet.
    private func resolveProvider() async throws -> PlexLiveTVProvider? {
        resetIfProfileChanged()
        if let provider { return provider }
        if case .inconclusive(let error) = await discoverOnce(), provider == nil {
            throw error
        }
        return provider
    }

    /// Loads the guide when it is missing, stale or for another selection.
    /// Cheap to call on every appearance.
    func load(force: Bool = false, now: Date = .now) async {
        // IPTV sources load beside the Plex guide, never behind it: a slow
        // DVR must not hold back channels that have nothing to do with it.
        let iptvLoad = Task { [iptvService] in await iptvService?.load(force: force) }
        await loadPlexGuide(force: force, now: now)
        await iptvLoad.value
    }

    private func loadPlexGuide(force: Bool, now: Date) async {
        // The tab is up for IPTV alone. `discover()` keeps looking for a DVR
        // on its own; asking again on every guide tick would only repeat it.
        if provider == nil, hasIPTVSources, !force { return }
        guard !isLoading else {
            reloadRequested = true
            return
        }
        guard force || needsReload(now: now) else {
            trimToWindow(now: now)
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        repeat {
            reloadRequested = false
            await fetchGuide(refreshChannels: force)
        } while reloadRequested && !Task.isCancelled
    }

    /// Keeps the guide current while it is on screen: ended programs drop off
    /// every minute, and the whole guide is refetched once it is
    /// `refreshInterval` old. Runs until the calling task is cancelled.
    func keepFresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func needsReload(now: Date) -> Bool {
        guard fetchedLineup != nil, let loadedAt, let loadedDayOffset else { return true }
        return loadedDayOffset != selectedDayOffset
            || !Calendar.current.isDate(loadedAt, inSameDayAs: now)
            || now.timeIntervalSince(loadedAt) >= Self.refreshInterval
    }

    private func fetchGuide(refreshChannels: Bool) async {
        let dayOffset = selectedDayOffset
        let window = Self.displayWindow(forDayOffset: dayOffset)
        do {
            guard let provider = try await resolveProvider() else {
                lineup = nil
                fetchedLineup = nil
                return
            }

            if channels.isEmpty || refreshChannels {
                channels = try await plexService.getLiveTVChannels(provider: provider)
            }
            let fetched = try await plexService.getLiveTVGuide(
                provider: provider,
                channels: channels,
                dates: window.gridDays()
            )
            // A newer selection is already queued; don't flash this one.
            guard dayOffset == selectedDayOffset else { return }
            fetchedLineup = fetched
            loadedWindow = window
            loadedAt = .now
            loadedDayOffset = dayOffset
            lineup = fetched.restricted(to: window)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Drops what has ended from the "Now" guide without a refetch.
    private func trimToWindow(now: Date) {
        guard selectedDayOffset == 0, let fetchedLineup else { return }
        let window = LiveTVGuideWindow(
            start: Self.gridStart(now: now),
            end: loadedWindow?.end ?? now.addingTimeInterval(LiveTVGuideWindow.lookahead)
        )
        let trimmed = fetchedLineup.restricted(to: window)
        if trimmed != lineup { lineup = trimmed }
    }

    /// Feeds the Home shelf. Separate from `load()`'s flag: a guide load in
    /// flight used to swallow this call, and the shelf never asked again.
    func loadNowPlaying(force: Bool = false) async {
        guard !isLoadingNowPlaying else { return }
        guard force || nowPlayingLineup == nil else { return }
        isLoadingNowPlaying = true
        defer { isLoadingNowPlaying = false }

        do {
            guard let provider = try await resolveProvider() else { return }
            if channels.isEmpty {
                channels = try await plexService.getLiveTVChannels(provider: provider)
            }
            nowPlayingLineup = try await plexService.getLiveTVNowPlaying(
                provider: provider,
                channels: channels
            )
        } catch {
            // The shelf just stays hidden; the Live TV tab shows the details.
        }
    }

    func selectDayOffset(_ dayOffset: Int) async {
        guard dayOffset != selectedDayOffset else { return }
        selectedDayOffset = dayOffset
        await load()
    }

    /// Image URLs for one lineup's rows: IPTV art is absolute, Plex art is
    /// asked of the DVR's server.
    func imageURL(for lineup: PlexLiveTVLineup) -> (String?, Int, Int) -> URL? {
        guard lineup.provider.isIPTV else { return imageURL(for:width:height:) }
        let plexService = plexService
        return { path, width, height in
            plexService.imageURL(for: path, serverID: IPTVImages.serverID, width: width, height: height)
        }
    }

    func imageURL(for path: String?, width: Int, height: Int) -> URL? {
        // Explicit because `imageURL` falls back to the primary server, while
        // the DVR may live on another one.
        plexService.imageURL(
            for: path,
            serverID: provider?.serverID ?? plexService.liveTVServerID,
            width: width,
            height: height
        )
    }

    /// The stretch the grid shows for a day offset. "Now" starts on a half
    /// hour before now rather than at now, so the grid's ruler opens on a
    /// round time and what ended a few minutes ago still fills the dimmed
    /// past instead of leaving a hole.
    static func displayWindow(forDayOffset dayOffset: Int, now: Date = .now) -> LiveTVGuideWindow {
        let window = LiveTVGuideWindow.forDayOffset(dayOffset, now: now)
        guard dayOffset == 0 else { return window }
        return LiveTVGuideWindow(start: gridStart(now: window.start), end: window.end)
    }

    /// The half hour at least `gridLeadIn` before now: at 17:00 sharp the grid
    /// opened on the now line itself, with nothing of the programme on now.
    static func gridStart(now: Date) -> Date {
        LiveTVGuideTimeline.floorToTick(now.addingTimeInterval(-gridLeadIn))
    }

    static let gridLeadIn: TimeInterval = 10 * 60

    /// The window shown right now.
    var displayWindow: LiveTVGuideWindow { Self.displayWindow(forDayOffset: selectedDayOffset) }

    /// "Now" plus the next week. No past days: Plex's grid drops airings that
    /// have ended, so yesterday only ever came back empty.
    var dayOffsetOptions: [Int] { Array(0...7) }

    /// How old a fetched guide may get before it is fetched again.
    static let refreshInterval: TimeInterval = 15 * 60

    private static let discoveryMaxRetryDelay: Duration = .seconds(60)
}
