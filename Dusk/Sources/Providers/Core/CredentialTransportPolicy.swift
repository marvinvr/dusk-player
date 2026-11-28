import Foundation

/// Where a provider's credential may travel (docs/jellyfin/04-architecture.md §8),
/// one policy per provider: which requests carry a secret (`X-Plex-Token`,
/// `ApiKey`), whether a URL may carry one over plain HTTP, and which redirects
/// keep it. The engines and `RemuxHLSLoader` check a stream's URLs against the
/// policy of the `PlaybackSource` instead of naming a provider.
protocol CredentialTransportPolicy: Sendable {
    func allowsCredential(in url: URL) -> Bool
    func carriesCredential(_ request: URLRequest) -> Bool
    /// Throws when `request` would send a credential where it must not go.
    func validate(_ request: URLRequest) throws
    func allowsRedirect(_ request: URLRequest, original: URLRequest?) -> Bool
    /// A session whose redirects follow this policy, for loaders that fetch a
    /// stream's playlists and segments themselves.
    var session: URLSession { get }
}
