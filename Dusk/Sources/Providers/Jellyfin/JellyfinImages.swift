import Foundation

/// Jellyfin's `ImageProviding` (docs/jellyfin/04-architecture.md §10). The
/// locator is a `JellyfinArtworkLocator` (`jf:<itemID>:<type>:<index>:<tag>`),
/// and the URL is
///
///     /Items/{itemID}/Images/{type}[/{index}]?tag=…&fillWidth=…&fillHeight=…&quality=90
///
/// - The tag makes the server answer `immutable` for a year and turns the URL
///   into a correct cache key: new artwork has a new tag, so a new URL
///   (03 §10.4).
/// - `fillWidth`/`fillHeight` scale the image to cover the box without
///   cropping and never upscale, which is what Plex's `minSize=1&upscale=0`
///   does, so the same `ImageSize` gives the same pixels on both servers.
/// - Chapter images ignore `fill*` (the server does not know their source
///   size and sends the original frame), so they are bounded with
///   `maxWidth`/`maxHeight` instead.
/// - No `format`: logos stay PNG with their transparency.
///
/// Image URLs need no token, so neither the URL nor the request carries one.
struct JellyfinImages: ImageProviding {
    /// What `quality` Jellyfin re-encodes resized JPEGs at; the server default
    /// is far larger at no visible gain.
    static let quality = 90

    func url(for ref: ArtworkRef, size: ImageSize, session: ServerSession?) -> URL? {
        guard let session, let locator = JellyfinArtworkLocator(locator: ref.locator) else { return nil }

        var query: [URLQueryItem] = []
        if let tag = locator.tag {
            query.append(URLQueryItem(name: "tag", value: tag))
        }
        let width = ImageDisplayScale.pixels(size.width)
        let height = ImageDisplayScale.pixels(size.height)
        if width != nil || height != nil {
            let (widthName, heightName) = locator.type == .chapter
                ? ("maxWidth", "maxHeight")
                : ("fillWidth", "fillHeight")
            if let width { query.append(URLQueryItem(name: widthName, value: String(width))) }
            if let height { query.append(URLQueryItem(name: heightName, value: String(height))) }
            query.append(URLQueryItem(name: "quality", value: String(Self.quality)))
        }
        return Self.url(baseURL: session.baseURL, path: Self.path(for: locator), query: query)
    }

    /// Images are unauthenticated: a plain cached GET.
    func authenticatedRequest(for url: URL, session: ServerSession) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        return request
    }

    // MARK: - URLs

    /// Types that come in a list are always addressed with their index
    /// (`Backdrop/0`); single images by type alone.
    private static let indexedTypes: Set<JellyfinImageType> = [.backdrop, .chapter, .screenshot]

    static func path(for locator: JellyfinArtworkLocator) -> String {
        let base = "/Items/\(segment(locator.itemID))/Images/\(segment(locator.type.rawValue))"
        guard indexedTypes.contains(locator.type) || locator.index > 0 else { return base }
        return base + "/\(locator.index)"
    }

    /// `baseURL` + `path` + `query`, keeping a reverse-proxy path prefix
    /// (`https://host/jellyfin`).
    static func url(baseURL: URL, path: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil, components.host != nil else { return nil }
        let prefix = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = prefix + path
        components.percentEncodedQuery = query.isEmpty ? nil : query.map { item in
            "\(segment(item.name))=\(segment(item.value ?? ""))"
        }.joined(separator: "&")
        return components.url
    }

    /// Ids, tags and type names are hex and words; anything else is encoded so
    /// it can never add a path segment or a parameter.
    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: JellyfinAuthorization.unreserved) ?? ""
    }
}
