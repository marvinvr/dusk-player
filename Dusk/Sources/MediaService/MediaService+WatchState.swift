import Foundation

/// Progress reports and watched state. The Plex calls behind `UserDataProviding`
/// (docs/jellyfin/04-architecture.md §12.5).
extension MediaService {
    /// - Parameter serverID: The server the item is being played from. Progress
    ///   goes to that server only — never fanned out — because a rating key
    ///   means something different on every other server.
    func reportTimeline(
        itemID: String,
        key: String? = nil,
        state: PlaybackState,
        timeMs: Int,
        durationMs: Int,
        sessionIdentifier: String? = nil,
        serverID: String? = nil
    ) async {
        try? await submitTimeline(
            itemID: itemID,
            key: key,
            state: state,
            timeMs: timeMs,
            durationMs: durationMs,
            sessionIdentifier: sessionIdentifier,
            serverID: serverID
        )
    }

    func submitTimeline(
        itemID: String,
        key: String? = nil,
        state: PlaybackState,
        timeMs: Int,
        durationMs: Int,
        sessionIdentifier: String? = nil,
        serverID: String? = nil
    ) async throws {
        let stateString: String
        switch state {
        case .playing:
            stateString = "playing"
        case .paused:
            stateString = "paused"
        case .loading:
            // The engine is opening or refilling its buffer. Plex expects
            // "buffering" here so the server keeps the session (and any
            // transcoder) alive instead of timing it out.
            stateString = "buffering"
        default:
            stateString = "stopped"
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "ratingKey", value: itemID),
            URLQueryItem(name: "key", value: key ?? "/library/metadata/\(itemID)"),
            URLQueryItem(name: "state", value: stateString),
            URLQueryItem(name: "time", value: String(timeMs)),
            URLQueryItem(name: "duration", value: String(durationMs)),
        ]
        if let sessionIdentifier {
            queryItems.append(URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier))
        }

        _ = try await rawServerRequest(
            path: "/:/timeline",
            queryItems: queryItems,
            serverID: serverID
        )
    }

    func scrobble(itemID: String, serverID: String? = nil) async throws {
        _ = try await rawServerRequest(
            path: "/:/scrobble",
            queryItems: [
                URLQueryItem(name: "key", value: itemID),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            ],
            serverID: serverID
        )
    }

    func unscrobble(itemID: String, serverID: String? = nil) async throws {
        _ = try await rawServerRequest(
            path: "/:/unscrobble",
            queryItems: [
                URLQueryItem(name: "key", value: itemID),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            ],
            serverID: serverID
        )
    }

    func setWatched(_ watched: Bool, itemID: String, serverID: String? = nil) async throws {
        if watched {
            try await scrobble(itemID: itemID, serverID: serverID)
        } else {
            try await unscrobble(itemID: itemID, serverID: serverID)
        }
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
