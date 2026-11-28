import Foundation

extension MediaService {
    /// How the signed-in account signs in to Seerr (docs/jellyfin/04-architecture.md
    /// §16): the account's own facet, built on every read so it always carries
    /// the active profile's credential.
    var seerrAuth: any SeerrAuthProviding {
        primaryAccount.seerrAuth
    }
}
