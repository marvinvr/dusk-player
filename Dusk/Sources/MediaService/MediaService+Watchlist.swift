import Foundation
import OSLog

/// The account's watchlist, routed to the account's `WatchlistProviding`
/// (docs/jellyfin/04-architecture.md §17; Plex: `PlexWatchlist`, plex.tv
/// Discover). Matching each title to a copy on a connected server asks each
/// server `/library/all?guid=plex://…`.
///
/// Everything here degrades to "no Watchlist": a failure is logged by outcome
/// only and never surfaces on Home.
extension MediaService {
    /// The signed-in account's watchlist facet. One Plex account until the
    /// account layer (P0-16) and Jellyfin (J-01) add others; built here like
    /// `accountPreferences`.
    var watchlistProvider: (any WatchlistProviding)? {
        PlexWatchlist(client: client, transport: self)
    }

    /// How long a loaded list is reused when Home reloads.
    private static let watchlistMaxAge: TimeInterval = 120
    /// How long "this title is not on that server" is believed before asking
    /// again. A hit is re-read every load so its progress stays current.
    private static let watchlistMissMaxAge: TimeInterval = 30 * 60
    private static let watchlistMatchConcurrency = 4

    // MARK: - Load

    /// Loads the list, Plex's Home layout and the server matches. Joins a
    /// load already running; reuses a recent one unless `force`.
    func loadWatchlist(force: Bool = false) async {
        guard activeAccountToken?.nilIfEmpty != nil, let profileID = activeProfileID else { return }
        let serverIDs = mergeServerIDs
        if !force, watchlist.isFresh(profileID: profileID, serverIDs: serverIDs, maxAge: Self.watchlistMaxAge) {
            return
        }
        // Join a load already running for the same servers. One started
        // before a server connected cannot match against it, so a load for a
        // different server set replaces it.
        if !force, let running = watchlist.loadTask, watchlist.loadingServerIDs == serverIDs {
            await running.value
            return
        }

        watchlist.loadTask?.cancel()
        let generation = watchlist.beginLoad(profileID: profileID)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performWatchlistLoad(serverIDs: serverIDs, generation: generation)
        }
        watchlist.loadTask = task
        watchlist.loadingServerIDs = serverIDs
        await task.value
        if watchlist.loadTask == task {
            watchlist.loadTask = nil
        }
    }

    private func performWatchlistLoad(serverIDs: [String], generation: Int) async {
        let provider = watchlistProvider
        async let homeHubs = provider?.homeLayout()
        let entries: [WatchlistEntry]
        do {
            guard let provider else { throw PlexServiceError.notAuthenticated }
            entries = try await provider.entries()
        } catch {
            logWatchlistFailure("list", error: error)
            _ = await homeHubs
            watchlist.fail(generation: generation)
            return
        }

        let matches = await matchWatchlist(entries, serverIDs: serverIDs)
        let layout = await homeHubs
        guard !Task.isCancelled else { return }
        watchlist.commit(
            entries: entries,
            matches: matches,
            homeHubs: layout,
            serverIDs: serverIDs,
            generation: generation
        )
        watchlistLogger.notice(
            "Watchlist: \(entries.count, privacy: .public) titles, \(matches.count, privacy: .public) on a server"
        )
    }

    // MARK: - Server matching

    /// Each entry's copy on the highest-priority connected server, skipping
    /// libraries hidden on the account. Per-title lookups only: a full guid
    /// index of a 60k library is never built.
    private func matchWatchlist(
        _ entries: [WatchlistEntry],
        serverIDs: [String]
    ) async -> [String: MediaItem] {
        guard !serverIDs.isEmpty, !entries.isEmpty else { return [:] }
        let hidden = await loadedHiddenLibraryFilter()
        let previous = watchlist.matches
        let now = Date()

        var jobs: [WatchlistMatchJob] = []
        for entry in entries {
            for serverID in serverIDs {
                if let checked = watchlist.missCheckedAt["\(serverID)|\(entry.guid)"],
                   now.timeIntervalSince(checked) < Self.watchlistMissMaxAge {
                    continue
                }
                jobs.append(WatchlistMatchJob(guid: entry.guid, type: entry.type, serverID: serverID))
            }
        }

        let service = self
        var found: [String: [String: MediaItem]] = [:]
        var misses = Set<String>()
        var next = 0
        var completed = 0
        await withTaskGroup(of: WatchlistMatchResult.self) { group in
            while next < jobs.count || !group.isEmpty {
                while next < jobs.count, next < Self.watchlistMatchConcurrency + completed {
                    let job = jobs[next]
                    next += 1
                    group.addTask { await service.matchWatchlistJob(job, hidden: hidden) }
                }
                guard let result = await group.next() else { break }
                completed += 1
                let key = result.job.missKey
                if let item = result.item {
                    found[result.job.guid, default: [:]][result.job.serverID] = item
                    watchlist.missCheckedAt[key] = nil
                } else if !result.failed {
                    misses.insert(key)
                    watchlist.missCheckedAt[key] = now
                }
            }
        }

        var matches: [String: MediaItem] = [:]
        for entry in entries {
            if let item = serverIDs.lazy.compactMap({ found[entry.guid]?[$0] }).first {
                matches[entry.guid] = item
            } else if let item = previous[entry.guid], let serverID = item.serverID,
                      serverIDs.contains(serverID),
                      !misses.contains("\(serverID)|\(entry.guid)") {
                // A lookup that failed, or was not due, keeps the last answer
                // rather than flipping the card to "not on your servers".
                matches[entry.guid] = item
            }
        }
        return matches
    }

    private func matchWatchlistJob(_ job: WatchlistMatchJob, hidden: HiddenLibraryFilter) async -> WatchlistMatchResult {
        do {
            let items = try await serverItems(guid: job.guid, serverID: job.serverID)
            let item = items.first { $0.type == job.type && !hidden.hides($0) }
            return WatchlistMatchResult(job: job, item: item, failed: false)
        } catch {
            return WatchlistMatchResult(job: job, item: nil, failed: true)
        }
    }

    func serverItems(guid: String, serverID: String) async throws -> [MediaItem] {
        let data = try await rawServerRequest(
            path: "/library/all",
            queryItems: [
                URLQueryItem(name: "guid", value: guid),
                URLQueryItem(name: "includeGuids", value: "1"),
            ],
            serverID: serverID
        )
        return try decodeJSON(MetadataResponse<MediaItem>.self, from: data, serverID: serverID)
            .MediaContainer.Metadata ?? []
    }

    // MARK: - Edits

    /// Adds or removes a title, optimistically: the store changes first and
    /// is restored if plex.tv refuses. Throws that refusal for the caller's
    /// inline error.
    func setWatchlisted(_ watchlisted: Bool, entry: WatchlistEntry, match: MediaItem? = nil) async throws {
        let snapshot = watchlist.apply(watchlisted: watchlisted, entry: entry, match: match)
        do {
            guard let provider = watchlistProvider else { throw PlexServiceError.notAuthenticated }
            try await provider.setWatchlisted(watchlisted, entry: entry)
        } catch {
            logWatchlistFailure(watchlisted ? "add" : "remove", error: error)
            watchlist.restore(snapshot)
            throw error
        }
        // Added from a detail page, which has no `MediaItem` to show: read the
        // list back so the Home card finds its server copy.
        if watchlisted, match == nil {
            Task { await loadWatchlist(force: true) }
        }
    }

    // MARK: - Details (titles not on a server)

    func getWatchlistMetadata(itemID: String) async throws -> WatchlistEntry? {
        guard let provider = watchlistProvider else { throw PlexServiceError.notAuthenticated }
        return try await provider.details(itemID: itemID)
    }

    func getWatchlistAvailabilities(itemID: String) async throws -> [WatchlistAvailability] {
        guard let provider = watchlistProvider else { throw PlexServiceError.notAuthenticated }
        return try await provider.availabilities(itemID: itemID)
    }

    /// Outcomes only: requests carry the account token.
    private func logWatchlistFailure(_ stage: String, error: any Error) {
        let outcome: String
        switch error as? PlexServiceError {
        case .httpError(let statusCode)?: outcome = "HTTP \(statusCode)"
        case .unauthorized?: outcome = "unauthorized"
        case .requestTimedOut?: outcome = "timed out"
        case .networkError?: outcome = "network error"
        case .decodingError?: outcome = "decoding error"
        default: outcome = error is CancellationError ? "cancelled" : "unavailable"
        }
        watchlistLogger.notice("Watchlist \(stage, privacy: .public) failed: \(outcome, privacy: .public)")
    }
}

private struct WatchlistMatchJob: Sendable {
    let guid: String
    let type: MediaKind
    let serverID: String

    var missKey: String { "\(serverID)|\(guid)" }
}

private struct WatchlistMatchResult: Sendable {
    let job: WatchlistMatchJob
    let item: MediaItem?
    let failed: Bool
}

let watchlistLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "Watchlist"
)
