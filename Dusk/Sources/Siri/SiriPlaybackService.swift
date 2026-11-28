import Foundation
import OSLog

private let siriLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "Siri"
)

/// What the Siri intents run on: finds the movie or show a spoken title means
/// across every connected server and starts it the way the app's own Play
/// buttons do (a movie resumes, a show plays its next episode).
///
/// The intents open Dusk before they run, because only the foreground app
/// connects its servers, so everything here first waits for the pool.
@MainActor
final class SiriPlaybackService {
    enum Lookup {
        case resolved(SiriTitleResolution)
        /// Nothing can be searched (signed out, no server); the message says why.
        case unavailable(String)
    }

    private static let readinessTimeout: Duration = .seconds(15)
    /// Once one server answers, how long the others get to join the search.
    private static let otherServersGrace: Duration = .milliseconds(1500)
    private static let maxEntityResults = 10

    private let plexService: PlexService
    private let playback: PlaybackCoordinator

    /// Titles found by a picker search that are not in the catalog, so the
    /// entity Siri hands back to an intent by identifier can be rebuilt.
    private(set) var recentlyMatched: [String: PlexTitleEntity] = [:]

    init(plexService: PlexService, playback: PlaybackCoordinator) {
        self.plexService = plexService
        self.playback = playback
    }

    // MARK: - Resolving

    func lookUp(_ spoken: String) async -> Lookup {
        let query = SiriTitleQuery(spoken)
        guard !query.text.isEmpty else { return .resolved(.notFound) }
        if let problem = await waitUntilServersAreReady() {
            return .unavailable(problem)
        }
        let candidates = await candidates(for: query)
        return .resolved(SiriTitleMatcher.resolve(query, among: candidates))
    }

    /// Ranked matches for the Shortcuts/Siri title picker. Uses Plex search
    /// when a server is connected, otherwise the titles Siri already knows.
    func entities(matching text: String) async -> [SiriTitleCandidate] {
        let query = SiriTitleQuery(text)
        guard !query.text.isEmpty else { return [] }
        let candidates = plexService.isSessionReady && plexService.pool.availability.isReady
            ? await candidates(for: query)
            : catalogCandidates(connectedOnly: false)
        return SiriTitleMatcher.rank(query, among: candidates)
            .prefix(Self.maxEntityResults)
            .map(\.candidate)
    }

    func remember(_ entities: [PlexTitleEntity]) {
        if recentlyMatched.count > 200 {
            recentlyMatched = [:]
        }
        for entity in entities {
            recentlyMatched[entity.id] = entity
        }
    }

    // MARK: - Playing

    /// Starts `candidate` and returns what Siri should say.
    func play(_ candidate: SiriTitleCandidate) async -> String {
        if let problem = await waitUntilServersAreReady() {
            return problem
        }

        // A title Siri learned earlier may live on a server that is not
        // connected right now; another server may well have it.
        guard plexService.pool.connection(for: candidate.id.serverID) != nil else {
            let query = SiriTitleQuery(candidate.title)
            let alternatives = await candidates(for: query).filter { $0.kind == candidate.kind }
            guard let replacement = SiriTitleMatcher.rank(query, among: alternatives).first?.candidate,
                  plexService.pool.connection(for: replacement.id.serverID) != nil else {
                return "The server with \(candidate.title) isn’t reachable right now."
            }
            return await play(replacement)
        }

        switch candidate.kind {
        case .movie:
            return await playMovie(candidate)
        case .show:
            return await playNextEpisode(of: candidate)
        }
    }

    private func playMovie(_ candidate: SiriTitleCandidate) async -> String {
        let details: MediaDetails
        do {
            details = try await plexService.getMediaDetails(
                itemID: candidate.id.itemID,
                serverID: candidate.id.serverID
            )
        } catch {
            siriLogger.error("Siri: movie details failed: \(error.localizedDescription, privacy: .public)")
            return "I couldn’t load \(candidate.title) from Plex."
        }

        startPlayback(
            id: candidate.id,
            resumeOffset: details.viewOffset,
            duration: details.duration,
            placeholder: PlaybackPlaceholder(details: details)
        )
        let isResuming = (details.viewOffset ?? 0) > 0
        return "\(isResuming ? "Resuming" : "Playing") \(details.title)."
    }

    private func playNextEpisode(of show: SiriTitleCandidate) async -> String {
        let episodes: [Episode]
        do {
            episodes = try await plexService.getAllEpisodes(
                showKey: show.id.itemID,
                serverID: show.id.serverID
            )
        } catch {
            siriLogger.error("Siri: episodes failed: \(error.localizedDescription, privacy: .public)")
            return "I couldn’t load \(show.title) from Plex."
        }

        let states = episodes.map { episode in
            SiriNextEpisodePicker.Episode(
                id: episode.id,
                season: episode.parentIndex,
                index: episode.index,
                isWatched: (episode.viewCount ?? 0) > 0,
                isInProgress: (episode.viewOffset ?? 0) > 0,
                lastViewedAt: episode.lastViewedAt
            )
        }
        guard let pick = SiriNextEpisodePicker.pick(from: states),
              let episode = episodes.first(where: { $0.id == pick.id }) else {
            return "\(show.title) has no episodes to play."
        }

        startPlayback(
            id: episode.id,
            resumeOffset: episode.viewOffset,
            duration: episode.duration,
            placeholder: PlaybackPlaceholder(episode: episode)
        )

        let verb = pick.isInProgress ? "Resuming" : "Playing"
        guard let season = episode.parentIndex, let number = episode.index else {
            return "\(verb) \(show.title)."
        }
        return "\(verb) \(show.title), season \(season), episode \(number)."
    }

