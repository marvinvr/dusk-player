import Foundation

/// The providers this build ships, wired for one `MediaService`
/// (docs/jellyfin/04-architecture.md §2): the account the install signs in with
/// and the factories the pool builds each session's server provider from.
/// The only place outside a provider's folder that names a provider type.
enum ProviderSetup {
    struct Standard {
        /// The Plex account, which the facade's Plex Home orchestration drives.
        let account: any MediaAccountProvider
        /// The other providers' accounts. Each runs its own session
        /// (`AccountSession`); the facade restores and attaches them too.
        let additionalAccounts: [any MediaAccountProvider]
        let registry: ProviderRegistry
    }

    /// - Parameters:
    ///   - clientIdentifier: This install's stable device id.
    ///   - urlProtocolClasses: Tests only: serves every session's requests.
    @MainActor
    static func standard(clientIdentifier: String, urlProtocolClasses: [AnyClass]? = nil) -> Standard {
        let client = PlexClient(clientIdentifier: clientIdentifier, urlProtocolClasses: urlProtocolClasses)
        let account = PlexAccountProvider(client: client)
        let jellyfin = JellyfinAccountProvider(
            sessions: urlProtocolClasses.map { JellyfinSessions(urlProtocolClasses: $0) } ?? .standard
        )
        return Standard(
            account: account,
            additionalAccounts: [jellyfin],
            registry: ProviderRegistry([PlexProviderFactory(account: account), JellyfinProviderFactory(account: jellyfin)])
        )
    }
}
