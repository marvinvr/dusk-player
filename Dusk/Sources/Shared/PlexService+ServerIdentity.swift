import Foundation

/// Server identity helpers for the parts of the app that persist a server
/// reference and have to survive both restarts and the pre-multi-server format.
///
/// Anything Dusk writes to disk — a download record, a queued offline action, a
/// Seerr session — names a server by machine identifier. Two things make that
/// harder than it looks:
///
/// * Before the multi-server change the identifier fell back to the server's
///   base URL when Plex did not report a `clientIdentifier`, so old state can
///   carry a URL string where an identifier belongs.
/// * `pool.primary` is live state: nil until a server answers, and a different
///   server whenever the top one is offline. Nothing persisted may be keyed on
///   it.
extension PlexService {
    /// The server Seerr is bound to: the account's first enabled server in
    /// Server Priority. Persisted, so it is the same before any server has
    /// connected and stays the same while the top server is offline — which a
    /// stored Seerr session depends on.
    var seerrBindingServerID: String? {
        if let enabled = serverPriority.entries.first(where: \.isEnabled)?.machineIdentifier.nilIfEmpty {
            return enabled
        }
        if let first = serverPriority.entries.first?.machineIdentifier.nilIfEmpty {
            return first
        }
        // Nothing has been reconciled yet (a fresh install linking Seerr during
        // the very first connect pass).
        return pool.primary?.serverID
    }

    /// Whether this identifier names a server of the signed-in account — either
    /// one discovery has seen or one the priority list remembers.
    func isKnownServerID(_ serverID: String) -> Bool {
        guard !serverID.isEmpty else { return false }
        return pool.server(for: serverID) != nil
            || serverPriority.entries.contains { $0.machineIdentifier == serverID }
    }

    /// Resolves a legacy identifier that is really a connection URI onto the
    /// machine identifier of the server reachable at that address.
    ///
    /// Returns nil when nothing matches — the caller then leaves the stored
    /// value alone rather than guessing, because a wrong mapping would point
    /// downloads and watch state at a different server's library.
    func serverID(forLegacyConnectionURI uri: String) -> String? {
        guard let needle = Self.normalizedConnectionURI(uri) else { return nil }

        for serverID in pool.priorityOrderedIdentifiers {
            if Self.connectionURIs(forServerID: serverID, server: pool.server(for: serverID))
                .contains(needle) {
                return serverID
            }
        }
        return nil
    }

    /// Every address this server is known to answer at: the endpoints plex.tv
    /// reported and the ones that actually worked on this device.
    private static func connectionURIs(forServerID serverID: String, server: PlexServer?) -> Set<String> {
        var uris: Set<String> = []
        for connection in server?.connections ?? [] {
            if let uri = normalizedConnectionURI(connection.uri) {
                uris.insert(uri)
            }
            if let fallback = connection.httpFallbackURI,
               let uri = normalizedConnectionURI(fallback) {
                uris.insert(uri)
            }
        }
        if let baseURL = ServerPool.storedBaseURL(serverID: serverID),
           let uri = normalizedConnectionURI(baseURL.absoluteString) {
            uris.insert(uri)
        }
        if let lastGood = ServerPool.lastGoodConnectionURI(serverID: serverID),
           let uri = normalizedConnectionURI(lastGood) {
            uris.insert(uri)
        }
        return uris
    }

    private static func normalizedConnectionURI(_ value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard trimmed.contains("://") else { return nil }
        return trimmed.nilIfEmpty
    }
}
