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

    func scrubPreviewSource(forPartID partID: String, serverID: String? = nil) async -> PlexScrubPreviewSource? {
        // Plex part ids are positive numbers; 0 or below is a placeholder.
        guard Int(partID).map({ $0 > 0 }) ?? !partID.isEmpty else { return nil }

        do {
            let data = try await rawScrubPreviewRequest(partID: partID, serverID: serverID)
            guard !data.isEmpty, data.count <= PlexBIFParser.maxFileSize else { return nil }

            let frames = await Task.detached(priority: .utility) {
                PlexBIFParser.parse(data)
            }.value

            guard !frames.isEmpty else { return nil }
            return PlexScrubPreviewSource(frames: frames)
        } catch {
            return nil
        }
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

    private func rawScrubPreviewRequest(partID: String, serverID: String?) async throws -> Data {
        let targetID = try resolveServerID(serverID)

        if pool.connection(for: targetID) == nil {
            try await refreshServerAuthorization(serverID: targetID)
        }

        do {
            return try await sendScrubPreviewRequest(partID: partID, serverID: targetID)
        } catch let error as PlexServiceError where error == .unauthorized {
            try await refreshServerAuthorization(serverID: targetID)
            return try await sendScrubPreviewRequest(partID: partID, serverID: targetID)
        }
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

    private func sendScrubPreviewRequest(partID: String, serverID: String) async throws -> Data {
        guard let connection = pool.connection(for: serverID) else {
            switch pool.state(for: serverID) {
            case .unauthorized:
                throw isAuthenticationFresh ? PlexServiceError.authenticationPending : PlexServiceError.unauthorized
            default:
                throw PlexServiceError.noServerConnected
            }
        }

        guard let url = buildURL(
            base: connection.baseURL.absoluteString,
            path: "/library/parts/\(partID)/indexes/sd"
        ) else {
            throw PlexServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        applyHeaders(to: &request, token: connection.token)
        request.setValue("application/octet-stream,image/*,*/*", forHTTPHeaderField: "Accept")

        return try await executeRequest(request)
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

private enum PlexBIFParser {
    static let maxFileSize = 50 * 1024 * 1024

    private static let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]

    static func parse(_ data: Data) -> [PlexScrubPreviewFrame] {
        guard data.count >= 72, data.count <= maxFileSize else { return [] }

        let bytes = [UInt8](data)
        guard Array(bytes.prefix(magic.count)) == magic else { return [] }

        let imageCountValue = uint32(at: 12, in: bytes)
        guard imageCountValue > 0 else {
            return []
        }

        let imageCount = Int(imageCountValue)
        let tableEntryCount = imageCount + 1
        guard tableEntryCount > imageCount,
              tableEntryCount <= (bytes.count - 64) / 8 else {
            return []
        }

        let rawMultiplier = uint32(at: 16, in: bytes)
        let timestampMultiplier = Int64(rawMultiplier == 0 ? 1000 : rawMultiplier)

        var frames: [PlexScrubPreviewFrame] = []
        frames.reserveCapacity(imageCount)

        for index in 0..<imageCount {
            let entryOffset = 64 + (index * 8)
            let timestamp = uint32(at: entryOffset, in: bytes)
            let imageOffset = Int(uint32(at: entryOffset + 4, in: bytes))
            let nextImageOffset = Int(uint32(at: entryOffset + 12, in: bytes))

            guard nextImageOffset > imageOffset,
                  nextImageOffset <= data.count else {
                continue
            }

            frames.append(
                PlexScrubPreviewFrame(
                    timestampMs: Int64(timestamp) * timestampMultiplier,
                    imageData: data.subdata(in: imageOffset..<nextImageOffset)
                )
            )
        }

        return frames
    }

    private static func uint32(at offset: Int, in bytes: [UInt8]) -> UInt32 {
        guard offset >= 0, offset + 3 < bytes.count else { return 0 }

        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
