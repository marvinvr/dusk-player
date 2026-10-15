import Foundation

extension PlexService {
    // Offline queue jobs match static targets. A streaming target fails with
    // PMS decision 4005 even though the same profile works during playback.
    private static let downloadProfile =
        "add-transcode-target(type=videoProfile&context=static&protocol=http"
        + "&container=mkv&videoCodec=h264&audioCodec=aac&replace=true)"

    /// `clientIdentifier` must be unique to this durable download request. PMS
    /// gets/creates one queue per client + user; the app-wide client identifier
    /// would make lost-add recovery ambiguous across quality/source changes.
    func captureDownloadQueueContext(
        serverID: String,
        profileID: String,
        clientIdentifier: String
    ) throws -> PlexDownloadQueueContext {
        guard !profileID.isEmpty, activeProfileID == profileID else {
            throw PlexDownloadQueueError.wrongProfile
        }
        guard !clientIdentifier.isEmpty, let connection = pool.connection(for: serverID) else {
            throw PlexServiceError.noServerConnected
        }
        var headers = plexRequestHeaders
        headers["X-Plex-Client-Identifier"] = clientIdentifier
        headers["X-Plex-Token"] = connection.token
        headers["X-Plex-Pms-Api-Version"] = "1.0.0"
        headers["X-Plex-Platform"] = "Generic"
        headers["X-Plex-Client-Profile-Name"] = "Generic"
        headers["X-Plex-Client-Profile-Extra"] = Self.downloadProfile
        return PlexDownloadQueueContext(profileID: profileID, connection: connection, headers: headers)
    }

    /// PMS assigns the numeric ID. Creation is idempotent for this context's
    /// persisted client identifier and user. Persist the result before add.
    func createDownloadQueue(context: PlexDownloadQueueContext) async throws -> String {
        let data = try await downloadQueueRequest(context: context, method: "POST", path: "/downloadQueue")
        let queues = try PlexDownloadQueueResponse.elements(data, named: "DownloadQueue")
        guard queues.count == 1 else { throw PlexDownloadQueueResponse.invalidResponse() }
        return try PlexDownloadQueueResponse.id(queues[0]["id"])
    }

