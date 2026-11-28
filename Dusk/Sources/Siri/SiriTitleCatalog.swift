import AppIntents
import Foundation
import OSLog

private let siriCatalogLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "Siri"
)

/// One movie or show Siri can recognise by name.
struct SiriCatalogEntry: Codable, Hashable, Sendable {
    let id: MediaItemID
    let kind: SiriTitleKind
    let title: String
    let year: Int?
    let lastViewedAt: Int?
}

/// The movies and shows Dusk registers with Siri.
///
/// App Shortcut phrases with a title in them ("Play Severance in Dusk") only
/// match titles the app has registered in advance, so this keeps the ones the
/// user is most likely to ask for: what they watched recently, then what was
/// added recently, across every connected server. It is refreshed when servers
/// connect and is also what Siri falls back to before any server has.
///
/// Stored in UserDefaults and owned by the signed-in identity: sign-out and
/// Plex Home switches clear it, like the Top Shelf.
@MainActor
final class SiriTitleCatalog {
    static let shared = SiriTitleCatalog()

    static let capacity = 300
    private static let recentlyWatchedPerLibrary = 80
    private static let recentlyAddedPerLibrary = 30
    private static let refreshInterval: TimeInterval = 30 * 60
    private static let defaultsKey = "siriTitleCatalog"

    private struct Stored: Codable {
        let profileID: String
        let refreshedAt: Date
        let entries: [SiriCatalogEntry]
        /// The libraries that were hidden when it was built. Hiding or showing
        /// one rebuilds the catalog, so Siri never offers a hidden title.
        let hiddenLibraryIDs: Set<String>?
    }

    private var stored: Stored?
    private var refreshTask: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey) {
            stored = try? JSONDecoder().decode(Stored.self, from: data)
        }
    }

    var entries: [SiriCatalogEntry] {
        stored?.entries ?? []
    }

    func entry(for id: MediaItemID) -> SiriCatalogEntry? {
        entries.first { $0.id == id }
    }

    func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        guard stored != nil else { return }
        stored = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        Self.updateSiriVocabulary()
    }

    /// Rebuilds the catalog from the connected servers unless it is fresh.
    func refreshIfNeeded(plexService: PlexService, now: Date = .now) async {
        guard plexService.isSessionReady,
              let profileID = plexService.activeProfileID,
              !plexService.pool.connections.isEmpty else { return }

        let hiddenLibraries = await plexService.loadedHiddenLibraryFilter(for: .search)
        let hiddenLibrariesChanged = (stored?.hiddenLibraryIDs ?? []) != hiddenLibraries.hiddenLibraryIDs

        if let stored,
           stored.profileID == profileID,
           !hiddenLibrariesChanged,
           now.timeIntervalSince(stored.refreshedAt) < Self.refreshInterval {
            return
        }

        if let refreshTask {
            await refreshTask.value
            return
        }

        let task = Task { @MainActor in
            let entries = await Self.fetchEntries(plexService: plexService, hiddenLibraries: hiddenLibraries)
            // An empty answer normally means the servers did not answer; after
            // a hide it can also mean every library is hidden now.
            guard !Task.isCancelled,
                  plexService.activeProfileID == profileID,
                  !entries.isEmpty || hiddenLibrariesChanged else { return }

            let previous = self.stored?.profileID == profileID ? self.entries : []
            self.store(Stored(
                profileID: profileID,
                refreshedAt: .now,
                entries: entries,
                hiddenLibraryIDs: hiddenLibraries.hiddenLibraryIDs
            ))
            if entries != previous {
                Self.updateSiriVocabulary()
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func store(_ value: Stored) {
        stored = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Re-reads `PlayTitleEntityQuery.suggestedEntities()`, which is what
    /// teaches Siri the titles in the App Shortcut phrases.
    private static func updateSiriVocabulary() {
        DuskAppShortcuts.updateAppShortcutParameters()
    }

    /// Recently watched first (most recent at the top, across servers), then
    /// recently added, one copy per title.
    private static func fetchEntries(
        plexService: PlexService,
        hiddenLibraries: HiddenLibraryFilter
    ) async -> [SiriCatalogEntry] {
        let perServer = await plexService.fanOutAcrossServers { service, serverID in
            await recentItems(service: service, serverID: serverID, hiddenLibraries: hiddenLibraries)
        }

        let watched = perServer
            .flatMap(\.value.watched)
            .sorted { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }
        let added = perServer.flatMap(\.value.added)

        var seen: Set<String> = []
        var entries: [SiriCatalogEntry] = []
        for item in watched + added {
            guard entries.count < capacity,
                  let entry = entry(for: item) else { continue }
            let identity = "\(entry.kind.rawValue)|\(SiriTitleNormalizer.tokens(entry.title).joined())|\(entry.year.map(String.init) ?? "")"
            guard seen.insert(identity).inserted else { continue }
            entries.append(entry)
        }
        return entries
    }

    private static func recentItems(
        service: PlexService,
        serverID: String,
        hiddenLibraries: HiddenLibraryFilter
    ) async -> (watched: [MediaItem], added: [MediaItem]) {
        let libraries: [Library]
        do {
            libraries = try await service.getLibraries(serverID: serverID)
        } catch {
            siriCatalogLogger.error("Siri catalog: libraries failed: \(error.localizedDescription, privacy: .public)")
            return ([], [])
        }

        var watched: [MediaItem] = []
        var added: [MediaItem] = []
        for library in libraries
        where (library.libraryType == .movie || library.libraryType == .show) && !hiddenLibraries.hides(library) {
            if let items = try? await service.getLibraryItems(
                sectionId: library.key,
                size: recentlyWatchedPerLibrary,
                sort: "lastViewedAt:desc",
                serverID: serverID
            ) {
                watched += items.filter { $0.lastViewedAt != nil }
            }
            if let items = try? await service.getLibraryItems(
                sectionId: library.key,
                size: recentlyAddedPerLibrary,
                sort: "addedAt:desc",
                serverID: serverID
            ) {
                added += items
            }
        }
        return (watched, added)
    }

    private static func entry(for item: MediaItem) -> SiriCatalogEntry? {
        guard !item.isClip else { return nil }
        let kind: SiriTitleKind
        switch item.type {
        case .movie: kind = .movie
        case .show: kind = .show
        default: return nil
        }
        return SiriCatalogEntry(
            id: item.id,
            kind: kind,
            title: item.title,
            year: item.year,
            lastViewedAt: item.lastViewedAt
        )
    }
}
