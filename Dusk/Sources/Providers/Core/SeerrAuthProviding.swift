import Foundation

/// How an account signs in to Seerr (docs/jellyfin/04-architecture.md §16).
///
/// The facet only describes the sign-in; `SeerrService` sends it through its own
/// session, because Seerr requests carry that session's cookies, XSRF token and
/// pinned certificates. A 401 on any later call re-sends the same login.
protocol SeerrAuthProviding: Sendable {
    /// Whether a Seerr with these public settings takes this account's
    /// sign-in. Answered before anything is sent, also while signed out.
    func accepts(_ settings: SeerrPublicSettings) -> Bool

    /// The sign-in request for this account, or nil while the account has no
    /// credential to sign in with.
    func login() -> SeerrLogin?
}

/// One Seerr sign-in request: the endpoint below `api/v1/auth/` and its JSON
/// body. The body holds a credential.
struct SeerrLogin: Sendable, Equatable {
    /// Relative to the Seerr base URL, for example `api/v1/auth/plex`.
    let path: String
    let body: Data
}
