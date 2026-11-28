import Foundation

/// The account's video playlists across every connected server, shared by the
/// Playlists tab, its detail pages and the Add to Playlist sheet so an edit in
/// one shows everywhere (and a first playlist created from a context menu
/// brings the tab in). `PlexService+Playlists` loads it; screens mutate it only
/// through the store's edit helpers after the server accepted the change.
///
/// Loaded once per `ServerContentRevision` (connected servers, priority,
/// profile). A server that does not answer keeps whatever it had before rather
/// than emptying the list.
@MainActor
@Observable
final class PlaylistStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var playlistsByServer: [String: [Playlist]] = [:]
    private(set) var serverOrder: [String] = []
    private(set) var state: State = .idle
    @ObservationIgnored private(set) var loadedRevision: ServerContentRevision?
    /// Bumped by every load and by `reset`: an answer from an older load is
    /// dropped instead of putting back a server the newer one removed.
    @ObservationIgnored private(set) var loadGeneration = 0
    /// Bumped when the account or profile changes (`reset`, a load for
    /// another profile). Edits and refreshes that were in flight across it
    /// are dropped.
    @ObservationIgnored private(set) var sessionGeneration = 0

    /// Every playlist, A–Z like Plex lists them; same-titled playlists keep
    /// server priority order.
    var playlists: [Playlist] {
        let ordered = serverOrder.flatMap { playlistsByServer[$0] ?? [] }
        return ordered.enumerated().sorted { lhs, rhs in
            let order = lhs.element.title.localizedStandardCompare(rhs.element.title)
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.map(\.element)
    }

    var hasPlaylists: Bool {
        playlistsByServer.values.contains { !$0.isEmpty }
    }

    /// Regular (non-smart) playlists on one server, most recently updated
    /// first: the Add to Playlist targets for an item from that server.
    func editablePlaylists(serverID: String?) -> [Playlist] {
        guard let serverID else { return [] }
        return (playlistsByServer[serverID] ?? [])
            .filter { !$0.smart }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    func playlist(id: MediaItemID) -> Playlist? {
        guard let serverID = id.serverID else { return nil }
        return playlistsByServer[serverID]?.first { $0.itemID == id.itemID }
    }

    /// True when the playlists are worth asking each server about more than one.
    var spansMultipleServers: Bool {
        playlistsByServer.filter { !$0.value.isEmpty }.count > 1
    }

    // MARK: - Loading (PlexService+Playlists)

    /// Returns the load's generation, which `commit`/`finishLoad` must quote.
    @discardableResult
    func beginLoad(revision: ServerContentRevision) -> Int {
        loadGeneration += 1
        if loadedRevision?.profileID != revision.profileID {
            playlistsByServer = [:]
            sessionGeneration += 1
        }
        // Servers that are no longer connected drop out.
        playlistsByServer = playlistsByServer.filter { revision.serverIDs.contains($0.key) }
        serverOrder = revision.serverIDs
        loadedRevision = revision
        if state != .loaded {
            state = .loading
        }
        return loadGeneration
    }

    func commit(_ playlists: [Playlist], serverID: String, generation: Int) {
        guard generation == loadGeneration, serverOrder.contains(serverID) else { return }
        playlistsByServer[serverID] = playlists
    }

    func finishLoad(failure: String?, generation: Int) {
        guard generation == loadGeneration else { return }
        if let failure, !hasPlaylists {
            state = .failed(failure)
        } else {
            state = .loaded
        }
    }

    func reset() {
        loadGeneration += 1
        sessionGeneration += 1
        playlistsByServer = [:]
        serverOrder = []
        loadedRevision = nil
        state = .idle
    }

    // MARK: - Edits

    /// `sessionGeneration`: the session the caller read before its request;
    /// an answer that outlived a sign-out or profile switch is dropped.
    func upsert(_ playlist: Playlist, sessionGeneration expected: Int? = nil) {
        if let expected, expected != sessionGeneration { return }
        guard let serverID = playlist.serverID else { return }
        var list = playlistsByServer[serverID] ?? []
        if let index = list.firstIndex(where: { $0.itemID == playlist.itemID }) {
            list[index] = playlist
        } else {
            list.append(playlist)
        }
        playlistsByServer[serverID] = list
        if !serverOrder.contains(serverID) {
            serverOrder.append(serverID)
        }
    }

    func remove(_ id: MediaItemID, sessionGeneration expected: Int? = nil) {
        if let expected, expected != sessionGeneration { return }
        guard let serverID = id.serverID else { return }
        playlistsByServer[serverID]?.removeAll { $0.itemID == id.itemID }
    }
}
