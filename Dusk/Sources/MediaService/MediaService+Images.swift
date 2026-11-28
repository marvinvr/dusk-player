import Foundation

extension MediaService {
    /// The URL that loads `ref` at `size` (docs/jellyfin/04-architecture.md §10),
    /// built by the provider of the ref's server (`ImageProviding`).
    ///
    /// `ref.serverID` is the server the artwork belongs to. nil means the
    /// primary server, which is only correct for artwork that has no item
    /// behind it; everything derived from a `MediaItem`/`MediaDetails` carries
    /// that model's `serverID`.
    func imageURL(for ref: ArtworkRef?, size: ImageSize = .original) -> URL? {
        guard let ref else { return nil }
        // IPTV logos and programme icons are absolute URLs on their own hosts
        // and have nothing to do with any server.
        if ref.serverID == IPTVImages.serverID {
            return IPTVImageProvider().url(for: ref, size: size, session: nil)
        }

        let session = pool.connection(for: ref.serverID)
        return imageProvider(for: session).url(for: ref, size: size, session: session)
    }

    func imageData(for url: URL) async throws -> Data {
        if let connection = imageServerConnection(for: url) {
            return try await rawImageServerRequest(url: url, connection: connection)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        return try await executeBinaryRequest(request)
    }

    /// The image facet of `session`'s server. A server that is not connected,
    /// or a session built outside the pool (tests), has no provider to ask;
    /// every such server is Plex today, so Plex answers (absolute-URL artwork
    /// still resolves without a session).
    private func imageProvider(for session: ServerSession?) -> any ImageProviding {
        session?.provider?.images ?? PlexImages(client: client)
    }

    /// Plex only, for `+Photos` (the viewer builds its own `/photo/:/transcode`
    /// URL) until the catalog facet takes it over.
    func transcodeSourceURLString(for path: String, serverID: String? = nil) -> String? {
        PlexImages(client: client).transcodeSourceURLString(for: path, session: pool.connection(for: serverID))
    }

    /// Plex only: the image URL string on the server's connection, optionally
    /// with the token in the query.
    func imageRequestURLString(for path: String, includeToken: Bool, serverID: String? = nil) -> String? {
        PlexImages(client: client).imageRequestURLString(
            for: path,
            includeToken: includeToken,
            session: pool.connection(for: serverID)
        )
    }

    /// `points` in display pixels (`ImageDisplayScale`).
    func scaledImageDimension(_ dimension: Int?) -> Int? {
        ImageDisplayScale.pixels(dimension)
    }

    /// The connected server an artwork URL points at, matched on scheme, host,
    /// and port.
    ///
    /// Checked against *every* connected server, not just the primary one:
    /// artwork for an item that lives on the second server is served by that
    /// server, and matching only the primary would send it out unauthenticated.
    /// Needed while `DuskAsyncImage`, downloads and Top Shelf fetch by URL
    /// rather than by `ArtworkRef`.
    func imageServerConnection(for url: URL) -> ServerSession? {
        pool.connections.first { connection in
            let baseURL = connection.baseURL
            let normalizedURLPort = url.port ?? defaultPort(for: url.scheme)
            let normalizedServerPort = baseURL.port ?? defaultPort(for: baseURL.scheme)

            return url.scheme?.lowercased() == baseURL.scheme?.lowercased()
                && url.host?.lowercased() == baseURL.host?.lowercased()
                && normalizedURLPort == normalizedServerPort
        }
    }

    private func rawImageServerRequest(url: URL, connection: ServerSession) async throws -> Data {
        do {
            return try await sendImageServerRequest(url: url, connection: connection)
        } catch let error as PlexServiceError where error == .unauthorized {
            plexAuthLogger.notice("Image request unauthorized for \(url.path, privacy: .public); attempting token refresh")
            let refreshed = try await refreshedImageConnection(serverID: connection.serverID)
            do {
                return try await sendImageServerRequest(url: url, connection: refreshed)
            } catch let retryError as PlexServiceError where retryError == .unauthorized {
                // Only this server is out; the rest of the pool keeps working.
                pool.markUnauthorized(serverID: connection.serverID)
                throw retryError
            }
        }
    }

    /// Re-authorizes the one server an image belongs to and hands back its new
    /// session.
    private func refreshedImageConnection(serverID: String) async throws -> ServerSession {
        try await refreshServerAuthorization(serverID: serverID)
        guard let connection = pool.connection(for: serverID) else {
            throw PlexServiceError.unauthorized
        }
        return connection
    }

    /// One authenticated attempt on `connection`'s server, through the image
    /// cache and `executeRequest` (transport check, fresh-sign-in retry).
    private func sendImageServerRequest(url: URL, connection: ServerSession) async throws -> Data {
        let request = imageProvider(for: connection).authenticatedRequest(for: url, session: connection)

        if let cachedResponse = AppImageCache.cachedResponse(for: request) {
            return cachedResponse.data
        }

        let data = try await executeRequest(request)
        if let cachedResponse = URLCache.shared.cachedResponse(for: request) {
            AppImageCache.storeCachedResponse(cachedResponse, for: request)
        }
        return data
    }

    private func executeBinaryRequest(_ request: URLRequest) async throws -> Data {
        try PlexTransportSecurity.validate(request)
        if let cachedResponse = AppImageCache.cachedResponse(for: request) {
            return cachedResponse.data
        }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PlexServiceError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PlexServiceError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200...299:
            if let cachedResponse = URLCache.shared.cachedResponse(for: request) {
                AppImageCache.storeCachedResponse(cachedResponse, for: request)
            }
            return data
        case 401:
            throw PlexServiceError.unauthorized
        default:
            throw PlexServiceError.httpError(statusCode: http.statusCode)
        }
    }

    private func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}
