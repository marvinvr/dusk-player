import Foundation

/// Where the app's session stands (docs/jellyfin/04-architecture.md §7.3).
/// `ContentView` routes on it: sign-in, the bootstrap screen, the profile
/// picker, or the app.
enum SessionState: Sendable, Hashable {
    /// No account is signed in.
    case signedOut
    /// Signed in; the account's profiles are still being resolved.
    case bootstrapping
    /// The account has several profiles and one has to be chosen.
    case needsProfile
    /// A profile is active; the app shell mounts.
    case ready
}

/// The app-wide storage scope: the active profile of the primary account.
/// Downloads, IPTV sources, Trakt, Seerr, pinned playlists and remembered
/// tracks are filed under `id`, which is exactly today's `activeProfileID`.
struct ProfileScope: Sendable, Hashable {
    let id: String
}

/// The accounts signed in on this device and their providers
/// (docs/jellyfin/04-architecture.md §2, §7.1).
///
/// Nothing here is persisted. Each provider reads its own records in place
/// from the credentials it already stores (`ProviderFactory.storedAccounts()`),
/// so an install signed in before accounts existed reads exactly as it was
/// written. Plex is the only provider, so there is at most one account and it
/// is the primary one; linked accounts (04 §7.3) arrive with J-13.
@MainActor
@Observable
final class AccountStore {
    let registry: ProviderRegistry

    init(registry: ProviderRegistry) {
        self.registry = registry
    }

    /// Every signed-in account, primary first.
    var accounts: [StoredAccount] {
        registry.factories.flatMap { $0.storedAccounts() }
    }

    /// The account signed in from the sign-in screen. Its active profile
    /// defines the storage scope.
    var primary: StoredAccount? { accounts.first }

    var isSignedIn: Bool { primary != nil }

    func provider(for account: StoredAccount) -> (any MediaAccountProvider)? {
        registry.factory(for: account.kind)?.restoreAccount(from: account)
    }

    var primaryProvider: (any MediaAccountProvider)? {
        primary.flatMap(provider(for:))
    }

    /// The sign-in flows the sign-in host offers, in registry order.
    var signInFlows: [any SignInFlow] {
        registry.factories.map { $0.makeSignInFlow() }
    }
}
