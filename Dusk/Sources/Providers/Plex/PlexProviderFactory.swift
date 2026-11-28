import Foundation

/// Builds Plex's providers. Carries the service's `PlexClient` and its one
/// Plex account, so every server provider shares the client's sessions and
/// headers.
struct PlexProviderFactory: ProviderFactory {
    let account: PlexAccountProvider

    var client: PlexClient { account.client }

    init(account: PlexAccountProvider) {
        self.account = account
    }

    /// A factory around `client` with an account object of its own, signed
    /// out. Only for building server providers outside a `MediaService`.
    @MainActor
    init(client: PlexClient) {
        self.init(account: PlexAccountProvider(client: client))
    }

    var kind: ProviderKind { .plex }

    func makeSignInFlow() -> any SignInFlow {
        PlexSignInFlow(account: account)
    }

    @MainActor
    func storedAccounts() -> [StoredAccount] {
        account.storedAccounts
    }

    /// An install holds one Plex account, loaded at launch, so every Plex
    /// record restores to that same provider.
    func restoreAccount(from record: StoredAccount) -> any MediaAccountProvider {
        account
    }

    func makeServerProvider(_ seed: ServerSessionSeed) -> any MediaServerProvider {
        PlexServerProvider(client: client, seed: seed)
    }
}
