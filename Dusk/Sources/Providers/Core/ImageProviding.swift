import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Turns an `ArtworkRef` into an image request (docs/jellyfin/04-architecture.md
/// §10). `MediaService+Images` routes every ref to its server's provider.
///
/// The provider is per server but does not hold the live endpoint or token
/// (the pool re-records those as connections heal), so the facade hands in
/// the `ServerSession` it resolved for the ref. Fetching, the image cache, the
/// token refresh after a 401 and matching a URL back to its server stay in
/// the facade; a provider only builds URLs and requests.
@MainActor
protocol ImageProviding: Sendable {
    /// The URL that loads `ref` at `size` (points; the provider scales to the
    /// display). `session` is the connected session of `ref.serverID`, nil when
    /// that server is not connected: a provider still answers for refs that do
    /// not need one, such as an absolute URL. nil when no URL can be built.
    func url(for ref: ArtworkRef, size: ImageSize, session: ServerSession?) -> URL?

    /// The request that fetches `url`, a URL on `session`'s server, with that
    /// session's credentials.
    func authenticatedRequest(for url: URL, session: ServerSession) -> URLRequest
}

/// Points to pixels for image requests: every provider asks for artwork sized
/// for the sharpest screen the app draws on.
@MainActor
enum ImageDisplayScale {
    static var current: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.scale
        #elseif os(macOS)
        // Retina Macs draw at 2x; artwork is requested for the sharpest screen.
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        #else
        1
        #endif
    }

    /// `points` in pixels, rounded up; nil for a missing or non-positive side.
    static func pixels(_ points: Int?) -> Int? {
        guard let points, points > 0 else { return nil }
        return Int(ceil(Double(points) * Double(current)))
    }
}
