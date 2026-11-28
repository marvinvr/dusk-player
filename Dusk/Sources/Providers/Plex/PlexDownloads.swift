import Foundation

/// Plex's `DownloadProviding`: original files with the server token, the
/// Download Queue API (PMS 1.41.9+) for converted copies, and sidecars through
/// `PlexTransportSecurity`. Sending goes through the facade's
/// `DownloadConversionTransport`, which owns the profile and server checks.
struct PlexDownloads: DownloadProviding {
    let client: PlexClient

    // Offline queue jobs match static targets. A streaming target fails with
    // PMS decision 4005 even though the same profile works during playback.
    static let downloadProfile =
        "add-transcode-target(type=videoProfile&context=static&protocol=http"
        + "&container=mkv&videoCodec=h264&audioCodec=aac&replace=true)"

    func qualities(for item: MediaItemID) -> [DownloadQuality] {
        DownloadQuality.allCases
    }

    @MainActor
    func originalFileRequest(url: URL, credential: String) -> URLRequest {
        var request = URLRequest(url: url)
        client.applyHeaders(to: &request, token: credential)
        return request
    }

    @MainActor
    func fetchSidecar(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try PlexTransportSecurity.validate(request)
        return try await PlexTransportSecurity.session.data(for: request)
    }

    // MARK: - Download Queue

    /// `clientIdentifier` must be unique to this durable download request. PMS
    /// gets/creates one queue per client + user; the app-wide client identifier
    /// would make lost-add recovery ambiguous across quality/source changes.
    @MainActor
    func conversionHeaders(clientIdentifier: String, credential: String) -> [String: String] {
        var headers = client.plexRequestHeaders
        headers["X-Plex-Client-Identifier"] = clientIdentifier
        headers["X-Plex-Token"] = credential
        headers["X-Plex-Pms-Api-Version"] = "1.0.0"
        headers["X-Plex-Platform"] = "Generic"
        headers["X-Plex-Client-Profile-Name"] = "Generic"
        headers["X-Plex-Client-Profile-Extra"] = Self.downloadProfile
        return headers
    }

    /// PMS assigns the numeric ID. Creation is idempotent for this context's
    /// persisted client identifier and user. Persist the result before add.
    @MainActor
    func createConversionQueue(via transport: any DownloadConversionTransport) async throws -> String {
        let data: Data
        do {
            data = try await transport.send(method: "POST", path: "/downloadQueue", queryItems: [], canExpire: false)
        } catch MediaServiceError.httpError(let status) where status == 404 {
            // Servers before PMS 1.41.9 have no download queue.
            throw PlexDownloadQueueError.preparationFailed(
                "This Plex server can't convert downloads. Update Plex Media Server or download in Original quality."
            )
        }
        let queues = try PlexDownloadQueueResponse.elements(data, named: "DownloadQueue")
        guard queues.count == 1 else { throw PlexDownloadQueueResponse.invalidResponse() }
        return try PlexDownloadQueueResponse.id(queues[0]["id"])
    }

