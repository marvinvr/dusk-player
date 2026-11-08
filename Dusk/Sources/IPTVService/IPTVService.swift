import Foundation
import OSLog

private let iptvLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "IPTV"
)

/// The user's IPTV sources for the active Plex profile and their loaded
/// lineups. One shared instance (`DuskApp`), read by Settings and by
/// `LiveTVViewModel`, which shows the lineups after the Plex channels.
@MainActor
@Observable
final class IPTVService {
    private let plexService: PlexService
    private let store: IPTVSourceStore
    private let loader: IPTVSourceLoader

    private(set) var sources: [IPTVSource] = []
    /// In source order; a source whose playlist never loaded is absent.
    private(set) var lineups: [IPTVSourceLineup] = []
    /// Why a source's playlist failed to load, by source id.
    private(set) var sourceErrors: [UUID: String] = [:]
    private(set) var isLoading = false

    private var profileID: String?
    private var loadedAt: [UUID: Date] = [:]
    private var reloadRequested = false

    init(
        plexService: PlexService,
        store: IPTVSourceStore = IPTVSourceStore(),
        loader: IPTVSourceLoader = IPTVSourceLoader()
    ) {
        self.plexService = plexService
        self.store = store
        self.loader = loader
        syncProfile()
    }

    var hasSources: Bool { !sources.isEmpty }

    /// Re-reads the sources when the Plex Home profile changed. Cheap; called
    /// before every load and when Settings opens.
    func syncProfile() {
        let current = plexService.activeProfileID ?? Self.noProfileID
        guard current != profileID else { return }
        profileID = current
        sources = store.sources(profileID: current)
        lineups = []
        sourceErrors = [:]
        loadedAt = [:]
        #if DEBUG
        if sources.isEmpty, let seeded = ScreenshotMode.seededIPTVSource {
            persist([seeded.source])
            store.setHeaderValue(seeded.headerValue, for: seeded.source.id)
        }
        #endif
    }

    // MARK: - Editing

    func headerValue(for source: IPTVSource) -> String? {
        store.headerValue(for: source.id)
    }

    /// Adds the source, or replaces the one with the same id.
    func save(_ source: IPTVSource, headerValue: String?) {
        syncProfile()
        var updated = sources
        if let index = updated.firstIndex(where: { $0.id == source.id }) {
            updated[index] = source
        } else {
            updated.append(source)
        }
        persist(updated)
        store.setHeaderValue(source.headerName == nil ? nil : headerValue, for: source.id)
        loadedAt[source.id] = nil
        Task { await load() }
    }

    func delete(_ source: IPTVSource) {
        syncProfile()
        persist(sources.filter { $0.id != source.id })
        store.setHeaderValue(nil, for: source.id)
        lineups.removeAll { $0.source.id == source.id }
        sourceErrors[source.id] = nil
        loadedAt[source.id] = nil
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var updated = sources
        updated.move(fromOffsets: offsets, toOffset: destination)
        persist(updated)
        lineups = updated.compactMap { source in lineups.first { $0.source.id == source.id } }
    }

    private func persist(_ updated: [IPTVSource]) {
        sources = updated
        store.save(updated, profileID: profileID ?? Self.noProfileID)
    }

    // MARK: - Loading

    /// Loads every source that has not loaded within `refreshInterval`.
    /// Sources load in parallel; one slow or broken source never holds the
    /// others back.
    func load(force: Bool = false, now: Date = .now) async {
        syncProfile()
        guard !isLoading else {
            reloadRequested = true
            return
        }
        isLoading = true
        defer { isLoading = false }

        repeat {
            reloadRequested = false
            let due = sources.filter { source in
                force || loadedAt[source.id].map { now.timeIntervalSince($0) >= Self.refreshInterval } ?? true
            }
            guard !due.isEmpty else { break }
            let requests = due.map { ($0, store.headerValue(for: $0.id)) }
            let loader = loader
            let profileAtStart = profileID

            await withTaskGroup(of: IPTVSourceLoad.self) { group in
                for (source, headerValue) in requests {
                    group.addTask {
                        let outcome = await Result.capturing {
                            try await loader.load(source: source, headerValue: headerValue)
                        }
                        return IPTVSourceLoad(source: source, outcome: outcome)
                    }
                }
                for await load in group {
                    let source = load.source
                    guard profileAtStart == profileID,
                          let current = sources.first(where: { $0.id == source.id }),
                          current == source else { continue }
                    apply(load.outcome, for: source)
                }
            }
        } while reloadRequested && !Task.isCancelled
    }

