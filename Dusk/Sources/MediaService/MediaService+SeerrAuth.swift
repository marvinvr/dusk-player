import Foundation

extension MediaService {
    /// How the signed-in account signs in to Seerr (docs/jellyfin/04-architecture.md
    /// §16). Built on every call so it always carries the current Plex Home
    /// member's credential. Only Plex accounts exist so far; once the account
    /// layer holds the credential (P0-16) this is the binding account's
    /// `seerrAuth`.
    var seerrAuth: any SeerrAuthProviding {
        PlexSeerrAuth(accountToken: activeAccountToken)
    }
}
