import Foundation

/// The account's watchlist (docs/jellyfin/04-architecture.md §17): the list,
/// adding and removing a title, and what the account knows about a title that
/// is on no server.
///
/// One value per account. Loading, matching entries to server copies, the
/// optimistic edit and its rollback are the facade's (`MediaService+Watchlist`,
/// `WatchlistStore`). The methods run on the main actor, where the facade and
/// its request routing live.
///
/// `HomeLayoutHub` keeps its Plex name until the boundary pass
/// (05-plan P0-19).
protocol WatchlistProviding: Sendable {
    /// Movies and shows on the list, newest first, each title once.
    @MainActor func entries() async throws -> [WatchlistEntry]

    /// Adds or removes a title. Idempotent.
    @MainActor func setWatchlisted(_ watchlisted: Bool, entry: WatchlistEntry) async throws

    /// A title's details (with its external ids) by its watchlist id.
    @MainActor func details(itemID: String) async throws -> WatchlistEntry?

    /// Where a title streams, by its watchlist id.
    @MainActor func availabilities(itemID: String) async throws -> [WatchlistAvailability]

    /// The account's own Home layout, where it says where the Watchlist row
    /// goes. nil for the default layout, or when it cannot be read.
    @MainActor func homeLayout() async -> [HomeLayoutHub]?

    /// The entry a server title is on the list as, for its bookmark and menu
    /// item; nil when the account cannot list it.
    @MainActor func entry(for item: MediaItem) -> WatchlistEntry?

    /// The same, from a detail page.
    @MainActor func entry(for details: MediaDetails) -> WatchlistEntry?
}
