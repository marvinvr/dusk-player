import Foundation

/// Cached library order for the current (connected servers, Plex Home profile)
/// combination.
///
/// Holds every connected server's `/library/sections` list and the account's
/// `pinnedSources` list from plex.tv, and combines them into the effective
/// order every screen in Dusk uses. `PlexService+LibraryOrder` owns all
/// networking and is the only thing allowed to mutate the store; everything
/// else reads `orderedSections` / `orderedSectionIdentities`.
///
/// The cache is keyed by `"<connected serverIDs in priority order>|<profileID>"`:
/// the pinned list is per Plex account *token* (Plex Home members each have
/// their own), and the sections are only the ones the currently connected
/// servers answered with, so a server coming up or dropping out has to
/// invalidate it. The order is part of the key because the unpinned tail
/// follows server priority, so a reorder has to invalidate it too.
@MainActor
@Observable
final class LibraryOrderStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// `/library/sections` of every connected server, in server-priority order
    /// and then each server's own order, unfiltered — music and photo sections
    /// are kept even though Dusk cannot browse them, because Home hub
    /// regrouping and the write path both need every section.
    ///
    /// Assembled from `sectionsByServer` so a server that answers late slots
    /// into its own priority position instead of the end.
    private(set) var sections: [PlexLibrary] = []

    /// Sections per server, and the priority order to concatenate them in. Kept
    /// separately so one server's sections can be committed the moment they
    /// arrive without waiting for the slowest server.
    @ObservationIgnored private var sectionsByServer: [String: [PlexLibrary]] = [:]
    @ObservationIgnored private var serverOrder: [String] = []

    /// The account's complete pinned list: every server plus the cloud
    /// providers, exactly as plex.tv returned it. Never filtered down to the
    /// connected server — the entries of other sources have to survive a write.
    private(set) var pinnedSources: [PlexPinnedSource] = []

    private(set) var state: State = .idle

    /// True when the plex.tv `experience` blob could not be read (transport or
    /// auth failure). A missing or unparseable setting is *not* a failure: that
    /// just means the account never customized its order.
    private(set) var orderUnavailable = false

    /// Machine identifiers of the servers that answered `/library/sections`
    /// **with at least one section**. Only these may have their pins rewritten.
    ///
    /// An empty answer is deliberately excluded: it has nothing to write, and
    /// letting it participate would delete whatever the account has pinned for
    /// that server — an empty list is what a half-started or still-scanning
    /// server returns too.
    private(set) var machineIdentifiers: Set<String> = []

    /// Servers that were asked for their sections and failed.
    ///
    /// HARD INVARIANT: never write pinned entries for a server in this set. A
    /// failed `/library/sections` looks exactly like "this server has no
    /// libraries", and the write would unpin that server's libraries in every
    /// Plex client the account uses.
    private(set) var failedServerIDs: Set<String> = []

    /// `"<sorted serverIDs>|<profileID>"` of the cached data.
    private(set) var cacheIdentity: String?

    /// The whole decoded `experience` blob, kept so a write can preserve every
    /// key Dusk does not model. nil means "the account has no experience
    /// setting yet"; the first write then creates one.
    @ObservationIgnored private(set) var experienceBlob: DuskJSONValue?

    /// In-flight combined load, so concurrent callers (Home, Libraries, the
    /// settings screen, all racing at launch) share one pair of requests.
    @ObservationIgnored var loadTask: Task<[PlexLibrary], Error>?

    /// Tail of the write chain. Writes are last-writer-wins on plex.tv, so they
    /// are serialized locally and each one re-reads before it posts.
    @ObservationIgnored var writeTask: Task<Void, Error>?

    /// The order Dusk shows: sections pinned by the account first, in the
    /// account's sidebar order, then everything else in server-priority order.
    /// See `LibraryOrderArrangement`.
    var orderedSections: [PlexLibrary] {
        LibraryOrderArrangement.effectiveOrder(
            libraries: sections,
            pinnedSources: pinnedSources,
            machineIdentifiers: machineIdentifiers
        )
    }

    /// `PlexLibrary.id` (`"<serverID>|<key>"`) in effective order.
    var orderedSectionIdentities: [String] {
        orderedSections.map(\.id)
    }

    /// Drops everything cached. Called whenever the connected servers or the
    /// active profile change, so a stale order can never leak across accounts.
    func invalidate() {
        loadTask?.cancel()
        loadTask = nil
        sections = []
        sectionsByServer = [:]
        serverOrder = []
        pinnedSources = []
        experienceBlob = nil
        machineIdentifiers = []
        failedServerIDs = []
        cacheIdentity = nil
        orderUnavailable = false
        state = .idle
    }

    // MARK: - Mutation (PlexService+LibraryOrder only)

    func matchesCacheIdentity(_ identity: String) -> Bool {
        cacheIdentity == identity
    }

    /// Opens a load for exactly these servers, in priority order. Any server
    /// that is no longer connected loses its cached sections immediately, so a
    /// disabled server's libraries cannot linger on screen.
    func beginLoading(serverOrder: [String]) {
        state = .loading
        self.serverOrder = serverOrder
        let connected = Set(serverOrder)
        sectionsByServer = sectionsByServer.filter { connected.contains($0.key) }
        machineIdentifiers.formIntersection(connected)
        failedServerIDs.formIntersection(connected)
        rebuildSections()
    }

    func failLoading(_ message: String) {
        state = .failed(message)
    }

    /// Commits one server's sections as soon as they land, so the library list
    /// and Home paint from the first server that answers.
    ///
    /// `sections == nil` means the fetch failed: the server is recorded in
    /// `failedServerIDs` and must never have its pins rewritten. An empty
    /// (successful) answer is not a failure, but it does not make the server a
    /// participant in a write either — see `machineIdentifiers`.
    func applyServerSections(_ sections: [PlexLibrary]?, serverID: String) {
        if !serverOrder.contains(serverID) {
            serverOrder.append(serverID)
        }

        switch sections {
        case let sections? where !sections.isEmpty:
            sectionsByServer[serverID] = sections
            machineIdentifiers.insert(serverID)
            failedServerIDs.remove(serverID)
        case .some:
            sectionsByServer[serverID] = []
            machineIdentifiers.remove(serverID)
            failedServerIDs.remove(serverID)
        case .none:
            sectionsByServer[serverID] = nil
            machineIdentifiers.remove(serverID)
            failedServerIDs.insert(serverID)
        }

        rebuildSections()
    }

    /// Closes a load: records the account blob and the identity the cached data
    /// belongs to. The sections were already committed per server.
    func finishLoading(experience: PlexExperienceSettings?, identity: String) {
        cacheIdentity = identity
        if let experience {
            pinnedSources = experience.pinnedSources
            experienceBlob = experience.blob
            orderUnavailable = false
        } else {
            pinnedSources = []
            experienceBlob = nil
            orderUnavailable = true
        }
        state = .loaded
    }

    private func rebuildSections() {
        sections = serverOrder.flatMap { sectionsByServer[$0] ?? [] }
    }

    /// Commits a blob-only refresh, leaving `sections` alone.
    func apply(experience: PlexExperienceSettings, identity: String) {
        pinnedSources = experience.pinnedSources
        experienceBlob = experience.blob
        orderUnavailable = false
        cacheIdentity = identity
        if state != .loaded, !sections.isEmpty {
            state = .loaded
        }
    }

    /// Commits the exact payload that plex.tv just accepted, so the UI settles
    /// on the written order without another round trip.
    func commitWrite(pinnedSources: [PlexPinnedSource], blob: DuskJSONValue) {
        self.pinnedSources = pinnedSources
        experienceBlob = blob
        orderUnavailable = false
    }

    func clearLoadTask(_ task: Task<[PlexLibrary], Error>) {
        if loadTask == task {
            loadTask = nil
        }
    }

    func clearWriteTask(_ task: Task<Void, Error>) {
        if writeTask == task {
            writeTask = nil
        }
    }
}

/// The parsed plex.tv `experience` setting.
struct PlexExperienceSettings: Sendable {
    /// The whole blob, or nil when the account has no `experience` setting yet
    /// (or it was unparseable — both mean "never customized").
    var blob: DuskJSONValue?
    /// `sidebarSettings.pinnedSources`, in sidebar order.
    var pinnedSources: [PlexPinnedSource]

    static let neverCustomized = PlexExperienceSettings(blob: nil, pinnedSources: [])
}