    /// The player cover comes up on its loading placeholder at once; the
    /// intent does not wait for the stream, which has its own error UI.
    private func startPlayback(
        id: MediaItemID,
        resumeOffset: Int?,
        duration: Int?,
        placeholder: PlaybackPlaceholder
    ) {
        let playback = playback
        Task {
            await playback.play(
                id: id,
                resumeOffsetMilliseconds: resumeOffset,
                resumeOffsetDurationMilliseconds: duration,
                placeholder: placeholder
            )
        }
    }

    // MARK: - Readiness

    /// Waits for the foreground app to connect its servers. Returns what Siri
    /// should say when there is nothing to search, nil when ready.
    private func waitUntilServersAreReady() async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.readinessTimeout
        var readySince: ContinuousClock.Instant?

        while true {
            guard plexService.isAuthenticated else {
                return "Sign in to Plex in Dusk first."
            }
            if plexService.homeBootstrapCompleted, plexService.needsHomeUserSelection {
                return "Choose your Plex profile in Dusk first."
            }

            if plexService.isSessionReady {
                switch plexService.pool.availability {
                case .ready:
                    let since = readySince ?? clock.now
                    readySince = since
                    if !plexService.pool.isConnecting || clock.now >= since + Self.otherServersGrace {
                        return nil
                    }
                case .allDisabled:
                    return "All your Plex servers are switched off in Dusk’s settings."
                case .unreachable:
                    return "Dusk can’t reach your Plex server right now."
                case .unknown, .connecting:
                    break
                }
            }

            guard clock.now < deadline else {
                return plexService.pool.availability.isReady
                    ? nil
                    : "Dusk can’t reach your Plex server right now."
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Candidates

    /// Plex search on every connected server for each of the query's search
    /// terms, merged so the same title on two servers is one candidate (the
    /// other copy is registered as a playback fallback), then the titles Siri
    /// already knows.
    private func candidates(for query: SiriTitleQuery) async -> [SiriTitleCandidate] {
        let terms = query.searchTerms
        let perServer = await plexService.fanOutAcrossServers { service, serverID in
            await withTaskGroup(of: (Int, [MediaItem]).self) { group in
                for (index, term) in terms.enumerated() {
                    group.addTask {
                        let groups = (try? await service.search(query: term, serverID: serverID)) ?? []
                        return (index, groups.flatMap(\.items))
                    }
                }
                var byTerm: [(Int, [MediaItem])] = []
                for await result in group {
                    byTerm.append(result)
                }
                return byTerm.sorted { $0.0 < $1.0 }.flatMap(\.1)
            }
        }

        let lists = perServer.map { result in
            var seen: Set<String> = []
            let items = result.value.filter { item in
                Self.kind(of: item) != nil && seen.insert(item.itemID).inserted
            }
            return [SearchSection(title: "Siri", type: "siri", items: items)]
        }
        let merged = SearchMerge.merge(lists)
        plexService.registerAlternates(merged.alternates)

        let searched = merged.groups.flatMap(\.items).compactMap(Self.candidate(for:))
        return searched + catalogCandidates(connectedOnly: true)
    }

    private func catalogCandidates(connectedOnly: Bool) -> [SiriTitleCandidate] {
        SiriTitleCatalog.shared.entries
            .filter { !connectedOnly || plexService.pool.connection(for: $0.id.serverID) != nil }
            .map(SiriTitleCandidate.init(entry:))
    }

    private static func kind(of item: MediaItem) -> SiriTitleKind? {
        guard !item.isClip else { return nil }
        switch item.type {
        case .movie: return .movie
        case .show: return .show
        default: return nil
        }
    }

    private static func candidate(for item: MediaItem) -> SiriTitleCandidate? {
        guard let kind = kind(of: item) else { return nil }
        let isInProgress: Bool
        switch kind {
        case .movie:
            isInProgress = item.isPartiallyWatched
        case .show:
            let viewed = item.viewedLeafCount ?? 0
            isInProgress = viewed > 0 && viewed < (item.leafCount ?? 0)
        }
        return SiriTitleCandidate(
            id: item.id,
            kind: kind,
            title: item.title,
            year: item.year,
            isInProgress: isInProgress,
            lastViewedAt: item.lastViewedAt
        )
    }
}

extension SiriTitleCandidate {
    init(entry: SiriCatalogEntry) {
        self.init(
            id: entry.id,
            kind: entry.kind,
            title: entry.title,
            year: entry.year,
            lastViewedAt: entry.lastViewedAt
        )
    }

    /// "The Office (2005) · TV show": how a choice is read out when several
    /// titles match.
    var choiceLabel: String {
        let kindLabel = kind == .movie ? "Movie" : "TV show"
        guard let year else { return "\(title) · \(kindLabel)" }
        return "\(title) (\(year)) · \(kindLabel)"
    }
}
