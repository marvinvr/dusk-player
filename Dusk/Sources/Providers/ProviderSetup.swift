import Foundation

/// The providers this build ships, wired for one `MediaService`
/// (docs/jellyfin/04-architecture.md §2): the account the install signs in with
/// and the factories the pool builds each session's server provider from.
/// The only place outside a provider's folder that names a provider type.
enum ProviderSetup {
    struct Standard {
        let account: any MediaAccountProvider
        let registry: ProviderRegistry
    }

    /// - Parameters:
    ///   - clientIdentifier: This install's stable device id.
    ///   - urlProtocolClasses: Tests only: serves every session's requests.
    @MainActor
    static func standard(clientIdentifier: String, urlProtocolClasses: [AnyClass]? = nil) -> Standard {
        let client = PlexClient(clientIdentifier: clientIdentifier, urlProtocolClasses: urlProtocolClasses)
        let account = PlexAccountProvider(client: client)
        return Standard(account: account, registry: ProviderRegistry([PlexProviderFactory(account: account)]))
    }
}
