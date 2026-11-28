import Foundation

/// Plex's `ImageProviding`. The locator is the server-relative path
/// (`/library/metadata/1/thumb/1700000000`) or an absolute URL. With a size the
/// image goes through `/photo/:/transcode`; without one it is the plain path on
/// the session's base URL. URLs never carry the token; `authenticatedRequest`
/// adds it as a header.
struct PlexImages: ImageProviding {
    let client: PlexClient

    func url(for ref: ArtworkRef, size: ImageSize, session: ServerSession?) -> URL? {
        let path = ref.locator
        let requestSize = ImageRequestSize(
            width: ImageDisplayScale.pixels(size.width),
            height: ImageDisplayScale.pixels(size.height)
        )
        if requestSize.hasDimensions,
           let transcodedURL = transcodedImageURL(for: path, size: requestSize, session: session) {
            return transcodedURL
        }

        return directImageURL(for: path, session: session)
    }

    func authenticatedRequest(for url: URL, session: ServerSession) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        client.applyHeaders(to: &request, token: session.token)
        return request
    }

    // MARK: - Plex URLs

    func directImageURL(for path: String, session: ServerSession?) -> URL? {
        guard let urlString = imageRequestURLString(for: path, includeToken: false, session: session) else {
            return nil
        }
        return URL(string: urlString)
    }

    func transcodedImageURL(for path: String, size: ImageRequestSize, session: ServerSession?) -> URL? {
        guard let connection = session,
              let originalURLString = transcodeSourceURLString(for: path, session: session) else {
            return nil
        }

        let baseURL = connection.baseURL
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        guard var components = URLComponents(string: base + "/photo/:/transcode") else {
            return nil
        }

        var items = [
            URLQueryItem(name: "width", value: String(max(size.width ?? 1, 1))),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "0"),
            URLQueryItem(name: "url", value: originalURLString),
        ]

        if let height = size.height {
            items.append(URLQueryItem(name: "height", value: String(height)))
        }

        components.queryItems = items
        return PlexTransportSecurity.authenticatedURL(components.url)
    }

    func imageRequestURLString(for path: String, includeToken: Bool, session: ServerSession?) -> String? {
        if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
            return (try? PlexTransportSecurity.validate(URLRequest(url: absoluteURL))) != nil ? absoluteURL.absoluteString : nil
        }

        guard let connection = session else { return nil }
        let baseURL = connection.baseURL
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        guard var components = URLComponents(string: base + path) else { return nil }

        if includeToken {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "X-Plex-Token", value: connection.token))
            components.queryItems = items
        }

        return PlexTransportSecurity.authenticatedURL(components.url)?.absoluteString
    }

    /// The `url` for `/photo/:/transcode`. Library paths are sent relative, as
    /// Plex Web does. Sending the server its own full URL breaks posters on a
    /// LAN connection: the server fetches itself and gets a 404. Artwork that
    /// is already a full URL is sent unchanged. nil for a library path when the
    /// server is not connected.
    func transcodeSourceURLString(for path: String, session: ServerSession?) -> String? {
        if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
            return (try? PlexTransportSecurity.validate(URLRequest(url: absoluteURL))) != nil ? absoluteURL.absoluteString : nil
        }
        guard session != nil else { return nil }
        return path.hasPrefix("/") ? path : "/" + path
    }
}

/// A Plex image request's size in pixels.
struct ImageRequestSize {
    let width: Int?
    let height: Int?

    var hasDimensions: Bool {
        width != nil || height != nil
    }
}

extension PlexServerProvider {
    var images: any ImageProviding { PlexImages(client: client) }
}
