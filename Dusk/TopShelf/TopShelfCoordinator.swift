#if os(tvOS)
import Foundation
import BackgroundTasks
import OSLog
import TVServices

/// Owns the tvOS Top Shelf integration end to end:
///
/// 1. Produces the "Continue Watching" snapshot the extension renders and tells
///    the system to reload it (`topShelfContentDidChange`).
/// 2. Keeps that snapshot fresh — on app activation, after playback, and via a
///    periodic `BGAppRefreshTask` while the app is not running.
/// 3. Routes the `dusk://` deep link a selected Top Shelf item opens with, so the
///    connected tab shell can resume playback.
@MainActor
@Observable
final class TopShelfCoordinator {
    /// Background-refresh task identifier. Must match the value listed under
    /// `BGTaskSchedulerPermittedIdentifiers` in the tvOS app's Info.plist.
    static let backgroundRefreshIdentifier = "com.dusk-player.app.topshelf.refresh"

    private static let maxEntries = 12
    private static let refreshDebounce: TimeInterval = 20
    private static let imagePixelWidth = 1024
    private static let backgroundRefreshInterval: TimeInterval = 4 * 60 * 60

    /// Rating key the user selected from the Top Shelf that the connected tab
    /// shell should resume. Set when a `dusk://play` URL is opened and cleared
    /// once playback is started.
    var pendingPlayRatingKey: String?

    private let plexService: PlexService
    private var lastRefresh: Date = .distantPast
    private var isRefreshing = false

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
        category: "TopShelf"
    )

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    // MARK: - Deep links

    /// Parses an incoming `dusk://` URL and, if it is a play request, stores the
    /// target so the tab shell can resume it once connected.
    func handleOpenURL(_ url: URL) {
        guard let request = TopShelfDeepLink.playRequest(from: url) else { return }
        pendingPlayRatingKey = request.ratingKey
        Self.logger.notice("Top Shelf deep link received for ratingKey \(request.ratingKey, privacy: .public)")
    }

    /// Returns and clears the pending play target, if any.
    func consumePendingPlayRatingKey() -> String? {
        defer { pendingPlayRatingKey = nil }
        return pendingPlayRatingKey
    }

    // MARK: - Foreground snapshot updates

    /// Fetches the latest Continue Watching list and rewrites the snapshot.
    /// Debounced unless `force` is set, so frequent activations don't hammer the
    /// server. No-ops (preserving any existing snapshot) when not connected or on
    /// a transient fetch error.
    func refresh(force: Bool = false) async {
        guard plexService.isAuthenticated, plexService.isConnected else { return }
        if !force, Date.now.timeIntervalSince(lastRefresh) < Self.refreshDebounce { return }
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let items = try await plexService.getContinueWatching()
            Self.store(items: items, plexService: plexService)
            lastRefresh = .now
        } catch {
            Self.logger.error("Top Shelf refresh failed: \(error.localizedDescription, privacy: .public)")
            // Keep the previous snapshot on transient errors.
        }
    }

    /// Rewrites the snapshot from an already-fetched Continue Watching list,
    /// avoiding a redundant network round trip.
    func update(from items: [PlexItem]) {
        guard plexService.isAuthenticated, plexService.isConnected else { return }
        Self.store(items: items, plexService: plexService)
        lastRefresh = .now
    }

    /// Clears the snapshot when the user signs out so the Home screen stops
    /// showing another account's resumable items.
    func handleSignOut() {
        lastRefresh = .distantPast
        TopShelfSnapshotStore.clear()
        TVTopShelfContentProvider.topShelfContentDidChange()
        Self.logger.notice("Top Shelf snapshot cleared after sign-out")
    }

    // MARK: - Background refresh

    /// Submits the next periodic background refresh. Safe to call repeatedly;
    /// submission failures (e.g. on Simulator) are ignored.
    static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: backgroundRefreshInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.debug("Top Shelf background refresh not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Entry point for the SwiftUI `.backgroundTask(.appRefresh:)` handler.
    ///
    /// Uses a fresh `PlexService` (which restores the auth token from Keychain
    /// and the connected server from UserDefaults in its initializer) so it does
    /// not capture any main-actor app state into the `@Sendable` task closure.
    static func performBackgroundRefresh() async {
        defer { scheduleAppRefresh() }

        let service = PlexService()
        guard service.isAuthenticated, service.isConnected else { return }

        do {
            let items = try await service.getContinueWatching()
            store(items: items, plexService: service)
        } catch {
            logger.error("Top Shelf background refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Snapshot construction

    private static func store(items: [PlexItem], plexService: PlexService) {
        let entries = makeEntries(from: items, plexService: plexService)
        let snapshot = TopShelfSnapshot(
            generatedAt: .now,
            serverIdentifier: plexService.currentServerIdentifier,
            entries: entries
        )
        TopShelfSnapshotStore.save(snapshot)
        TVTopShelfContentProvider.topShelfContentDidChange()
        logger.notice("Top Shelf snapshot written with \(entries.count, privacy: .public) entries")
    }

    private static func makeEntries(from items: [PlexItem], plexService: PlexService) -> [TopShelfEntry] {
        items.prefix(maxEntries).compactMap { item in
            guard let actionURL = TopShelfDeepLink.playURL(
                ratingKey: item.ratingKey,
                mediaType: item.type.rawValue
            ) else {
                return nil
            }

            let imageURL = plexService.externalImageURL(
                for: item.topShelfImagePath,
                width: imagePixelWidth
            )

            return TopShelfEntry(
                ratingKey: item.ratingKey,
                mediaType: item.type.rawValue,
                title: item.continueWatchingDisplayTitle,
                subtitle: item.continueWatchingDisplaySubtitle,
                imageURLString: imageURL?.absoluteString,
                playbackProgress: item.posterProgress,
                actionURLString: actionURL.absoluteString
            )
        }
    }
}
#endif
