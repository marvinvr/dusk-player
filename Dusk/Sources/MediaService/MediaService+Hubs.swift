import Foundation

/// Hub rows: Home, Continue Watching, a library's hubs and a hub's items.
/// Each method is a route to the server's `HomeProviding` facet
/// (docs/jellyfin/04-architecture.md §11, `PlexHomeRows`). Every endpoint
/// takes the item's or library's `serverID`, as in `MediaService+Library`;
/// nil means the primary server.
extension MediaService {
    /// The home facet of one server. Built here rather than read off
    /// `session.provider` while routing and self-healing still live in the
    /// facade (`PlexServerTransport`).
    func home(on serverID: String) -> any HomeProviding {
        PlexHomeRows(serverID: serverID, transport: self)
    }

    /// A library's hub rows: the server's most expensive read on a big
    /// library, so the facet gives it a longer timeout.
    func getLibraryHubs(sectionId: String, count: Int = 12, serverID: String? = nil) async throws -> [HomeRow] {
        try await home(on: resolveServerID(serverID)).libraryRows(libraryID: sectionId, count: count)
    }

    /// A library's promoted rows: Continue Watching, On Deck and Recently
    /// Added, the top of `getLibraryHubs` at a fraction of its cost, so a big
    /// library paints before its full hub rows are in.
    func getLibraryPromotedHubs(sectionId: String, count: Int = 12, serverID: String? = nil) async throws -> [HomeRow] {
        try await home(on: resolveServerID(serverID)).promotedLibraryRows(libraryID: sectionId, count: count)
    }

    func getHubs(serverID: String? = nil) async throws -> [HomeRow] {
        try await home(on: resolveServerID(serverID)).homeRows()
    }

    func getContinueWatching(serverID: String? = nil) async throws -> [MediaItem] {
        try await home(on: resolveServerID(serverID)).continueWatching()
    }

    /// One server's page of a row (`HomeRow.sources[n].key`), without the
    /// account's hidden libraries.
    func getHubItems(
        hubKey: String,
        start: Int = 0,
        size: Int? = nil,
        serverID: String? = nil
    ) async throws -> [MediaItem] {
        let items = try await home(on: resolveServerID(serverID)).rowItems(rowKey: hubKey, start: start, size: size)
        return await loadedHiddenLibraryFilter().filtering(items)
    }
}
