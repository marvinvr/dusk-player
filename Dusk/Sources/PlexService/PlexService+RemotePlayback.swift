import Foundation

/// Plex's remote-streaming rule, as the server enforces it.
///
/// Since 2025 Plex only streams personal video outside the server's local
/// network when the server owner has Plex Pass, or the viewer has Plex Pass or
/// a Remote Watch Pass. Playback on the same network stays free.
///
/// Dusk deliberately does not decide this itself. Who is entitled depends on
/// the owner's pass, the viewer's pass, the Remote Watch Pass (which plex.tv's
/// `subscription` object does not describe), and on whether *the server* sees
/// the request as local — a public or relay address can still be the server's
/// own LAN (NAT loopback). Only the server knows all of that, so Dusk always
/// tries and explains the rule only when the server refuses a playback request
/// that left the local network.
enum RemotePlaybackRefusal {
    static let message = """
    Plex didn't allow this stream outside your server's home network. Streaming \
    away from home needs Plex Pass on the server owner's account, or Plex Pass or \
    a Remote Watch Pass on yours. Playing at home is free: if you're home, make \
    sure this device is on the same network as the server.
    """
}

extension PlexService {
    /// True when the server refused a playback request (HTTP 403) on a
    /// connection that is not positively on its local network — the only shape
    /// Plex's remote-streaming rule takes that the client can observe. Any
    /// other failure is reported as itself, never as a missing pass.
    func isRemotePlaybackRefusal(_ error: Error, serverID: String?) -> Bool {
        guard case .httpError(statusCode: 403)? = error as? PlexServiceError,
              let connection = pool.connection(for: serverID) else {
            return false
        }
        return !connection.isLocal
    }

    /// Remote sessions only: asks for the first byte of the direct-play file,
    /// because an engine handed a refused URL never reports it — AVPlayer
    /// just keeps loading — so the refusal would surface as an endless
    /// spinner. Throws only for a 403; anything else is left to the engine.
    func checkRemoteDirectPlayAccess(_ url: URL, serverID: String?) async throws {
        guard let connection = pool.connection(for: serverID), !connection.isLocal else { return }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10
        for (key, value) in plexRequestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let response = try? await session.data(for: request).1 as? HTTPURLResponse,
              response.statusCode == 403 else {
            return
        }
        throw PlexServiceError.httpError(statusCode: 403)
    }

    /// After a remote refusal, races the server's connections again: a LAN
    /// address that lost the earlier race (a slow wake-up, a network change the
    /// session has not caught up with) wins it when the device is home.
    ///
    /// - Returns: true when the session now runs over the local network, so the
    ///   refused request is worth one more try there.
    func reconnectOverLocalNetwork(serverID: String?) async -> Bool {
        guard let connection = pool.connection(for: serverID),
              !connection.isLocal,
              let server = pool.server(for: connection.serverID),
              server.connections.contains(where: \.isOnLocalNetwork) else {
            return false
        }
        let refreshed = await pool.connect(to: server, priority: serverPriority)
        return refreshed?.isLocal == true
    }
}
