import Foundation

/// One signed-in account, whatever it signs in to (docs/jellyfin/04-architecture.md
/// §3, §7). Built from a `StoredAccount` by its provider's
/// `ProviderFactory.restoreAccount(from:)`; `AccountStore` holds the result.
///
/// The account owns its credential and the discovery of its servers. For
/// Plex the facade still orchestrates sign-in, Plex Home switches and the
/// connect pass (`MediaService+Auth`, `+Home`, `+Servers`). Every other
/// account runs its own session through `session` (`AccountSession`), and the
/// pool probes its servers with `probe(_:in:)`.
protocol MediaAccountProvider: AnyObject, Sendable {
    var account: AccountDescriptor { get }

    /// Every server this account can use, each with the endpoints worth trying.
    func servers() async throws -> [ServerCandidateSet]
    /// Tries one endpoint of one server: does it answer as that server, with
    /// this account's credential?
    func probe(_ candidate: ConnectionCandidate, in set: ServerCandidateSet) async -> ProbeResult
    /// Forgets this account's credentials on this device.
    func signOut() async

    /// Loads the stored credential and profile at launch.
    /// - Parameter readsStoredSignIn: false only for screenshot mode's signed-out
    ///   start, which must never touch a real sign-in.
    @MainActor func restoreCredentials(readsStoredSignIn: Bool)
    /// Hands the account's request core the pool it heals sessions through.
    @MainActor func attach(recovering: any SessionRecovering)

    var profiles: any ProfileProviding { get }
    var preferences: any AccountPreferencesProviding { get }
    var watchlist: (any WatchlistProviding)? { get }
    /// Built on every read, so it carries the active profile's credential.
    @MainActor var seerrAuth: any SeerrAuthProviding { get }

    /// The account's own session, for an account whose profiles the facade
    /// does not bootstrap. nil for Plex: its Plex Home state lives on the
    /// facade (`MediaService+Home`).
    @MainActor var session: (any AccountSession)? { get }
}

extension MediaAccountProvider {
    @MainActor var session: (any AccountSession)? { nil }
}

/// The session of an account that resolves its own profiles and servers
/// (docs/jellyfin/04-architecture.md §7). The facade reads it instead of the
/// Plex Home state when such an account is the primary one, and keeps the
/// teardown and the pool.
@MainActor
protocol AccountSession: AnyObject {
    /// A profile is signed in (or one has to be chosen).
    var isSignedIn: Bool { get }
    /// The storage scope of the active profile; nil while none is active.
    var activeProfileID: String? { get }
    /// The profile picker is up: asked for from Settings, or nothing is active.
    var needsProfileSelection: Bool { get }
    /// What the profile picker asks for when a profile is protected.
    var profileSecret: ProfileSecretKind { get }

    /// The active profile's servers, with their credentials, as the pool
    /// connects them. Never reaches the network.
    func accountServers() -> [AccountServer]
    /// Re-reads what the server says about the active profile after launch
    /// (its permissions). A transport failure is not a sign-out.
    func refresh() async throws
    /// Makes `profile` the active one. `secret` goes only into this request.
    /// The facade tears the server sessions down afterwards.
    func switchProfile(_ profile: Profile, secret: String?) async throws
    func requestProfileSelection()
    func cancelProfileSelection()
    /// Ends every profile's session on the server and forgets them here.
    func signOutAll() async
}

/// Who is signed in, as the account names them (the Mac's account row).
struct AccountUser: Sendable, Hashable {
    let username: String?
    let title: String?
    let friendlyName: String?
    let thumb: String?
    let email: String?
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
