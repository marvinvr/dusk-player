import Foundation

/// One program's answer in the recording lookup's task group. A named type built
/// in one place on purpose: see `Result.capturing`.
private struct LiveTVRecordingLookup: Sendable {
    let guid: String
    let outcome: Result<PlexItem?, any Error>
}

/// One day's answer in the ranged guide fetch's task group (see
/// `LiveTVRecordingLookup`).
private struct LiveTVGuideDayFetch: Sendable {
    let day: Date
    let outcome: Result<[PlexLiveProgram], any Error>
}

@MainActor
@Observable
final class LiveTVViewModel {
    private let plexService: PlexService
    /// The user's IPTV sources, shown after the Plex channels.
    private let iptvService: IPTVService?

    private(set) var provider: PlexLiveTVProvider?
    private(set) var channels: [PlexLiveChannel] = []
    /// The DVR's tuner devices. Empty until the server has said (the guide
    /// then shows Plex as one section).
    private(set) var devices: [PlexLiveTVDevice] = []
    private var hasLoadedDevices = false
    private(set) var lineup: PlexLiveTVLineup?
    private(set) var nowPlayingLineup: PlexLiveTVLineup?
    /// The day last picked in the day menu: 0 is today, 1 and up days after
    /// it, -1 and down days before it (only offered while some channel has
    /// catch-up, `pastDayCount`). Only scrolls the guide: every section, Plex
    /// included, holds its whole guide on one axis. An offset, not a date: a
    /// date picked at launch went stale on an Apple TV that keeps the app
    /// running for days.
    private(set) var selectedDayOffset = 0
    private(set) var isLoading = false
    private(set) var isLoadingNowPlaying = false
    private(set) var error: String?

    /// The full guide as fetched; `lineup` is it with what ended more than
    /// `nowLookback` ago dropped.
    private var fetchedLineup: PlexLiveTVLineup?
    /// Plex airings by the local day (midnight) they were asked for. Today
    /// and tomorrow refresh every `refreshInterval`; the days after that
    /// (as far as the server has a guide) every `farRefreshInterval`.
    private var plexAirings: [Date: [PlexLiveProgram]] = [:]
    /// When today and tomorrow were last fetched.
    private var loadedAt: Date?
    /// When the days after tomorrow were last fetched.
    private var farLoadedAt: Date?
    /// Set when the server ignored the grid's time range (nothing at all for
    /// today and tomorrow): the guide then falls back to one `date=` request
    /// per channel and day, for those two days only.
    private var usesPerChannelGuide = false
    /// A load asked for while another ran, e.g. a date picked mid-refresh.
    /// It used to be dropped, leaving the guide on the old date.
    private var reloadRequested = false
    /// The Plex Home profile the provider was found for.
    private var discoveredProfileID: String?
    /// Library copies (DVR recordings) of past Plex airings, by guid: what
    /// makes a past Plex programme playable.
    private(set) var plexRecordings: [String: PlexItem] = [:]
    /// Guids already asked about, hit or miss, so a guide refresh does not
    /// ask again.
    private var checkedRecordingGuids: Set<String> = []

    /// Whether a connected server has a DVR or an IPTV source is set up.
    /// Drives the tab.
    var isAvailable: Bool { provider != nil || hasIPTVSources }

    var hasIPTVSources: Bool { iptvService?.hasSources == true }

    /// Each loaded IPTV source with its whole guide. Unlike Plex (fetched per
    /// day) all of it is in memory, so a source scrolls through it on one
    /// axis, independent of the day the Plex section is on.
    var iptvLineups: [IPTVSourceLineup] { iptvService?.lineups ?? [] }

