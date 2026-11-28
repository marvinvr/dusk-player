import Foundation

/// Downloads: routes to the server's `DownloadProviding` facet. The facade
/// keeps what needs the pool and the active profile: which session a request
/// goes to, the owning-profile and switched-off-server checks around every
/// await of a converted download, and the healing server read for snapshots.
extension MediaService {
    /// The presets the download quality menu offers for an item.
    func downloadQualities(for item: MediaItemID) -> [DownloadQuality] {
        pool.connection(for: item.serverID)?.provider?.downloads.qualities(for: item)
            ?? DownloadQuality.allCases
    }

    /// The provider behind a server id, from its live session when there is
    /// one. A server without a session or record is Plex (`ServerRegistry`).
    func downloadProviderKind(for serverID: String?) -> ProviderKind {
        pool.connection(for: serverID)?.provider?.descriptor.kind ?? .plex
    }

    /// The snapshot formats of every provider in this build, for reading the
    /// offline metadata without a session.
    var metadataSnapshotFormats: MetadataSnapshotFormats {
        MetadataSnapshotFormats([ProviderKind.plex, .jellyfin].compactMap {
            (providers.factory(for: $0) as? any MetadataSnapshotFormatProviding)?.metadataSnapshotFormat
        })
    }

    // MARK: - Original file, sidecars, snapshot

    /// The original file's transfer request on the item's server.
    func originalDownloadRequest(for part: MediaPart, serverID: String) -> URLRequest? {
        guard let connection = pool.connection(for: serverID),
              let sourceURL = directPlayURL(for: part, serverID: serverID),
              let downloads = connection.provider?.downloads else {
            return nil
        }
        return downloads.originalFileRequest(url: sourceURL, credential: connection.token)
    }

    /// One external text subtitle saved next to a download.
    func offlineSidecar(for stream: MediaStream, serverID: String) -> SidecarDownload? {
        guard let url = externalSubtitleURL(for: stream, serverID: serverID),
              let downloads = pool.connection(for: serverID)?.provider?.downloads else {
            return nil
        }
        return SidecarDownload(request: URLRequest(url: url)) { request in
            try await downloads.fetchSidecar(request)
        }
    }

    /// The raw payload the offline cache stores for `key`, through the same
    /// healing server read every other request takes.
    func metadataSnapshot(_ key: MetadataSnapshotKey, serverID: String) async throws -> Data {
        guard let format = metadataSnapshotFormats.format(for: downloadProviderKind(for: serverID)) else {
            throw MediaServiceError.noServerConnected
        }
        let request = format.fetchRequest(for: key)
        return try await rawServerRequest(path: request.path, queryItems: request.queryItems, serverID: serverID)
    }

    // MARK: - Converted downloads

    /// `clientIdentifier` must be unique to this durable download request; see
    /// `DownloadProviding.conversionHeaders`.
    func captureConversionContext(
        serverID: String,
        profileID: String,
        clientIdentifier: String
    ) throws -> DownloadConversionContext {
        guard !profileID.isEmpty, activeProfileID == profileID else {
            throw DownloadPreparationError.wrongProfile
        }
        guard !clientIdentifier.isEmpty, let connection = pool.connection(for: serverID),
              let downloads = connection.provider?.downloads else {
            throw MediaServiceError.noServerConnected
        }
        return DownloadConversionContext(
            profileID: profileID,
            connection: connection,
            headers: downloads.conversionHeaders(clientIdentifier: clientIdentifier, credential: connection.token)
        )
    }

    /// Server-assigned. Idempotent for the context's client identifier and
    /// user. Persist the result before adding.
    func createConversionQueue(context: DownloadConversionContext) async throws -> String {
        try await conversionProvider(context).createConversionQueue(via: conversionTransport(context))
    }

    func addConversionJob(
        context: DownloadConversionContext,
        queueID: String,
        itemID: String,
        mediaIndex: Int,
        quality: DownloadQuality
    ) async throws -> String {
        try await conversionProvider(context).addConversionJob(
            queueID: queueID, itemID: itemID, mediaIndex: mediaIndex, quality: quality,
            via: conversionTransport(context)
        )
    }

    func conversionJobs(context: DownloadConversionContext, queueID: String) async throws -> [ConversionJob] {
        try await conversionProvider(context).conversionJobs(queueID: queueID, via: conversionTransport(context))
    }

    func conversionJob(
        context: DownloadConversionContext,
        queueID: String,
        jobID: String
    ) async throws -> ConversionJob {
        try await conversionProvider(context).conversionJob(queueID: queueID, jobID: jobID, via: conversionTransport(context))
    }

    func preparedConversion(
        context: DownloadConversionContext,
        queueID: String,
        jobID: String,
        sourceMedia: MediaVersion
    ) async throws -> ConvertedDownload {
        try await conversionProvider(context).preparedConversion(
            queueID: queueID, jobID: jobID, sourceMedia: sourceMedia, via: conversionTransport(context)
        )
    }

    func removeConversionJob(
        context: DownloadConversionContext,
        queueID: String,
        jobID: String
    ) async throws {
        try await conversionProvider(context).removeConversionJob(queueID: queueID, jobID: jobID, via: conversionTransport(context))
    }

    private func conversionProvider(_ context: DownloadConversionContext) throws -> any DownloadProviding {
        guard let downloads = context.connection.provider?.downloads else { throw MediaServiceError.noServerConnected }
        return downloads
    }

    private func conversionTransport(_ context: DownloadConversionContext) -> any DownloadConversionTransport {
        ConversionTransport(media: self, context: context)
    }

    fileprivate func validateConversionContext(_ context: DownloadConversionContext) throws {
        guard activeProfileID == context.profileID else { throw DownloadPreparationError.wrongProfile }
        guard pool.state(for: context.connection.serverID) != .disabled else {
            throw MediaServiceError.noServerConnected
        }
    }
}

/// The facade's side of a converted download's requests: the captured
/// connection and headers, the context check before and after every await,
/// and no token refresh, which could land on another Home user's token.
@MainActor
private struct ConversionTransport: DownloadConversionTransport {
    let media: MediaService
    let context: DownloadConversionContext

    func request(method: String, path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        try media.validateConversionContext(context)
        guard let url = media.buildURL(base: context.connection.baseURL.absoluteString, path: path, queryItems: queryItems) else {
            throw MediaServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allHTTPHeaderFields = context.headers
        try TransportSecurity.validate(request)
        return request
    }

    func send(method: String, path: String, queryItems: [URLQueryItem], canExpire: Bool) async throws -> Data {
        let request = try request(method: method, path: path, queryItems: queryItems)
        do {
            // This request must not refresh into another Home user's token.
            let data = try await media.executeRequest(request, retriesFreshAuthentication: false)
            try Task.checkCancellation()
            try media.validateConversionContext(context)
            return data
        } catch MediaServiceError.httpError(let status) where canExpire && [404, 410].contains(status) {
            throw DownloadPreparationError.expired
        }
    }

    func response(for request: URLRequest) async throws -> URLResponse {
        try media.validateConversionContext(context)
        let (_, response) = try await media.session.data(for: request)
        try Task.checkCancellation()
        try media.validateConversionContext(context)
        return response
    }
}