    /// Reconcile the dedicated queue before adding: a request may have reached
    /// PMS even when its response was lost or the app was terminated.
    func addDownloadQueueItem(
        context: PlexDownloadQueueContext,
        queueID: String,
        ratingKey: String,
        mediaIndex: Int,
        quality: DownloadQuality
    ) async throws -> String {
        guard mediaIndex >= 0, let bitrate = quality.bitrate, let resolution = quality.resolution else {
            throw PlexDownloadQueueError.invalidResponse("Choose a conversion quality and an available media version.")
        }
        let key = try PlexDownloadQueueResponse.metadataKey(ratingKey)
        let existing = try await downloadQueueItems(context: context, queueID: queueID)
        if !existing.isEmpty {
            guard existing.count == 1, existing[0].key == key else {
                throw PlexDownloadQueueError.invalidResponse("Plex returned an unexpected download queue item.")
            }
            return existing[0].id
        }

        let data = try await downloadQueueRequest(
            context: context,
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

    func downloadQueueItems(context: PlexDownloadQueueContext, queueID: String) async throws -> [PlexDownloadQueueItem] {
        let data = try await downloadQueueRequest(
            context: context,
            path: "/downloadQueue/\(try PlexDownloadQueueResponse.id(queueID))/items",
            canExpire: true
        )
        return try PlexDownloadQueueResponse.elements(data, named: "DownloadQueueItem", allowEmpty: true)
            .map { try PlexDownloadQueueResponse.item($0, queueID: queueID) }
    }

    func downloadQueueItem(
        context: PlexDownloadQueueContext,
        queueID: String,
        itemID: String
    ) async throws -> PlexDownloadQueueItem {
        let data = try await downloadQueueRequest(
            context: context,
            path: "/downloadQueue/\(try PlexDownloadQueueResponse.id(queueID))/items/\(try PlexDownloadQueueResponse.id(itemID))",
            canExpire: true
        )
        let items = try PlexDownloadQueueResponse.elements(data, named: "DownloadQueueItem")
            .map { try PlexDownloadQueueResponse.item($0, queueID: queueID) }
            .filter { $0.id == itemID }
        guard items.count == 1 else { throw PlexDownloadQueueResponse.invalidResponse() }
        return items[0]
    }

    /// Validate the actual decision before assigning an MKV filename. Never
    /// silently fall back to an original or a live HLS transcode response.
    func preparedDownload(
        context: PlexDownloadQueueContext,
        queueID: String,
        itemID: String,
        sourceMedia: PlexMedia
    ) async throws -> PlexPreparedDownload {
        let itemPath = "/downloadQueue/\(try PlexDownloadQueueResponse.id(queueID))/item/\(try PlexDownloadQueueResponse.id(itemID))"
        let data = try await downloadQueueRequest(context: context, path: itemPath + "/decision", canExpire: true)
        let decision = try PlexDownloadQueueResponse.decision(data)

        let request = try makeDownloadQueueRequest(context: context, path: itemPath + "/media")
        // A decision's size may describe the input or an estimate. Only the
        // ready file's Content-Length is safe for full-transfer validation.
        var head = request
        head.httpMethod = "HEAD"
        try validateDownloadQueueContext(context)
        let (_, response) = try await session.data(for: head)
        try Task.checkCancellation()
        try validateDownloadQueueContext(context)
        guard let http = response as? HTTPURLResponse else { throw PlexDownloadQueueResponse.invalidResponse() }
        let expectedBytes: Int64?
        switch http.statusCode {
        case 200...299:
            expectedBytes = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        case 404, 410:
            throw PlexDownloadQueueError.expired
        case 401:
            throw PlexServiceError.unauthorized
        case 405, 501:
            expectedBytes = nil // Some PMS versions do not implement HEAD.
        default:
            throw PlexServiceError.httpError(statusCode: http.statusCode)
        }

        let convertedMedia = decision.convertedMedia(
            sourceMedia: sourceMedia,
            mediaPath: itemPath + "/media",
            expectedBytes: expectedBytes
        )
        return PlexPreparedDownload(request: request, media: convertedMedia, expectedBytes: expectedBytes)
    }

    func removeDownloadQueueItem(
        context: PlexDownloadQueueContext,
        queueID: String,
        itemID: String
    ) async throws {
        do {
            _ = try await downloadQueueRequest(
                context: context, method: "DELETE",
                path: "/downloadQueue/\(try PlexDownloadQueueResponse.id(queueID))/items/\(try PlexDownloadQueueResponse.id(itemID))",
                canExpire: true
            )
        } catch PlexDownloadQueueError.expired {
            // Already removed/expired is successful item-scoped cleanup.
        }
    }

    private func validateDownloadQueueContext(_ context: PlexDownloadQueueContext) throws {
        guard activeProfileID == context.profileID else { throw PlexDownloadQueueError.wrongProfile }
        guard pool.state(for: context.connection.serverID) != .disabled else {
            throw PlexServiceError.noServerConnected
        }
    }

    private func makeDownloadQueueRequest(
        context: PlexDownloadQueueContext,
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        try validateDownloadQueueContext(context)
        guard let url = buildURL(base: context.connection.baseURL.absoluteString, path: path, queryItems: queryItems) else {
            throw PlexServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allHTTPHeaderFields = context.headers
        return request
    }

    private func downloadQueueRequest(
        context: PlexDownloadQueueContext,
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        canExpire: Bool = false
    ) async throws -> Data {
        let request = try makeDownloadQueueRequest(context: context, method: method, path: path, queryItems: queryItems)
        do {
            // This request must not refresh into another Home user's token.
            let data = try await executeRequest(request, retriesFreshAuthentication: false)
            try Task.checkCancellation()
            try validateDownloadQueueContext(context)
            return data
        } catch PlexServiceError.httpError(let status) where canExpire && [404, 410].contains(status) {
            throw PlexDownloadQueueError.expired
        }
    }

}
