import Foundation

/// The account's Plex Watchlist, shared by the Home row, the detail-page
/// bookmark and the card context menus so an edit in one shows everywhere.
/// `PlexService+Watchlist` loads it; screens change it only through
/// `PlexService.setWatchlisted`, which edits optimistically and rolls back.
///
/// The list itself is account-level (plex.tv), so it is per profile.
/// `matches` maps each entry's `guid` to the copy on the highest-priority
/// connected server, if any; an entry without one is "not on your servers".
///
/// Failure is quiet by design: a list that could not be read is
/// `.unavailable`, which every consumer treats like an empty list (no Home
/// row, no bookmark). It never blanks anything else.
@MainActor
@Observable
final class WatchlistStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        /// plex.tv failed or this profile has no Watchlist. Nothing shows.
        case unavailable
    }

    private(set) var entries: [WatchlistEntry] = []
    private(set) var matches: [String: MediaItem] = [:]
    private(set) var state: State = .idle
    /// Plex Web's own Home layout, when the account customized it; nil means
    /// Plex's default layout (or that it could not be read).
    private(set) var homeHubs: [PlexHomeHubSetting]?

    @ObservationIgnored private(set) var loadedAt: Date?
    @ObservationIgnored private(set) var profileID: String?
    /// The connected servers (priority order) `matches` was built against.
    @ObservationIgnored private(set) var matchedServerIDs: [String] = []
    @ObservationIgnored var loadTask: Task<Void, Never>?
    /// The servers `loadTask` matches against.
    @ObservationIgnored var loadingServerIDs: [String] = []
    /// `"<serverID>|<guid>"` → when that server last said it does not have
    /// the title. Hits are never cached: they are re-read for their progress.
    @ObservationIgnored var missCheckedAt: [String: Date] = [:]
    /// Bumped by every load, edit and `reset`: an answer from before is
    /// dropped instead of undoing what came after it.
    @ObservationIgnored private(set) var generation = 0

    var isLoaded: Bool { state == .loaded }

    /// Watchlist membership by `guid`; nil while it is not known, which hides
    /// the bookmark rather than showing a guess.
    func contains(guid: String?) -> Bool? {
        guard isLoaded, let guid else { return nil }
        return entries.contains { $0.guid == guid }
    }

    func match(for entry: WatchlistEntry) -> MediaItem? {
        matches[entry.guid]
    }

    func isFresh(profileID: String?, serverIDs: [String], maxAge: TimeInterval) -> Bool {
        guard isLoaded, self.profileID == profileID, matchedServerIDs == serverIDs,
              let loadedAt else { return false }
        return Date().timeIntervalSince(loadedAt) < maxAge
    }

    // MARK: - Loading (PlexService+Watchlist)

    func beginLoad(profileID: String?) -> Int {
        generation += 1
        if self.profileID != profileID {
            entries = []
            matches = [:]
            homeHubs = nil
            state = .idle
            loadedAt = nil
            missCheckedAt = [:]
        }
        self.profileID = profileID
        if state != .loaded {
            state = .loading
        }
        return generation
    }

    func commit(
        entries: [WatchlistEntry],
        matches: [String: MediaItem],
        homeHubs: [PlexHomeHubSetting]?,
        serverIDs: [String],
        generation expected: Int
    ) {
        guard expected == generation else { return }
        self.entries = entries
        self.matches = matches
        self.homeHubs = homeHubs
        matchedServerIDs = serverIDs
        loadedAt = Date()
        state = .loaded
    }

    func fail(generation expected: Int) {
        guard expected == generation else { return }
        // Plex being down for a moment must not take away a list that was
        // already on screen; only a list never read stays hidden.
        if state != .loaded {
            state = .unavailable
        }
    }

    func reset() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        entries = []
        matches = [:]
        homeHubs = nil
        state = .idle
        loadedAt = nil
        profileID = nil
        matchedServerIDs = []
        missCheckedAt = [:]
    }

    // MARK: - Edits

    struct Snapshot {
        fileprivate let entries: [WatchlistEntry]
        fileprivate let matches: [String: MediaItem]
    }

    /// Applies an add or remove before plex.tv confirms it. Returns what to
    /// restore if it fails. Newest first, like Plex lists it.
    func apply(
        watchlisted: Bool,
        entry: WatchlistEntry,
        match: MediaItem?
    ) -> Snapshot {
        let snapshot = Snapshot(entries: entries, matches: matches)
        generation += 1
        entries.removeAll { $0.guid == entry.guid }
        if watchlisted {
            entries.insert(entry, at: 0)
            if let match {
                matches[entry.guid] = match
            }
        }
        return snapshot
    }

    func restore(_ snapshot: Snapshot) {
        generation += 1
        entries = snapshot.entries
        matches = snapshot.matches
    }
}
