import Foundation
import OSLog

private let watchedFanOutLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "WatchedFanOut"
)

extension PlexService {
    /// Marks an item watched or unwatched on every connected server that is
    /// known to hold the same content.
    ///
    /// Playback reporting stays on the one server the session streams from — a
    /// timeline is about a file. An explicit "Mark as Watched" is not: the user
    /// is saying they have seen the content, and leaving the other copies
    /// behind is what makes the item reappear in a merged Continue Watching row
    /// or an Up Next shelf fed by another server.
    ///
    /// The requested instance decides the outcome: its failure is thrown so the
    /// caller can surface it. The other copies are best effort — a server that
    /// refuses must not make the action look like it failed.
    func setWatchedAcrossServers(_ watched: Bool, id: PlexItemID) async throws {
        // A library grid may not have visited a merged surface yet. Discover
        // same-server movie copies before the explicit action reaches Plex.
        if alternates.contentKey(for: id)?.isMovie != false,
           let details = try? await getMediaDetails(ratingKey: id.ratingKey, serverID: id.serverID),
           !details.movieContentKeys.isEmpty {
            _ = await movieCopies(for: details, includeOtherServers: false)
        }
        try await setWatched(watched, ratingKey: id.ratingKey, serverID: id.serverID)

        for instance in alternates.instances(of: id) {
            guard let serverID = instance.serverID,
                  instance != id,
                  pool.connection(for: serverID) != nil else {
                continue
            }

            do {
                try await setWatched(watched, ratingKey: instance.ratingKey, serverID: serverID)
            } catch {
                watchedFanOutLogger.notice(
                    "Could not mark \(instance.storageKey, privacy: .public) as \(watched ? "watched" : "unwatched", privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
