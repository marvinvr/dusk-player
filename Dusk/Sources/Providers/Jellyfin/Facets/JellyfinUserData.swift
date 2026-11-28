import Foundation

/// Jellyfin's progress reports and watched state. Placeholder until J-05:
/// nothing is reported.
@MainActor
struct JellyfinUserData: UserDataProviding {
    let server: JellyfinServerProvider

    nonisolated init(server: JellyfinServerProvider) {
        self.server = server
    }

    func report(_ event: PlaybackReport) async throws {}

    func setWatched(_ watched: Bool, item: MediaItemID, at date: Date?) async throws {
        throw MediaServiceError.notImplemented
    }
}
