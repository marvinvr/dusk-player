import Foundation

/// One signed-in account, whatever it signs in to (docs/jellyfin/04-architecture.md
/// §3, §7). Built from a `StoredAccount` by its provider's
/// `ProviderFactory.restoreAccount(from:)`; `AccountStore` holds the result.
///
/// The account owns its credential and the discovery of its servers. The
/// facade still orchestrates sign-in, profile switches and the connect pass
/// (state transitions, teardown, persistence), and the pool still consumes the
/// provider's own server snapshots: wiring the pool through `servers()` and
/// `probe(_:in:)` arrives with the first account that is not Plex.
protocol MediaAccountProvider: AnyObject, Sendable {
    var account: AccountDescriptor { get }

    /// Every server this account can use, each with the endpoints worth trying.
    func servers() async throws -> [ServerCandidateSet]
    /// Tries one endpoint of one server: does it answer as that server, with
    /// this account's credential?
    func probe(_ candidate: ConnectionCandidate, in set: ServerCandidateSet) async -> ProbeResult
    /// Forgets this account's credentials on this device.
    func signOut() async

    var profiles: any ProfileProviding { get }
    var preferences: any AccountPreferencesProviding { get }
    var watchlist: (any WatchlistProviding)? { get }
    var seerrAuth: any SeerrAuthProviding { get }
}

/// Who an account is.
struct AccountDescriptor: Sendable, Hashable {
    let id: String
    let kind: ProviderKind
    let displayName: String
}

/// One server an account discovered: who it is, the credential to use with it
/// and every endpoint worth probing. Order of `candidates` is not priority;
/// `ConnectionSelector` ranks them.
struct ServerCandidateSet: Sendable, Hashable {
    let seed: ServerSessionSeed
    /// Server-scoped credential. Never the account credential.
    let credential: String?
    let candidates: [ConnectionCandidate]
}

/// What one probe of one candidate found.
typealias ProbeResult = ConnectionProbeOutcome
