import Foundation

/// Why remote streaming is unavailable for the current session.
enum RemoteStreamingRestriction: Sendable, Equatable {
    /// The user owns this server, is away from its local network, and the
    /// account has no active Plex Pass / Remote Watch Pass. Since April 2025
    /// Plex requires the server owner (or the streaming user) to hold one of
    /// those to stream personal media remotely; only local streaming is free.
    case ownerNeedsPlexPass

    var message: String {
        switch self {
        case .ownerNeedsPlexPass:
            return """
            Remote streaming needs Plex Pass. You're away from your server's local network, \
            and Plex now requires the server owner to have an active Plex Pass (or Remote Watch \
            Pass) to stream personal media remotely. Connect to your home Wi-Fi to keep watching, \
            or get Plex Pass at plex.tv.
            """
        }
    }
}

extension PlexService {
    private struct AccountEntitlementResponse: Decodable {
        let subscription: PlexSubscription?
    }

    /// nil = not yet known, true/false = fetched from the account.
    var accountHasRemoteStreamingEntitlement: Bool? {
        accountSubscriptionActive
    }

    /// Best-effort, cached lookup of the account's subscription state. Never
    /// throws: on failure the state stays `nil` (unknown) so we never wrongly
    /// block playback on a transient plex.tv hiccup.
    func loadAccountEntitlementIfNeeded() async {
        guard accountSubscriptionActive == nil, authToken != nil else { return }

        do {
            let account: AccountEntitlementResponse = try await plexTVRequest(path: "/api/v2/user")
            accountSubscriptionActive = account.subscription?.isActive ?? false
        } catch {
            plexAuthLogger.notice(
                "Account entitlement lookup failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Detects the Plex Pass remote-streaming restriction for online playback.
    ///
    /// Only decides for servers the account owns: there, the streaming user *is*
    /// the owner, so the account's own subscription is authoritative. For shared
    /// servers the owner's entitlement isn't visible to the client, so we don't
    /// pre-empt playback — those simply fall through to the normal error path.
    /// Returns nil unless we positively know the entitlement is missing.
    func remoteStreamingRestriction() async -> RemoteStreamingRestriction? {
        guard isConnectedRemotely,
              let server = connectedServer,
              server.owned else {
            return nil
        }

        await loadAccountEntitlementIfNeeded()

        return accountSubscriptionActive == false ? .ownerNeedsPlexPass : nil
    }
}
