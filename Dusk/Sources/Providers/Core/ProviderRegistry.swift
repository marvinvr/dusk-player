import Foundation

/// Builds one provider's objects (docs/jellyfin/04-architecture.md §3).
/// `makeSignInFlow()` and `restoreAccount(from:)` join with the account layer
/// (P0-16), which brings `SignInFlow`'s host and `StoredAccount`.
protocol ProviderFactory: Sendable {
    var kind: ProviderKind { get }
    func makeServerProvider(_ seed: ServerSessionSeed) -> any MediaServerProvider
}

/// The provider factories of this build, by kind. A fixed table, built once
/// per `MediaService` because a factory carries that service's client. There is
/// no "current provider": the pool holds sessions of every kind at the same
/// time. Plex is the only entry until Jellyfin's factory lands (J-01).
struct ProviderRegistry: Sendable {
    private let factories: [ProviderKind: any ProviderFactory]

    init(_ factories: [any ProviderFactory]) {
        self.factories = Dictionary(uniqueKeysWithValues: factories.map { ($0.kind, $0) })
    }

    func factory(for kind: ProviderKind) -> (any ProviderFactory)? {
        factories[kind]
    }
}
