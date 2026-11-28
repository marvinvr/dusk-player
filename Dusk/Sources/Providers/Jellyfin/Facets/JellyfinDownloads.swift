import Foundation

/// Jellyfin's downloads (docs/jellyfin/04-architecture.md §15, 02 §14):
///
/// - Original only until J-08b adds the converted presets.
/// - The original is `GET /Items/{sourceID}/Download` with the token in the
///   `Authorization` header. The source id picks the version (an alternate
///   version is its own item); the server checks the user's
///   `EnableContentDownloading`, which also hides the action
///   (`ServerPermissions.canDownload`). Multi-part films download their first
///   part only, as they play.
/// - Sidecars are the external text tracks' `…/Subtitles/{index}/0/Stream.*`
///   (`JellyfinPlayback.sidecarSubtitleURL`); embedded tracks are in the file.
/// - The metadata snapshot is `JellyfinMetadataSnapshotFormat`.
@MainActor
struct JellyfinDownloads: DownloadProviding {
    let server: JellyfinServerProvider

    nonisolated init(server: JellyfinServerProvider) {
        self.server = server
    }

    nonisolated func qualities(for item: MediaItemID) -> [DownloadQuality] { [.original] }

    func originalFileRequest(for part: MediaPart, directPlayURL: URL, credential: String) -> URLRequest? {
        guard let client = try? server.client() else { return nil }
        return Self.originalFileRequest(sourceID: part.id, client: client)
    }

    nonisolated static func originalFileRequest(sourceID: String, client: JellyfinClient) -> URLRequest? {
        guard let token = client.credentials?.accessToken,
              let url = try? client.makeURL(path: "/Items/\(JellyfinID.normalized(sourceID))/Download"),
              JellyfinCredentialPolicy.shared.allowsCredential(in: url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            JellyfinAuthorization.headerValue(identity: client.identity, token: token),
            forHTTPHeaderField: JellyfinAuthorization.headerName
        )
        return request
    }

    func fetchSidecar(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let policy = JellyfinCredentialPolicy.shared
        try policy.validate(request)
        return try await policy.session.data(for: request)
    }

    func metadataSnapshot(_ key: MetadataSnapshotKey) async throws -> Data {
        try await JellyfinMetadataSnapshotFormat.fetch(key, client: server.client())
    }

    // MARK: Converted downloads (J-08b)

    func conversionHeaders(clientIdentifier: String, credential: String) -> [String: String] { [:] }

    func createConversionQueue(via transport: any DownloadConversionTransport) async throws -> String {
        throw MediaServiceError.notImplemented
    }

    func addConversionJob(
        queueID: String,
        itemID: String,
        mediaIndex: Int,
        quality: DownloadQuality,
        via transport: any DownloadConversionTransport
    ) async throws -> String {
        throw MediaServiceError.notImplemented
    }

    func conversionJobs(queueID: String, via transport: any DownloadConversionTransport) async throws -> [ConversionJob] {
        throw MediaServiceError.notImplemented
    }

    func conversionJob(
        queueID: String,
        jobID: String,
        via transport: any DownloadConversionTransport
    ) async throws -> ConversionJob {
        throw MediaServiceError.notImplemented
    }

    func preparedConversion(
        queueID: String,
        jobID: String,
        sourceMedia: MediaVersion,
        via transport: any DownloadConversionTransport
    ) async throws -> ConvertedDownload {
        throw MediaServiceError.notImplemented
    }

    func removeConversionJob(
        queueID: String,
        jobID: String,
        via transport: any DownloadConversionTransport
    ) async throws {
        throw MediaServiceError.notImplemented
    }
}
