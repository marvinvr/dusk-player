import Foundation

/// Original and converted downloads, sidecars and the offline metadata snapshot
/// (docs/jellyfin/04-architecture.md §15).
///
/// The facet holds what only the provider knows: which qualities it offers,
/// how a converted copy is asked for and read back, how the original file and a
/// sidecar are requested. Routing, the owning-profile checks and every
/// persisted step stay in `MediaService+Downloads` and `DownloadManager`: a
/// converted download is a resumable job (create, add, poll, fetch, remove)
/// whose ids the manager persists between steps, so a lost response or a
/// relaunch continues the same job instead of starting another one.
///
/// The metadata snapshot (raw provider payloads on disk) is read offline, with
/// no session, so its format is reached by `ProviderKind` through
/// `MetadataSnapshotFormatProviding`, not through this facet.
protocol DownloadProviding: Sendable {
    /// The presets the download quality menu offers for this item.
    func qualities(for item: MediaItemID) -> [DownloadQuality]

    /// The original file's transfer request, for a URL the facade built.
    @MainActor func originalFileRequest(url: URL, credential: String) -> URLRequest

    /// Fetches one sidecar (an external text subtitle) saved next to a download.
    @MainActor func fetchSidecar(_ request: URLRequest) async throws -> (Data, URLResponse)

    // MARK: Converted downloads

    /// The headers every request of one converted download carries, keyed to
    /// that download's own client identifier.
    @MainActor func conversionHeaders(clientIdentifier: String, credential: String) -> [String: String]
    /// Creates (or, for the same client identifier, finds) the server queue.
    @MainActor func createConversionQueue(via transport: any DownloadConversionTransport) async throws -> String
    /// Adds the item to the queue, or returns the job a lost earlier add left there.
    @MainActor func addConversionJob(
        queueID: String,
        itemID: String,
        mediaIndex: Int,
        quality: DownloadQuality,
        via transport: any DownloadConversionTransport
    ) async throws -> String
    @MainActor func conversionJobs(queueID: String, via transport: any DownloadConversionTransport) async throws -> [ConversionJob]
    @MainActor func conversionJob(
        queueID: String,
        jobID: String,
        via transport: any DownloadConversionTransport
    ) async throws -> ConversionJob
    /// The ready file's transfer request and the media it describes. Never
    /// falls back to the original or to a live stream.
    @MainActor func preparedConversion(
        queueID: String,
        jobID: String,
        sourceMedia: MediaVersion,
        via transport: any DownloadConversionTransport
    ) async throws -> ConvertedDownload
    /// Removes a job; one that already expired counts as removed.
    @MainActor func removeConversionJob(
        queueID: String,
        jobID: String,
        via transport: any DownloadConversionTransport
    ) async throws
}

// MARK: - Converted downloads

/// Credentials captured for one converted-download operation, never stored in
/// downloads.json. The caller persists a unique client identifier before the
/// queue is created, so a lost create/add response can be recovered without
/// converting twice.
struct DownloadConversionContext: Sendable {
    let profileID: String
    let connection: ServerSession
    let headers: [String: String]
}

/// How a provider's conversion steps reach the server. Implemented by the
/// facade: it builds the request on the context's connection and checks the
/// owning profile and the server's state before and after every await.
@MainActor
protocol DownloadConversionTransport {
    /// A request on the context's connection, with its headers. Checks the
    /// context first.
    func request(method: String, path: String, queryItems: [URLQueryItem]) throws -> URLRequest
    /// Sends one request without refreshing into another profile's token.
    /// `canExpire` maps a 404/410 to `DownloadPreparationError.expired`.
    func send(method: String, path: String, queryItems: [URLQueryItem], canExpire: Bool) async throws -> Data
    /// Sends a request built by `request(…)` (a HEAD) and returns the raw response.
    func response(for request: URLRequest) async throws -> URLResponse
}

/// One converted download on the server, as the provider last reported it.
struct ConversionJob: Sendable, Hashable {
    let id: String
    let queueID: String
    /// The item the job converts; nil when the provider's answer names none.
    let itemID: String?
    let state: ConversionJobState
    /// Preparation progress (0…1), not transferred bytes. nil is indeterminate.
    let progress: Double?
    /// The server's reason for a failed job, when it gave one.
    let failureReason: String?
}

enum ConversionJobState: Sendable, Hashable {
    /// Queued, deciding or converting.
    case preparing
    case ready
    case failed
    case expired
}

/// A converted file ready to transfer. `media` only describes the converted
/// output; the original's stream ids and HDR flags must not leak into offline
/// playback.
struct ConvertedDownload: Sendable {
    let request: URLRequest
    let media: MediaVersion
    let expectedBytes: Int64?
}

enum DownloadPreparationError: LocalizedError {
    case wrongProfile
    case expired
    case invalidResponse(String)
    case preparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .wrongProfile:
            return "Switch back to the Plex profile that queued this download to continue."
        case .expired:
            return "The prepared download expired on the Plex server. Please retry."
        case .invalidResponse(let reason), .preparationFailed(let reason):
            return reason
        }
    }
}

/// A sidecar a download saves next to its video, with the provider's way of
/// fetching it.
struct SidecarDownload {
    var request: URLRequest
    let fetch: @MainActor (URLRequest) async throws -> (Data, URLResponse)
}

// MARK: - Metadata snapshot

/// One cached metadata payload of a downloaded item.
enum MetadataSnapshotKey: Hashable, Sendable {
    /// The item's own metadata.
    case details(itemID: String)
    /// Its children: a show's seasons, a season's episodes.
    case children(itemID: String)
}

/// A server read: path and query on the session's connection.
struct MetadataSnapshotRequest: Sendable, Hashable {
    let path: String
    let queryItems: [URLQueryItem]?
}

/// How one provider names, fetches and decodes its snapshot payloads. Needs no
/// session: offline browsing decodes with the kind the payload was written by.
protocol MetadataSnapshotFormat: Sendable {
    var kind: ProviderKind { get }
    /// The cache file's hash input. **Wire format**: the file name is
    /// SHA-256 of this string, so it may never change for a provider that has
    /// shipped (Plex: the PMS endpoint path).
    func storageName(for key: MetadataSnapshotKey) -> String
    func fetchRequest(for key: MetadataSnapshotKey) -> MetadataSnapshotRequest
    /// Every model is stamped with `serverID`, as if it had been fetched online.
    func details(from data: Data, serverID: String) throws -> [MediaDetails]
    func seasons(from data: Data, serverID: String) throws -> [Season]
    func episodes(from data: Data, serverID: String) throws -> [Episode]
}

/// A `ProviderFactory` whose provider writes metadata snapshots.
protocol MetadataSnapshotFormatProviding {
    var metadataSnapshotFormat: any MetadataSnapshotFormat { get }
}

/// The snapshot formats of this build, by provider kind.
struct MetadataSnapshotFormats: Sendable {
    private let formats: [ProviderKind: any MetadataSnapshotFormat]

    init(_ formats: [any MetadataSnapshotFormat]) {
        self.formats = Dictionary(formats.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func format(for kind: ProviderKind) -> (any MetadataSnapshotFormat)? {
        formats[kind]
    }
}
