import Foundation

/// Builds one provider's objects (docs/jellyfin/04-architecture.md §3).
protocol ProviderFactory: Sendable {
    var kind: ProviderKind { get }
    /// The provider's sign-in screens, for the sign-in host.
    func makeSignInFlow() -> any SignInFlow
    /// The accounts of this provider signed in on this device, read in place
    /// from the credentials the provider already stores. Nothing new is
    /// persisted: an install signed in before accounts existed keeps its
    /// sign-in unchanged.
    @MainActor func storedAccounts() -> [StoredAccount]
    func restoreAccount(from record: StoredAccount) -> any MediaAccountProvider
    func makeServerProvider(_ seed: ServerSessionSeed) -> any MediaServerProvider
}

/// The provider factories of this build, by kind. A fixed table, built once
/// per `MediaService` because a factory carries that service's client. There is
/// no "current provider": the pool holds sessions of every kind at the same
/// time. Plex is the only entry until Jellyfin's factory lands (J-01).
struct ProviderRegistry: Sendable {
    /// In registration order, which is the order the sign-in host lists them.
    let factories: [any ProviderFactory]

    init(_ factories: [any ProviderFactory]) {
        self.factories = factories
    }

    func factory(for kind: ProviderKind) -> (any ProviderFactory)? {
        factories.first { $0.kind == kind }
    }
}
