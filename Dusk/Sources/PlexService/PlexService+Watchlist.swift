import Foundation
import OSLog

/// The account's Plex Watchlist, on plex.tv's Discover provider.
///
/// Undocumented but stable (every Plex client, Overseerr/Seerr and Kometa use
/// it). Verified against a real account on 2026-10-25:
/// - `GET /library/sections/watchlist/all?sort=watchlistedAt:desc`, paged with
///   `X-Plex-Container-Start/Size`, `totalSize` in the container;
/// - `PUT /actions/addToWatchlist?ratingKey=` / `removeFromWatchlist`, both
///   idempotent (200 with an empty container either way);
/// - `GET /library/metadata/{ratingKey}` carries the `Guid` array (tmdb/imdb);
/// - `GET /library/metadata/{ratingKey}/availabilities` lists services.
///
/// The ratingKey is the hex id that ends a modern server item's `plex://`
/// guid, so a server item needs no lookup to be added. Matching the other
/// way asks each connected server `/library/all?guid=plex://…`.
///
/// Everything here degrades to "no Watchlist": a failure is logged by outcome
/// only and never surfaces on Home.
extension PlexService {
    static var discoverBase: String {
        #if DEBUG
        if let override = ScreenshotMode.discoverBase { return override }
        #endif
        return "https://discover.provider.plex.tv"
    }

    /// plex.tv is a nicety for Home: a LAN-only session must not wait on it.
    private static let watchlistRequestTimeout: TimeInterval = 8
    private static let watchlistPageSize = 100
    /// Large watchlists stop here; Home shows the newest ones anyway.
    private static let watchlistMaxEntries = 500
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
        async let homeHubs = loadPlexHomeLayout()
        let entries: [PlexWatchlistEntry]
        do {
            entries = try await fetchWatchlistEntries()
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

    private struct WatchlistPage: Decodable {
        struct Container: Decodable {
            let totalSize: Int?
            let size: Int?
            let Metadata: [FailableWatchlistEntry]?
        }
        let MediaContainer: Container
    }

    /// One undecodable entry (a type Plex added later) must not lose the list.
    private struct FailableWatchlistEntry: Decodable {
        let entry: PlexWatchlistEntry?
        init(from decoder: any Decoder) throws {
            entry = try? PlexWatchlistEntry(from: decoder)
        }
    }

    private func fetchWatchlistEntries() async throws -> [PlexWatchlistEntry] {
        var entries: [PlexWatchlistEntry] = []
        var start = 0
        while start < Self.watchlistMaxEntries {
            let data = try await discoverRequest(
                path: "/library/sections/watchlist/all",
                queryItems: [
                    URLQueryItem(name: "sort", value: "watchlistedAt:desc"),
                    URLQueryItem(name: "includeCollections", value: "1"),
                    URLQueryItem(name: "includeExternalMedia", value: "1"),
                    URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(Self.watchlistPageSize)),
                ]
            )
            let container = try decodeJSON(WatchlistPage.self, from: data).MediaContainer
            let page = container.Metadata ?? []
            entries += page.compactMap(\.entry).filter { $0.type == .movie || $0.type == .show }
            start += page.count
            guard !page.isEmpty, start < (container.totalSize ?? 0) else { break }
        }
        var seen = Set<String>()
        return entries.filter { seen.insert($0.guid).inserted }
    }

    // MARK: - Server matching

