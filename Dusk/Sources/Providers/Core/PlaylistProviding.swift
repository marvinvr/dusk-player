import Foundation

/// Playlist reads and edits on one server (docs/jellyfin/04-architecture.md §3).
/// A playlist lives on a single server and belongs to the signed-in profile;
/// its items can only come from that server, so every call goes to the
/// playlist's own server. Values come back stamped with that server.
///
/// The cross-server list and the shared `PlaylistStore` are the facade's.
///
/// The methods run on the main actor, where the facade and its request routing
/// live.
///
/// Entries are keyed by the server's opaque entry handle
/// (`PlaylistEntry.playlistItemID`). Moves are "after X"; a server that moves
/// by position (Jellyfin) converts against its current order. An add answers
/// how many entries it really added, so repeats the server skips can be told.
protocol PlaylistProviding: Sendable {
    /// The server's video playlists, in its own order.
    @MainActor func playlists() async throws -> [Playlist]

    /// One playlist, or nil when the server has none by that id.
    @MainActor func playlist(id: String) async throws -> Playlist?

    /// Every entry of a playlist, in playlist order.
    @MainActor func entries(playlistID: String) async throws -> [PlaylistEntry]

    /// A new regular playlist holding `itemIDs` (never empty: Plex cannot
    /// create an empty one).
    @MainActor func createPlaylist(title: String, itemIDs: [String]) async throws -> Playlist

    /// Appends items; a show or season adds its episodes.
    @MainActor func add(itemIDs: [String], to playlistID: String) async throws -> PlaylistAddResult

    /// Removes the entry with this handle (`PlaylistEntry.playlistItemID`).
    /// Where repeats of an item share one handle, every repeat goes.
    @MainActor func removeEntry(_ entryID: String, from playlistID: String) async throws

    /// Moves an entry right after `afterEntryID`, or to the top when nil. A
    /// server that moves by position works the position out itself.
    @MainActor func moveEntry(_ entryID: String, after afterEntryID: String?, in playlistID: String) async throws

    @MainActor func rename(playlistID: String, to title: String) async throws

    @MainActor func delete(playlistID: String) async throws
}