    /// Reconcile the dedicated queue before adding: a request may have reached
    /// PMS even when its response was lost or the app was terminated.
    @MainActor
    func addConversionJob(
        queueID: String,
        itemID: String,
        mediaIndex: Int,
        quality: DownloadQuality,
        via transport: any DownloadConversionTransport
    ) async throws -> String {
        guard mediaIndex >= 0, let bitrate = quality.bitrate, let resolution = quality.resolution else {
            throw PlexDownloadQueueError.invalidResponse("Choose a conversion quality and an available media version.")
        }
        let key = try PlexDownloadQueueResponse.metadataKey(itemID)
        let existing = try await queueItems(queueID: queueID, via: transport)
        if !existing.isEmpty {
            guard existing.count == 1, existing[0].key == key else {
                throw PlexDownloadQueueError.invalidResponse("Plex returned an unexpected download queue item.")
            }
            return existing[0].id
        }

        let data = try await transport.send(
            method: "POST",
            path: "/downloadQueue/\(try PlexDownloadQueueResponse.id(queueID))/add",
            queryItems: [
                URLQueryItem(name: "keys", value: key),
                URLQueryItem(name: "mediaIndex", value: String(mediaIndex)),
                // Join all parts into one complete offline file.
                URLQueryItem(name: "partIndex", value: "-1"),
                URLQueryItem(name: "videoBitrate", value: String(bitrate)),
                URLQueryItem(name: "videoResolution", value: resolution),
                URLQueryItem(name: "directPlay", value: "0"),
                URLQueryItem(name: "directStream", value: "0"),
                URLQueryItem(name: "directStreamAudio", value: "0"),
                URLQueryItem(name: "protocol", value: "http"),
                URLQueryItem(name: "subtitles", value: "none"),
                URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: Self.downloadProfile),
            ],
            canExpire: true
        )
        let added = try PlexDownloadQueueResponse.elements(data, named: "AddedQueueItems").filter { $0["key"] as? String == key }
        guard added.count == 1 else { throw PlexDownloadQueueResponse.invalidResponse() }
        return try PlexDownloadQueueResponse.id(added[0]["id"])
    }

    @MainActor
    func conversionJobs(queueID: String, via transport: any DownloadConversionTransport) async throws -> [ConversionJob] {
        try await queueItems(queueID: queueID, via: transport).map(\.job)
    }

    @MainActor
    func conversionJob(
        queueID: String,
        jobID: String,
        via transport: any DownloadConversionTransport
    ) async throws -> ConversionJob {
        let data = try await transport.send(
            method: "GET",
            path: "/downloadQueue/\(try PlexDownloadQueueResponse.id(queueID))/items/\(try PlexDownloadQueueResponse.id(jobID))",
            queryItems: [],
            canExpire: true
        )
        let items = try PlexDownloadQueueResponse.elements(data, named: "DownloadQueueItem")
            .map { try PlexDownloadQueueResponse.item($0, queueID: queueID) }
            .filter { $0.id == jobID }
        guard items.count == 1 else { throw PlexDownloadQueueResponse.invalidResponse() }
        return items[0].job
    }

    /// Validate the actual decision before assigning an MKV filename. Never
    /// silently fall back to an original or a live HLS transcode response.
    @MainActor
    func preparedConversion(
        queueID: String,
        jobID: String,
        sourceMedia: MediaVersion,
        via transport: any DownloadConversionTransport
    ) async throws -> ConvertedDownload {
        let itemPath = "/downloadQueue/\(try PlexDownloadQueueResponse.id(queueID))/item/\(try PlexDownloadQueueResponse.id(jobID))"
        let data = try await transport.send(method: "GET", path: itemPath + "/decision", queryItems: [], canExpire: true)
        let decision = try PlexDownloadQueueResponse.decision(data)

        let request = try transport.request(method: "GET", path: itemPath + "/media", queryItems: [])
        // A decision's size may describe the input or an estimate. Only the
        // ready file's Content-Length is safe for full-transfer validation.
        var head = request
        head.httpMethod = "HEAD"
        let response = try await transport.response(for: head)
        guard let http = response as? HTTPURLResponse else { throw PlexDownloadQueueResponse.invalidResponse() }
        let expectedBytes: Int64?
        switch http.statusCode {
        case 200...299:
            expectedBytes = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        case 404, 410:
            throw PlexDownloadQueueError.expired
        case 401:
            throw MediaServiceError.unauthorized
        case 405, 501:
            expectedBytes = nil // Some PMS versions do not implement HEAD.
        default:
            throw MediaServiceError.httpError(statusCode: http.statusCode)
        }

        let convertedMedia = decision.convertedMedia(
            sourceMedia: sourceMedia,
            mediaPath: itemPath + "/media",
            expectedBytes: expectedBytes
        )
        return ConvertedDownload(request: request, media: convertedMedia, expectedBytes: expectedBytes)
    }

    @MainActor
    func removeConversionJob(
        queueID: String,
        jobID: String,
        via transport: any DownloadConversionTransport
    ) async throws {
        do {
            _ = try await transport.send(
                method: "DELETE",
                path: "/downloadQueue/\(try PlexDownloadQueueResponse.id(queueID))/items/\(try PlexDownloadQueueResponse.id(jobID))",
                queryItems: [],
                canExpire: true
            )
        } catch PlexDownloadQueueError.expired {
            // Already removed/expired is successful item-scoped cleanup.
        }
    }

    @MainActor
    private func queueItems(queueID: String, via transport: any DownloadConversionTransport) async throws -> [PlexDownloadQueueItem] {
        let data = try await transport.send(
            method: "GET",
            path: "/downloadQueue/\(try PlexDownloadQueueResponse.id(queueID))/items",
            queryItems: [],
            canExpire: true
        )
        return try PlexDownloadQueueResponse.elements(data, named: "DownloadQueueItem", allowEmpty: true)
            .map { try PlexDownloadQueueResponse.item($0, queueID: queueID) }
    }
}

extension PlexServerProvider {
    var downloads: any DownloadProviding { PlexDownloads(client: client) }
}
