import Foundation

/// Plex's `SeerrAuthProviding`: `POST api/v1/auth/plex` with the account's
/// plex.tv token in the body. Needs a Plex-backed Seerr, or a fresh one that
/// has not picked a media server yet (its first Plex sign-in creates the admin).
///
/// The token is the facade's `activeAccountToken` (the switched Plex Home
/// member's, not always the primary account's), read when the facet is built:
/// `MediaService.seerrAuth` builds one per sign-in. `PlexTransportSecurity`
/// recognises the `authToken` body as a credential and enforces its transport.
struct PlexSeerrAuth: SeerrAuthProviding {
    /// nil when there is no signed-in account, and on the provider's own facet
    /// (see `PlexAccountProvider.seerrAuth`) until the account layer holds the
    /// token: then `login()` has nothing to send.
    let accountToken: String?

    func accepts(_ settings: SeerrPublicSettings) -> Bool {
        settings.acceptsPlexLogin
    }

    func login() -> SeerrLogin? {
        guard let accountToken,
              let body = try? JSONEncoder().encode(LoginBody(authToken: accountToken)) else {
            return nil
        }
        return SeerrLogin(path: "api/v1/auth/plex", body: body)
    }

    private struct LoginBody: Encodable {
        let authToken: String
    }
}

extension PlexAccountProvider {
    /// The account's credential still lives in the facade (P0-16 moves it
    /// here), so this facet has none: Seerr signs in through
    /// `MediaService.seerrAuth`.
    @MainActor var seerrAuth: any SeerrAuthProviding { PlexSeerrAuth(accountToken: state.activeAccountToken) }
}
