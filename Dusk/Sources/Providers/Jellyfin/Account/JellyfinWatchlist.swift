import Foundation

/// Jellyfin's `WatchlistProviding`: the active user's favourite films and
/// shows on their server (docs/jellyfin/04-architecture.md §17, §21 row 2;
/// decided 2026-11-28). The bookmark sets `IsFavorite`
/// (`POST`/`DELETE /UserFavoriteItems/{id}`), the Home row lists the
/// favourites, and both keep the Watchlist name.
///
/// - Every entry is a server title (`WatchlistEntry.serverItem`), so the
///   facade looks nothing up and there are no "not on your servers" cards.
/// - Jellyfin keeps no date for a favourite, so the list cannot be in the
///   order titles were added to it as on Plex; it is newest in the library
///   first (`DateCreated`).
/// - No streaming availabilities and no Home layout of its own: the row goes
///   where Dusk's default puts it.
@MainActor
struct JellyfinWatchlist: WatchlistProviding {
    let account: JellyfinAccountProvider

    nonisolated init(account: JellyfinAccountProvider) {
        self.account = account
    }

    /// Home shows the newest ones; a longer list stops here, like Plex's.
    private static let maxEntries = 500

    func entries() async throws -> [WatchlistEntry] {
        guard let record = account.state.activeRecord, let client = account.client(for: record) else {
            throw MediaServiceError.notAuthenticated
        }
        var query = JellyfinItemQuery()
        query.recursive = true
        query.includeItemTypes = [.movie, .series]
        query.isFavorite = true
        query.sortBy = [.dateCreated, .sortName]
        query.sortOrders = [.descending, .ascending]
        query.fields = JellyfinBrowseVocabulary.listFields + [.overview]
        query.limit = Self.maxEntries
        query.enableTotalRecordCount = false
        let serverID = record.serverID
        return try await client.send(JellyfinAPI.items(query)).items.compactMap { dto in
            JellyfinItemMapper.watchlistEntry(for: JellyfinItemMapper.map(dto, serverID: serverID))
        }
    }

    func setWatchlisted(_ watchlisted: Bool, entry: WatchlistEntry) async throws {
        guard let target = JellyfinItemMapper.watchlistTarget(entry.guid),
              let record = account.record(forServer: target.serverID),
              let client = account.client(for: record) else {
            throw MediaServiceError.notAuthenticated
        }
        _ = try await client.send(JellyfinAPI.setFavorite(itemID: target.itemID, watchlisted))
    }

    func details(itemID: String) async throws -> WatchlistEntry? {
        guard let record = account.state.activeRecord, let client = account.client(for: record) else {
            throw MediaServiceError.notAuthenticated
        }
        let dto = try await client.send(JellyfinAPI.item(id: itemID))
        return JellyfinItemMapper.watchlistEntry(for: JellyfinItemMapper.map(dto, serverID: record.serverID))
    }

    func availabilities(itemID: String) async throws -> [WatchlistAvailability] { [] }

    func homeLayout() async -> [HomeLayoutHub]? { nil }

    /// Only a title of this account's server can be its favourite.
    func entry(for item: MediaItem) -> WatchlistEntry? {
        guard let serverID = item.serverID, account.record(forServer: serverID) != nil else { return nil }
        return JellyfinItemMapper.watchlistEntry(for: item)
    }

    func entry(for details: MediaDetails) -> WatchlistEntry? {
        guard let serverID = details.serverID, account.record(forServer: serverID) != nil else { return nil }
        return JellyfinItemMapper.watchlistEntry(for: details)
    }
}
