import Foundation

/// The credential rules (04 §8) for code that handles a URL or a request
/// without knowing which server it belongs to: downloads, artwork, Seerr, the
/// subtitle and error-text fetches, the remux relay and the Dolby Vision 7
/// proxy, the pool's endpoint checks. Each forwards to this build's provider
/// policy, which today is Plex's (`PlexTransportSecurity`), so every rule is
/// exactly the one it was. Jellyfin's policy joins `validate` and
/// `allowsRedirect`, which never match a Plex request.
enum TransportSecurity {
    /// A session whose redirects follow the policy.
    static var session: URLSession { PlexTransportSecurity.session }

    /// The delegate that keeps a credential off redirects, for sessions built
    /// elsewhere.
    static func makeSessionDelegate() -> any URLSessionTaskDelegate {
        PlexTransportSessionDelegate()
    }

    /// The policy a `PlaybackSource` gets when its server's is not known.
    static var defaultPolicy: any CredentialTransportPolicy { PlexCredentialPolicy.shared }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        PlexTransportSecurity.sameOrigin(lhs, rhs)
    }

    /// Whether a credential may be sent to `url`.
    static func allowsCredential(in url: URL) -> Bool {
        PlexTransportSecurity.allowsToken(in: url)
    }

    /// `url` when a credential may be sent to it, else nil.
    static func authenticatedURL(_ url: URL?) -> URL? {
        PlexTransportSecurity.authenticatedURL(url)
    }

    /// Throws when `request` would send a credential where it must not go.
    /// Jellyfin's credential (its `Authorization` token, `ApiKey=`) is checked
    /// too: a download or sidecar request can carry either provider's.
    static func validate(_ request: URLRequest) throws {
        try PlexTransportSecurity.validate(request)
        try JellyfinCredentialPolicy.shared.validate(request)
    }

    static func allowsRedirect(_ request: URLRequest, original: URLRequest?) -> Bool {
        PlexTransportSecurity.allowsRedirect(request, original: original)
            && JellyfinCredentialPolicy.shared.allowsRedirect(request, original: original)
    }
}
