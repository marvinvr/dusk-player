import Foundation

/// Jellyfin's downloads. Placeholder until J-08a: nothing can be downloaded.
@MainActor
struct JellyfinDownloads: DownloadProviding {
    let server: JellyfinServerProvider

    nonisolated init(server: JellyfinServerProvider) {
        self.server = server
    }

    nonisolated func qualities(for item: MediaItemID) -> [DownloadQuality] { [] }

    func originalFileRequest(url: URL, credential: String) -> URLRequest { URLRequest(url: url) }

    func fetchSidecar(_ request: URLRequest) async throws -> (Data, URLResponse) {
        throw MediaServiceError.notImplemented
    }

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
