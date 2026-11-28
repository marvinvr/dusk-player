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
    /// Whether one of this provider's signed-in accounts holds `serverID`.
    /// How a server id finds its provider when `ServerRegistry` has no record
    /// of it: a provider's accounts already persist their server ids.
    @MainActor func ownsServer(_ serverID: String) -> Bool
    /// How the pool tests one endpoint of `serverID` with `credential`. nil:
    /// the pool's built-in probe (Plex's `/identity` + `/library/sections`).
    @MainActor func connectionProbe(serverID: String, credential: String) -> ConnectionProbe?
}

extension ProviderFactory {
    @MainActor func ownsServer(_ serverID: String) -> Bool { false }
    @MainActor func connectionProbe(serverID: String, credential: String) -> ConnectionProbe? { nil }
}

/// Tests one candidate endpoint of one server: does it answer as that server
/// and accept the credential?
typealias ConnectionProbe = @Sendable (ConnectionCandidate) async -> ConnectionProbeOutcome

/// The provider factories of this build, by kind. A fixed table, built once
/// per `MediaService` because a factory carries that service's client. There is
/// no "current provider": the pool holds sessions of every kind at the same
/// time.
struct ProviderRegistry: Sendable {
    /// In registration order, which is the order the sign-in host lists them.
    let factories: [any ProviderFactory]

    init(_ factories: [any ProviderFactory]) {
        self.factories = factories
    }

    /// The last factory registered for `kind`: a test's fake factory, added
    /// after the standard ones, replaces the build's own.
    func factory(for kind: ProviderKind) -> (any ProviderFactory)? {
        factories.last { $0.kind == kind }
    }

    /// The provider of `serverID`: its `ServerRegistry` record, else the
    /// provider whose accounts hold it, else Plex (every id persisted before
    /// Jellyfin support has no record).
    @MainActor
    func kind(for serverID: String?, registry: ServerRegistry) -> ProviderKind {
        guard let serverID = serverID?.nilIfEmpty else { return .plex }
        if let record = registry.record(for: serverID) { return record.kind }
        return factories.last { $0.ownsServer(serverID) }?.kind ?? .plex
    }
}