    /// Whether anything (Plex or IPTV) has a guide to show.
    /// The Plex lineup split per tuner device (each its own guide section,
    /// like an IPTV source), or nil when there is only one.
    var plexDeviceLineups: [PlexLiveTVDeviceLineup]? {
        lineup?.groupedByDevice(devices)
    }

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
        devices = []
        hasLoadedDevices = false
        lineup = nil
        fetchedLineup = nil
        nowPlayingLineup = nil
        plexAirings = [:]
        loadedAt = nil
        farLoadedAt = nil
        usesPerChannelGuide = false
        plexRecordings = [:]
        checkedRecordingGuids = []
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
            // Airings that ended since the last pass may have recordings.
            await findRecordings(now: now)
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
        guard fetchedLineup != nil, let loadedAt else { return true }
        return !Calendar.current.isDate(loadedAt, inSameDayAs: now)
            || now.timeIntervalSince(loadedAt) >= Self.refreshInterval
            || needsFarReload(now: now)
    }

    private func needsFarReload(now: Date) -> Bool {
        guard !usesPerChannelGuide else { return false }
        guard let farLoadedAt else { return true }
        return !Calendar.current.isDate(farLoadedAt, inSameDayAs: now)
            || now.timeIntervalSince(farLoadedAt) >= Self.farRefreshInterval
    }

    /// Today and tomorrow first (what the guide opens on), then the days
    /// after them, a few at a time, as far as the server has a guide: a
    /// sports feed's next race can be a week or two out, and a guide that
    /// stopped at "Now" plus 12 hours never reached it.
    private func fetchGuide(refreshChannels: Bool) async {
        let now = Date.now
        let today = Calendar.current.startOfDay(for: now)
        do {
            guard let provider = try await resolveProvider() else {
                lineup = nil
                fetchedLineup = nil
                return
            }

            if channels.isEmpty || refreshChannels {
                channels = try await plexService.getLiveTVChannels(provider: provider)
            }
            // Only groups the guide: a failure must not cost the channels,
            // and is asked again on the next load.
            if !hasLoadedDevices || refreshChannels,
               let found = try? await plexService.getLiveTVDevices(provider: provider) {
                devices = found
                hasLoadedDevices = true
            }

            let nearDays = Self.guideDays(from: today, count: 2)
            if usesPerChannelGuide && !refreshChannels {
                try await fetchPerChannelGuide(provider: provider, days: nearDays, now: now)
            } else {
                let near = try await fetchAirings(provider: provider, days: nearDays)
                if near.values.allSatisfy(\.isEmpty), !channels.isEmpty {
                    usesPerChannelGuide = true
                    try await fetchPerChannelGuide(provider: provider, days: nearDays, now: now)
                } else {
                    usesPerChannelGuide = false
                    plexAirings = plexAirings.filter { $0.key >= today }.merging(near) { $1 }
                    loadedAt = now
                    publishLineup(provider: provider, now: now)
                }
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        await findRecordings()
        if let provider, needsFarReload(now: now) || refreshChannels {
            await fetchFarDays(provider: provider, today: today)
        }
    }

    /// The days after tomorrow, `farDayBatch` at a time, until a batch has
    /// nothing at all (not even an airing running through it), the guide
    /// reaches `maxGuideDays`, or it holds `maxGuideAirings`. A failed day
    /// keeps what it had.
    private func fetchFarDays(provider: PlexLiveTVProvider, today: Date) async {
        guard !usesPerChannelGuide else { return }
        var offset = 2
        var reachedEnd = false
        while offset < Self.maxGuideDays, !Task.isCancelled {
            let days = Self.guideDays(
                from: Self.day(offset, after: today),
                count: min(Self.farDayBatch, Self.maxGuideDays - offset)
            )
            offset += days.count
            guard let batch = try? await fetchAirings(provider: provider, days: days) else { break }
            guard self.provider == provider else { return }
            plexAirings.merge(batch) { $1 }
            if batch.count == days.count, batch.values.allSatisfy(\.isEmpty) {
                reachedEnd = true
            }
            publishLineup(provider: provider, now: .now)
            if reachedEnd || plexAirings.values.reduce(0, { $0 + $1.count }) >= Self.maxGuideAirings { break }
        }
        // Days past the guide's end that an earlier pass still had.
        if reachedEnd {
            let last = Self.day(offset, after: today)
            plexAirings = plexAirings.filter { $0.key < last }
        }
        farLoadedAt = .now
    }

    /// Each of `days` as one ranged grid request, a few at a time. Days that
    /// failed are missing from the answer; only all of them failing throws.
    private func fetchAirings(provider: PlexLiveTVProvider, days: [Date]) async throws -> [Date: [PlexLiveProgram]] {
        let plexService = plexService
        let windows = days.map { LiveTVGuideWindow(start: $0, end: Self.day(1, after: $0)) }
        let results = await withTaskGroup(of: LiveTVGuideDayFetch.self) { group in
            for window in windows {
                group.addTask {
                    let outcome = await Result.capturing {
                        try await plexService.getLiveTVGuideAirings(provider: provider, window: window)
                    }
                    return LiveTVGuideDayFetch(day: window.start, outcome: outcome)
                }
            }
            var results: [LiveTVGuideDayFetch] = []
            for await result in group { results.append(result) }
            return results
        }
        var airings: [Date: [PlexLiveProgram]] = [:]
        var firstError: (any Error)?
        for result in results {
            let day = result.day
            switch result.outcome {
            case .success(let programs): airings[day] = programs
            case .failure(let error): firstError = firstError ?? error
            }
        }
        if airings.isEmpty, let firstError { throw firstError }
        return airings
    }

    /// The old way, for a server whose grid ignores the time range: one
    /// `date=` request per channel and day.
    private func fetchPerChannelGuide(provider: PlexLiveTVProvider, days: [Date], now: Date) async throws {
        let fetched = try await plexService.getLiveTVGuide(provider: provider, channels: channels, dates: days)
        plexAirings = [Calendar.current.startOfDay(for: now): fetched.guides.flatMap(\.programs)]
        loadedAt = now
        farLoadedAt = nil
        publishLineup(provider: provider, now: now)
    }

    private func publishLineup(provider: PlexLiveTVProvider, now: Date) {
        let fetched = PlexLiveTVLineup(
            provider: provider,
            channels: channels,
            programs: plexAirings.keys.sorted().flatMap { plexAirings[$0] ?? [] }
        )
        fetchedLineup = fetched
        let trimmed = fetched.restricted(to: Self.guideWindow(now: now))
        if trimmed != lineup { lineup = trimmed }
    }

    static func guideDays(from day: Date, count: Int) -> [Date] {
        (0..<max(0, count)).map { self.day($0, after: day) }
    }

    static func day(_ offset: Int, after day: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: day)
            ?? day.addingTimeInterval(TimeInterval(offset) * 24 * 60 * 60)
    }

    // MARK: - Catch-up

    /// Looks up a library copy for each ended Plex airing in the guide that
    /// has not been asked about yet. Plex itself offers no catch-up; a DVR
    /// recording is the only way a past airing plays.
    private func findRecordings(now: Date = .now) async {
        guard let lineup, let provider else { return }
        var pending: [PlexLiveProgram] = []
        var seen = Set<String>()
        for guide in lineup.guides {
            for program in guide.programs {
                guard let endsAt = program.endsAt, endsAt <= now,
                      let guid = program.guid?.nilIfEmpty,
                      !checkedRecordingGuids.contains(guid),
                      seen.insert(guid).inserted else { continue }
                pending.append(program)
            }
        }
        guard !pending.isEmpty else { return }
        let batch = Array(pending.prefix(Self.recordingLookupLimit))
        let plexService = plexService
        let results = await withTaskGroup(of: LiveTVRecordingLookup.self) { group in
            var iterator = batch.makeIterator()
            func addNext() {
                guard let program = iterator.next(), let guid = program.guid else { return }
                group.addTask {
                    let outcome = await Result.capturing {
                        try await plexService.liveTVRecording(for: program, provider: provider)
                    }
                    return LiveTVRecordingLookup(guid: guid, outcome: outcome)
                }
            }
            for _ in 0..<4 { addNext() }
            var results: [LiveTVRecordingLookup] = []
            for await result in group {
                results.append(result)
                addNext()
            }
            return results
        }
        for result in results {
            // A failed lookup is asked again on the next load.
            guard case .success(let item) = result.outcome else { continue }
            checkedRecordingGuids.insert(result.guid)
            if let item { plexRecordings[result.guid] = item }
        }
    }

    /// The library copy a past Plex airing plays from, if any.
    func recording(for program: PlexLiveProgram) -> PlexItem? {
        program.guid.flatMap { plexRecordings[$0] }
    }

    /// Whether a programme that has ended can be played: an IPTV channel
    /// with catch-up covering it, or a Plex airing with a recording.
    func canReplay(_ program: PlexLiveProgram, on channel: PlexLiveChannel, now: Date = .now) -> Bool {
        guard let beginsAt = program.beginsAt, let endsAt = program.endsAt, endsAt <= now else { return false }
        if let iptv = channel.iptv {
            return iptv.canCatchUp(start: beginsAt, end: endsAt, now: now)
        }
        return recording(for: program) != nil
    }

    /// The longest catch-up window of any IPTV channel, in days (0: none).
    /// Past days are offered in the day menu only up to it.
    var pastDayCount: Int {
        guard let iptvService else { return 0 }
        var days = 0
        for loaded in iptvService.lineups {
            for guide in loaded.lineup.guides {
                if let channelDays = guide.channel.iptv?.catchUp?.days, channelDays > days { days = channelDays }
            }
        }
        return days
    }

    /// Drops what ended long enough ago from the guide without a refetch.
    private func trimToWindow(now: Date) {
        guard let fetchedLineup else { return }
        let trimmed = fetchedLineup.restricted(to: Self.guideWindow(now: now))
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

    /// Only remembers the pick: the guide is already loaded, the grid
    /// scrolls to the day.
    func selectDayOffset(_ dayOffset: Int) {
        selectedDayOffset = dayOffset
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

    /// What the Plex guide keeps: from `nowLookback` ago (at least back to
    /// midnight) on, as far ahead as it was fetched. Plex's grid drops
    /// airings that have ended, so in practice the past is whatever is still
    /// on and the recordings found for it.
    static func guideWindow(now: Date = .now) -> LiveTVGuideWindow {
        let start = min(Calendar.current.startOfDay(for: now), now.addingTimeInterval(-nowLookback))
        return LiveTVGuideWindow(start: LiveTVGuideTimeline.floorToTick(start), end: .distantFuture)
    }

    /// The stretch a Plex section draws: its whole guide, like an IPTV
    /// source, opening no earlier than `guideWindow`.
    static func timelineWindow(of lineup: PlexLiveTVLineup, now: Date = .now) -> LiveTVGuideWindow {
        let whole = LiveTVGuideTimeline.wholeGuideWindow(of: lineup, now: now)
        return LiveTVGuideWindow(start: max(whole.start, guideWindow(now: now).start), end: whole.end)
    }

    /// Recording lookups per guide pass (one request each); the rest follow
    /// on the next pass, a minute later.
    static let recordingLookupLimit = 40

    /// How far "Now" reaches back (at least to midnight).
    static let nowLookback: TimeInterval = 12 * 60 * 60

    /// The half hour at least `gridLeadIn` before now: at 17:00 sharp the grid
    /// opened on the now line itself, with nothing of the programme on now.
    static func gridStart(now: Date) -> Date {
        LiveTVGuideTimeline.floorToTick(now.addingTimeInterval(-gridLeadIn))
    }

    static let gridLeadIn: TimeInterval = 10 * 60

    /// Today and the next week, or as far as any guide reaches (up to
    /// `maxGuideDays`), and past days only as far back as some IPTV channel
    /// has catch-up: Plex's grid drops airings that have ended, so a past day
    /// without catch-up is empty.
    var dayOffsetOptions: [Int] { Array(-pastDayCount...max(7, futureDayCount)) }

    /// The last day with guide data, as days after today.
    private var futureDayCount: Int {
        var last: Date?
        let lineups = [fetchedLineup].compactMap { $0 } + iptvLineups.map(\.lineup)
        for lineup in lineups {
            for guide in lineup.guides {
                if let end = guide.programs.last?.endsAt, end > (last ?? .distantPast) { last = end }
            }
        }
        guard let last else { return 0 }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: last.addingTimeInterval(-1))
        ).day ?? 0
        return min(days, Self.maxGuideDays)
    }

    /// How old today's and tomorrow's guide may get before they are fetched
    /// again.
    static let refreshInterval: TimeInterval = 15 * 60

    /// How old the days after tomorrow may get. XMLTV guides refresh about
    /// once a day; these only need to notice a session that moved.
    static let farRefreshInterval: TimeInterval = 3 * 60 * 60

    /// How many days ahead the Plex guide is fetched at most.
    static let maxGuideDays = 21

    /// Days fetched at once past tomorrow.
    static let farDayBatch = 3

    /// Stops fetching further days once the guide holds this many airings:
    /// a big cloud lineup has hundreds of channels, and every airing is a
    /// cell on the grid.
    static let maxGuideAirings = 20_000

    private static let discoveryMaxRetryDelay: Duration = .seconds(60)
}
