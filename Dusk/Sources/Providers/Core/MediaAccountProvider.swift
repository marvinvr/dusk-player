import Foundation

/// One signed-in account, whatever it signs in to (docs/jellyfin/04-architecture.md
/// §3, §7). The facets start empty like `MediaServerProvider`'s.
///
/// Still in the facade until the account layer (P0-16) moves them here:
/// `account` (`AccountDescriptor`), server discovery (`servers()`), connection
/// probing (`probe(_:)`) and `signOut()`.
protocol MediaAccountProvider: AnyObject, Sendable {
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
