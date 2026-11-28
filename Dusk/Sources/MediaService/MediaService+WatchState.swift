import Foundation

/// Progress reports and watched state, routed to the item's server's
/// `UserDataProviding` (docs/jellyfin/04-architecture.md §12.5).

extension MediaService {
    /// The user-data facet of `serverID`'s provider (nil = the primary
    /// server, which is what every not-yet-routed call has always meant).
    func userData(on serverID: String?) throws -> any UserDataProviding {
        serverProvider(for: try resolveServerID(serverID)).userData
    }

    /// Sends a playback report to the item's server only — never fanned out —
    /// because an item id means something different on every other server.
    /// Fire and forget: a lost tick is replaced by the next one.
    func report(_ event: PlaybackReport) async {
        try? await submit(event)
    }

    /// `report(_:)` for callers that must know whether the server took it
    /// (offline replay).
    func submit(_ event: PlaybackReport) async throws {
        try await userData(on: event.item.serverID).report(event)
    }

    /// Marks one item watched or unwatched on one server. Use
    /// `setWatchedAcrossServers` for a user's explicit action.
    func setWatched(_ watched: Bool, itemID: String, serverID: String? = nil) async throws {
        let facet = try userData(on: serverID)
        try await facet.setWatched(
            watched,
            item: MediaItemID(serverID: serverID, itemID: itemID),
            at: nil
        )
    }

    /// `PlaybackTraits.serverAppliesWatchedThreshold` for the server: true
    /// when it marks an item played on its own from the stopped report, so the
    /// coordinator's 90 % rule must not write it a second time. Plex never
    /// does.
    func serverAppliesWatchedThreshold(serverID: String?) -> Bool {
        playback(for: serverID).traits.serverAppliesWatchedThreshold
    }

    /// Hides an item from the server-wide "Continue Watching" hub without
    /// changing its watch state, mirroring Plex's "Remove from Continue
    /// Watching" action.
    func removeFromContinueWatching(itemID: String, serverID: String? = nil) async throws {
        _ = try await rawServerRequest(
            method: "PUT",
            path: "/actions/removeFromContinueWatching",
            queryItems: [
                URLQueryItem(name: "ratingKey", value: itemID),
            ],
            serverID: serverID
        )
    }
}
