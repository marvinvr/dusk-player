import Foundation

/// Plex's `UserDataProviding`: `/:/timeline`, `/:/scrobble` and
/// `/:/unscrobble` on one server.
struct PlexUserData: UserDataProviding {
    /// The server every call goes to. nil only for the facade's unrouted
    /// fallback, which the transport resolves to the primary server.
    let serverID: String?
    /// nil only on the provider's own facet (see `PlexServerProvider.userData`),
    /// which then refuses every call.
    let transport: (any PlexServerTransport)?

    nonisolated init(serverID: String?, transport: (any PlexServerTransport)?) {
        self.serverID = serverID
        self.transport = transport
    }

    func report(_ event: PlaybackReport) async throws {
        let itemID = event.item.itemID
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "ratingKey", value: itemID),
            URLQueryItem(name: "key", value: event.liveSessionPath ?? "/library/metadata/\(itemID)"),
            URLQueryItem(name: "state", value: Self.timelineState(event.state)),
            URLQueryItem(name: "time", value: String(event.positionMs)),
            URLQueryItem(name: "duration", value: String(event.durationMs)),
        ]
        if let sessionID = event.sessionID {
            queryItems.append(URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionID))
        }
        _ = try await send(path: "/:/timeline", queryItems: queryItems)
    }

    /// Plex has no "when": `date` is ignored.
    func setWatched(_ watched: Bool, item: MediaItemID, at date: Date?) async throws {
        _ = try await send(
            path: watched ? "/:/scrobble" : "/:/unscrobble",
            queryItems: [
                URLQueryItem(name: "key", value: item.itemID),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            ]
        )
    }

    /// Plex's timeline states. A session start is an ordinary "playing" tick.
    static func timelineState(_ state: PlaybackReport.State) -> String {
        switch state {
        case .started, .progress: "playing"
        case .paused: "paused"
        case .buffering: "buffering"
        case .stopped: "stopped"
        }
    }

    private func send(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        guard let transport else { throw PlexServiceError.noServerConnected }
        return try await transport.rawServerRequest(
            method: "GET",
            path: path,
            queryItems: queryItems,
            timeoutInterval: nil,
            serverID: serverID
        )
    }
}

extension PlexServerProvider {
    /// Nothing reads this yet: the facade builds the routed facet itself
    /// (`MediaService.userData(on:)`), because the routing lives there. This
    /// one has no transport until `PlexClient` carries a routed send (a
    /// reference to `MediaService`'s routing, set when the service builds it).
    var userData: any UserDataProviding {
        PlexUserData(serverID: descriptor.id, transport: nil)
    }
}
