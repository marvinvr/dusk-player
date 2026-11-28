import Foundation

/// Home rows and library hubs (docs/jellyfin/04-architecture.md §11): the rows
/// one server puts on Home and on a library's Recommended tab, its Continue
/// Watching, a row's further items, and the switch that takes a row off Home.
///
/// One value per server. Rows and items come back stamped with that server and
/// classified (`HomeRow.kind`, `libraryScope`, `mergeKey`, `canHide`). Hidden
/// libraries, permissions and the cross-server merge are the facade's.
///
/// The methods run on the main actor, where the facade and its request routing
/// live.
///
/// Dismiss from Continue Watching belongs here too (§11) but still lives in
/// `MediaService+WatchState`. The managed-row types (`PlexManagedHub`,
/// `PlexManagedHomeRow`) and `PlexHubSource` keep their Plex names until the
/// boundary pass (05-plan P0-19).
protocol HomeProviding: Sendable {
    /// The server's Home rows, in its own order.
    @MainActor func homeRows() async throws -> [HomeRow]

    /// Titles in progress and next up, as the server orders them.
    @MainActor func continueWatching() async throws -> [MediaItem]

    /// A library's rows, `count` items each. On a big library this is the
    /// server's most expensive read.
    @MainActor func libraryRows(libraryID: String, count: Int) async throws -> [HomeRow]

    /// The cheap top of `libraryRows` (Continue Watching, next up, Recently
    /// Added), holding only that library's titles.
    @MainActor func promotedLibraryRows(libraryID: String, count: Int) async throws -> [HomeRow]

    /// More of one server's part of a row: the `key` of that server's
    /// `HomeRow.sources` entry. `size` nil means the server's default page.
    @MainActor func rowItems(rowKey: String, start: Int, size: Int?) async throws -> [MediaItem]

    /// The Home switches of one library's rows.
    @MainActor func managedRows(libraryID: String) async throws -> [PlexManagedHub]

    /// Writes one library row's switches back.
    @MainActor func setManagedRow(_ row: PlexManagedHub, libraryID: String) async throws

    /// The switch behind this server's part of `row` (`source`), or nil when
    /// the row has none here. `libraryIDs` is every library on this server,
    /// asked in turn when the row does not say which one it belongs to.
    @MainActor func managedRow(
        for row: HomeRow,
        source: PlexHubSource,
        libraryIDs: [String]
    ) async -> PlexManagedHomeRow?
}
