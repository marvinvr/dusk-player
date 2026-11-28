import Foundation

/// IPTV's `ImageProviding` (docs/jellyfin/04-architecture.md §10). Logos and
/// programme icons are absolute URLs on their own hosts, tagged with the
/// `IPTVImages.serverID` sentinel: they are returned untouched, never sized
/// and never sent through any server's photo transcoder.
struct IPTVImageProvider: ImageProviding {
    func url(for ref: ArtworkRef, size: ImageSize, session: ServerSession?) -> URL? {
        M3UParser.httpURL(ref.locator)
    }

    /// IPTV art has no server and no credentials: a plain request.
    func authenticatedRequest(for url: URL, session: ServerSession) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        return request
    }
}