    /// Each entry's copy on the highest-priority connected server, skipping
    /// libraries hidden on the account. Per-title lookups only: a full guid
    /// index of a 60k library is never built.
    private func matchWatchlist(
        _ entries: [PlexWatchlistEntry],
        serverIDs: [String]
    ) async -> [String: PlexItem] {
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
        var found: [String: [String: PlexItem]] = [:]
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

        var matches: [String: PlexItem] = [:]
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

    func serverItems(guid: String, serverID: String) async throws -> [PlexItem] {
        let data = try await rawServerRequest(
            path: "/library/all",
            queryItems: [
                URLQueryItem(name: "guid", value: guid),
                URLQueryItem(name: "includeGuids", value: "1"),
            ],
            serverID: serverID
        )
        return try decodeJSON(MetadataResponse<PlexItem>.self, from: data, serverID: serverID)
            .MediaContainer.Metadata ?? []
    }

    // MARK: - Edits

    /// Adds or removes a title, optimistically: the store changes first and
    /// is restored if plex.tv refuses. Throws that refusal for the caller's
    /// inline error.
    func setWatchlisted(_ watchlisted: Bool, entry: PlexWatchlistEntry, match: PlexItem? = nil) async throws {
        let snapshot = watchlist.apply(watchlisted: watchlisted, entry: entry, match: match)
        do {
            _ = try await discoverRequest(
                method: "PUT",
                path: watchlisted ? "/actions/addToWatchlist" : "/actions/removeFromWatchlist",
                queryItems: [URLQueryItem(name: "ratingKey", value: entry.ratingKey)]
            )
        } catch {
            logWatchlistFailure(watchlisted ? "add" : "remove", error: error)
            watchlist.restore(snapshot)
            throw error
        }
        // Added from a detail page, which has no `PlexItem` to show: read the
        // list back so the Home card finds its server copy.
        if watchlisted, match == nil {
            Task { await loadWatchlist(force: true) }
        }
    }

    // MARK: - Details (titles not on a server)

    private struct MetadataPage: Decodable {
        struct Container: Decodable {
            let Metadata: [PlexWatchlistEntry]?
            let Availability: [PlexWatchlistAvailability]?
        }
        let MediaContainer: Container
    }

    func getWatchlistMetadata(ratingKey: String) async throws -> PlexWatchlistEntry? {
        let data = try await discoverRequest(path: "/library/metadata/\(ratingKey)")
        return try decodeJSON(MetadataPage.self, from: data).MediaContainer.Metadata?.first
    }

    func getWatchlistAvailabilities(ratingKey: String) async throws -> [PlexWatchlistAvailability] {
        let data = try await discoverRequest(path: "/library/metadata/\(ratingKey)/availabilities")
        return try decodeJSON(MetadataPage.self, from: data).MediaContainer.Availability ?? []
    }

    // MARK: - Plex's Home layout

    /// The rows of Plex's own Home, as Plex Web stores them. plex.tv keeps the
    /// `experience` setting per `X-Plex-Product` (verified: Dusk's own copy
    /// holds only the sidebar), and Plex Web's is the one where "Manage Home"
    /// lands. nil when it is the default layout or cannot be read.
    private func loadPlexHomeLayout() async -> [PlexHomeHubSetting]? {
        guard let token = activeAccountToken?.nilIfEmpty,
              let url = buildURL(
                  base: Self.plexTVBase,
                  path: "/api/v2/user",
                  queryItems: [URLQueryItem(name: "includeSettings", value: "1")]
              ) else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.watchlistRequestTimeout
        applyHeaders(to: &request, token: token)
        request.setValue("Plex Web", forHTTPHeaderField: "X-Plex-Product")

        guard let data = try? await executeRequest(request, retriesFreshAuthentication: false),
              let root = try? decoder.decode(DuskJSONValue.self, from: data),
              let setting = root["settings"]?.arrayValue?.first(where: { $0["id"]?.stringValue == "experience" }),
              let blob = setting["value"]?.stringValue.flatMap(DuskJSONValue.decode(jsonString:)),
              let home = blob["homeSettings"],
              home["hasCustomizations"]?.boolValue == true,
              let hubs = home["hubs"]?.arrayValue, !hubs.isEmpty else { return nil }
        return hubs.compactMap(PlexHomeHubSetting.init(raw:))
    }

    // MARK: - Transport

    /// A plex.tv Discover request as the active profile. A 401 here is "this
    /// profile has no Watchlist", never a reason to re-authenticate.
    private func discoverRequest(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> Data {
        guard let token = activeAccountToken?.nilIfEmpty else {
            throw PlexServiceError.notAuthenticated
        }
        guard let url = buildURL(base: Self.discoverBase, path: path, queryItems: queryItems) else {
            throw PlexServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.watchlistRequestTimeout
        applyHeaders(to: &request, token: token)
        return try await executeRequest(request, retriesFreshAuthentication: false)
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
    let type: PlexMediaType
    let serverID: String

    var missKey: String { "\(serverID)|\(guid)" }
}

private struct WatchlistMatchResult: Sendable {
    let job: WatchlistMatchJob
    let item: PlexItem?
    let failed: Bool
}

let watchlistLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "Watchlist"
)