    private func apply(_ result: Result<IPTVSourceLineup, Error>, for source: IPTVSource) {
        switch result {
        case .success(let lineup):
            loadedAt[source.id] = .now
            sourceErrors[source.id] = nil
            var updated = lineups.filter { $0.source.id != source.id }
            updated.append(lineup)
            let order = sources.map(\.id)
            lineups = updated.sorted {
                (order.firstIndex(of: $0.source.id) ?? .max) < (order.firstIndex(of: $1.source.id) ?? .max)
            }
            if let guideError = lineup.guideError {
                iptvLogger.notice("IPTV source guide failed: \(guideError, privacy: .public)")
            }
        case .failure(let error):
            // Keep the channels of an earlier good load on screen.
            sourceErrors[source.id] = error.localizedDescription
            iptvLogger.error("IPTV source failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Channel count or the load error, for Settings.
    func status(for source: IPTVSource) -> String {
        if let error = sourceErrors[source.id] { return error }
        guard let lineup = lineups.first(where: { $0.source.id == source.id }) else {
            return isLoading ? "Loading…" : "Not loaded"
        }
        let count = lineup.lineup.guides.count
        let channels = count == 1 ? "1 channel" : "\(count) channels"
        return lineup.guideError == nil ? channels : "\(channels) · No guide"
    }

    static let refreshInterval: TimeInterval = 30 * 60
    private static let noProfileID = "-"
}

/// The network half: fetch and parse a source's playlist and guide. No UI
/// state, so it runs off the main actor.
/// One source's answer in `IPTVService.load`'s task group. A named type built
/// in one place on purpose: see `Result.capturing`.
private struct IPTVSourceLoad: Sendable {
    let source: IPTVSource
    let outcome: Result<IPTVSourceLineup, any Error>
}

struct IPTVSourceLoader: Sendable {
    var session: URLSession = .shared

    static func headers(for source: IPTVSource, headerValue: String?) -> [String: String] {
        guard let name = source.headerName?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
              let value = headerValue?.nilIfEmpty else { return [:] }
        return [name: value]
    }

    func load(source: IPTVSource, headerValue: String?, now: Date = .now) async throws -> IPTVSourceLineup {
        let headers = Self.headers(for: source, headerValue: headerValue)
        let playlist = try await fetchPlaylist(source.playlistURL, headers: headers)

        var guide = IPTVGuide.empty
        var guideError: String?
        if let guideURL = source.guideURL ?? playlist.guideURLs.first {
            do {
                guide = try await fetchGuide(
                    guideURL,
                    headers: headers,
                    options: XMLTVParser.Options(
                        window: Self.guideWindow(catchUpDays: IPTVLineupBuilder.catchUpDays(for: playlist), now: now),
                        channelIDs: IPTVLineupBuilder.wantedGuideChannelIDs(for: playlist)
                    )
                )
            } catch {
                guideError = error.localizedDescription
            }
        }

        let lineup = IPTVLineupBuilder.lineup(
            source: source,
            playlist: playlist,
            guide: guide,
            sourceHeaders: headers
        )
        return IPTVSourceLineup(source: source, lineup: lineup, guideError: guideError)
    }

    /// What of the XMLTV file is kept: a day back (what the "Now" guide can
    /// show of the past: since midnight, at least 12 hours), or a channel's
    /// whole catch-up window, and eight days ahead.
    static func guideWindow(catchUpDays: Int, now: Date) -> ClosedRange<Date> {
        let past = (TimeInterval(max(catchUpDays, 1)) * 24 + 1) * 60 * 60
        return now.addingTimeInterval(-past)...now.addingTimeInterval(8 * 24 * 60 * 60)
    }

    func fetchPlaylist(_ url: URL, headers: [String: String]) async throws -> IPTVPlaylist {
        let (data, response) = try await session.data(for: request(url, headers: headers))
        try Self.validate(response, what: "playlist")
        let playlist = M3UParser.parse(data)
        guard !playlist.entries.isEmpty else { throw IPTVLoadError.emptyPlaylist }
        return playlist
    }

    /// Downloaded to a file and streamed through the parser on a background
    /// thread: guides of tens of megabytes are normal.
    func fetchGuide(_ url: URL, headers: [String: String], options: XMLTVParser.Options) async throws -> IPTVGuide {
        let (fileURL, response) = try await session.download(for: request(url, headers: headers))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Self.validate(response, what: "program guide")
        return try await Task.detached(priority: .utility) {
            try XMLTVParser.parse(fileURL: fileURL, options: options)
        }.value
    }

    private func request(_ url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private static func validate(_ response: URLResponse, what: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw IPTVLoadError.httpStatus(http.statusCode, what: what)
        }
    }
}

enum IPTVLoadError: LocalizedError {
    case emptyPlaylist
    case httpStatus(Int, what: String)

    var errorDescription: String? {
        switch self {
        case .emptyPlaylist:
            "The playlist has no channels."
        case .httpStatus(let status, let what):
            switch status {
            case 401, 403: "The \(what) was refused (HTTP \(status)). Check the source’s header."
            case 404: "The \(what) wasn’t found (HTTP 404)."
            default: "The \(what) couldn’t be loaded (HTTP \(status))."
            }
        }
    }
}
