import Foundation

/// Jellyfin's playlists. Placeholder until J-07: none, and none can be made.
@MainActor
struct JellyfinPlaylists: PlaylistProviding {
    let server: JellyfinServerProvider

    nonisolated init(server: JellyfinServerProvider) {
        self.server = server
    }

    func playlists() async throws -> [Playlist] { [] }

    func playlist(id: String) async throws -> Playlist? { nil }

    func entries(playlistID: String) async throws -> [PlaylistEntry] { [] }

    func createPlaylist(title: String, itemIDs: [String]) async throws -> Playlist {
        throw MediaServiceError.notImplemented
    }

    func add(itemIDs: [String], to playlistID: String) async throws -> PlaylistAddResult {
        throw MediaServiceError.notImplemented
    }

    func removeEntry(_ entryID: Int, from playlistID: String) async throws {
        throw MediaServiceError.notImplemented
    }

    func moveEntry(_ entryID: Int, after afterEntryID: Int?, in playlistID: String) async throws {
        throw MediaServiceError.notImplemented
    }

    func rename(playlistID: String, to title: String) async throws {
        throw MediaServiceError.notImplemented
    }

    func delete(playlistID: String) async throws {
        throw MediaServiceError.notImplemented
    }
}
