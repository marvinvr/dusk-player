import Foundation

/// Builds Jellyfin's providers. Carries the one `JellyfinAccountProvider` of
/// its `MediaService`, which holds every Jellyfin user saved on the device.
struct JellyfinProviderFactory: ProviderFactory {
    let account: JellyfinAccountProvider

    var kind: ProviderKind { .jellyfin }

    func makeSignInFlow() -> any SignInFlow {
        JellyfinSignInFlow(account: account)
    }

    @MainActor
    func storedAccounts() -> [StoredAccount] {
        account.storedAccounts
    }

    /// Every Jellyfin record restores to the same provider, which knows them all.
    func restoreAccount(from record: StoredAccount) -> any MediaAccountProvider {
        account
    }

    func makeServerProvider(_ seed: ServerSessionSeed) -> any MediaServerProvider {
        JellyfinServerProvider(account: account, seed: seed)
    }

    @MainActor
    func ownsServer(_ serverID: String) -> Bool {
        account.record(forServer: serverID) != nil
    }

    /// The address the user typed and the server's `LocalAddress`.
    var listedConnectionSource: ConnectionCandidateSource { .serverAddress }

    @MainActor
    func connectionProbe(serverID: String, credential: String) -> ConnectionProbe? {
        account.connectionProbe(serverID: serverID, credential: credential)
    }
}
