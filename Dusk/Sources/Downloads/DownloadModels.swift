import Foundation

/// An explicit offline conversion choice, independent of playback quality.
enum DownloadQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, p1080High, p1080, p720, p720Low, p480, p320

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: "Original"
        case .p1080High: "1080p · 12 Mbps"
        case .p1080: "1080p · 8 Mbps"
        case .p720: "720p · 4 Mbps"
        case .p720Low: "720p · 2 Mbps"
        case .p480: "480p · 1 Mbps"
        case .p320: "320p · 0.7 Mbps"
        }
    }

    var bitrate: Int? {
        switch self {
        case .original: nil
        case .p1080High: 12000
        case .p1080: 8000
        case .p720: 4000
        case .p720Low: 2000
        case .p480: 1000
        case .p320: 700
        }
    }

    var resolution: String? {
        switch self {
        case .original: nil
        case .p1080High, .p1080: "1920x1080"
        case .p720, .p720Low: "1280x720"
        case .p480: "720x480"
        case .p320: "576x320"
        }
    }
}

enum DownloadStatus: String, Codable, Sendable {
    case queued
    case preparing
    case downloading
    case paused
    case completed
    case failed
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .preparing, .downloading:
            return true
        case .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    var canPause: Bool {
        switch self {
        case .queued, .preparing, .downloading:
            return true
        case .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    var canResume: Bool {
        switch self {
        case .paused, .failed:
            return true
        case .queued, .preparing, .downloading, .completed, .cancelled:
            return false
        }
    }

    var canCancel: Bool {
        switch self {
        case .queued, .preparing, .downloading, .paused, .failed, .cancelled:
            return true
        case .completed:
            return false
        }
    }

    var canDelete: Bool {
        switch self {
        case .completed:
            return true
        case .queued, .preparing, .downloading, .paused, .failed, .cancelled:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .queued:
            return "Queued"
        case .preparing:
            return "Preparing"
        case .downloading:
            return "Downloading"
        case .paused:
            return "Paused"
        case .completed:
            return "Downloaded"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

/// What a download control acts on: one item (or one season/show branch) on one
/// server. The server travels with the rating key because the same key means a
/// different title on every other server the account has connected.
struct DownloadScope: Hashable, Sendable {
    let id: PlexItemID
    let type: PlexMediaType

    init(id: PlexItemID, type: PlexMediaType) {
        self.id = id
        self.type = type
    }

    var ratingKey: String { id.ratingKey }
    var serverID: String? { id.serverID }
}

struct DownloadControlState: Hashable, Sendable {
    let scope: DownloadScope
    let status: DownloadStatus?
    let progress: Double
    let isDeleting: Bool
    let records: [DownloadedMediaRecord]

    var hasRecords: Bool {
        !records.isEmpty
    }

    var canPause: Bool {
        status?.canPause == true
    }

    var canResume: Bool {
        status?.canResume == true
    }

    var canCancel: Bool {
        status?.canCancel == true
    }

    var canDelete: Bool {
        status?.canDelete == true
    }
}

struct DownloadedMediaRecord: Codable, Sendable, Identifiable, Hashable {
    var id: String { globalKey }

    /// Stable Plex Home identity that owns this download. A nil value is a
    /// pre-Plex-Home record awaiting one-time adoption by the original account.
    var accountProfileID: String? = nil
    /// Machine identifier of the server the file came from. Mutable only so a
    /// legacy record keyed on the server's base URL can be re-keyed once the
    /// matching server is known (see `DownloadManager`).
    var serverID: String
    var serverName: String?
    let ratingKey: String
    let type: PlexMediaType
    /// Whether the item is a video clip (Plex reports clips as `type == "movie"`
    /// with `subtype == "clip"`). Drives 16:9 artwork and the `.downloadedVideo`
    /// route. Defaults to false so records persisted before the flag existed
    /// still decode.
    var isClip: Bool = false
    var title: String
    var subtitle: String?
    var parentRatingKey: String?
    var parentTitle: String?
    var grandparentRatingKey: String?
    var grandparentTitle: String?
    var thumbPath: String?
    var artPath: String?
    var mediaID: Int?
    var partID: Int?
    var downloadQuality: DownloadQuality = .original
    /// Persisted before any server mutation; each request owns its own Plex queue.
    var queueClientIdentifier: String? = nil
    var plexDownloadQueueID: String? = nil
    var plexDownloadItemID: String? = nil
    var preparationProgress: Double? = nil
    var preparationRetryCount: Int = 0
    /// Encoded separately to retain the record's Hashable conformance. Source
    /// media/part IDs above remain stable even when the prepared file expires.
    var convertedMediaData: Data? = nil

    var convertedMedia: PlexMedia? {
        convertedMediaData.flatMap { try? JSONDecoder().decode(PlexMedia.self, from: $0) }
    }
    var relativeVideoPath: String?
    var resumeDataPath: String?
    var downloadTaskIdentifier: Int?
    /// Distinguishes an automatic Home-user suspension from a user-requested
    /// pause so the queue can resume when its owning profile becomes active.
    var wasPausedForProfileSwitch: Bool = false
    var status: DownloadStatus
    var progress: Double
    var downloadedBytes: Int64
    var totalBytes: Int64?
    var errorMessage: String?
    var addedAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case accountProfileID, serverID, serverName, ratingKey, type, isClip
        case title, subtitle
        case parentRatingKey, parentTitle
        case grandparentRatingKey, grandparentTitle
        case thumbPath, artPath
        case mediaID, partID
        case downloadQuality, queueClientIdentifier, plexDownloadQueueID, plexDownloadItemID
        case preparationProgress, preparationRetryCount, convertedMediaData
        case relativeVideoPath, resumeDataPath, downloadTaskIdentifier, wasPausedForProfileSwitch
        case status, progress, downloadedBytes, totalBytes
        case errorMessage, addedAt, updatedAt
    }

    var globalKey: String {
        Self.globalKey(
            accountProfileID: accountProfileID,
            serverID: serverID,
            ratingKey: ratingKey
        )
    }

    /// Server-scoped identity of the downloaded item, for playback and lookups.
    var itemID: PlexItemID {
        PlexItemID(serverID: serverID, ratingKey: ratingKey)
    }

    var displayTitle: String {
        if type == .episode, let grandparentTitle, !grandparentTitle.isEmpty {
            return "\(grandparentTitle) - \(title)"
        }
        return title
    }

    static func globalKey(serverID: String, ratingKey: String) -> String {
        globalKey(accountProfileID: nil, serverID: serverID, ratingKey: ratingKey)
    }

    static func globalKey(accountProfileID: String?, serverID: String, ratingKey: String) -> String {
        if let accountProfileID = accountProfileID?.nilIfEmpty {
            return "\(accountProfileID):\(serverID):\(ratingKey)"
        }
        return "\(serverID):\(ratingKey)"
    }

    var legacyGlobalKey: String {
        Self.globalKey(serverID: serverID, ratingKey: ratingKey)
    }
}

extension DownloadedMediaRecord {
    /// Custom decoding (kept in an extension so the memberwise initializer
    /// survives) solely so `isClip` can default to false for snapshots written
    /// before the flag existed. Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountProfileID = try container.decodeIfPresent(String.self, forKey: .accountProfileID)
        serverID = try container.decode(String.self, forKey: .serverID)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        type = try container.decode(PlexMediaType.self, forKey: .type)
        isClip = try container.decodeIfPresent(Bool.self, forKey: .isClip) ?? false
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        parentRatingKey = try container.decodeIfPresent(String.self, forKey: .parentRatingKey)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        grandparentRatingKey = try container.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        thumbPath = try container.decodeIfPresent(String.self, forKey: .thumbPath)
        artPath = try container.decodeIfPresent(String.self, forKey: .artPath)
        mediaID = try container.decodeIfPresent(Int.self, forKey: .mediaID)
        partID = try container.decodeIfPresent(Int.self, forKey: .partID)
        downloadQuality = try container.decodeIfPresent(DownloadQuality.self, forKey: .downloadQuality) ?? .original
        queueClientIdentifier = try container.decodeIfPresent(String.self, forKey: .queueClientIdentifier)
        plexDownloadQueueID = try container.decodeIfPresent(String.self, forKey: .plexDownloadQueueID)
        plexDownloadItemID = try container.decodeIfPresent(String.self, forKey: .plexDownloadItemID)
        preparationProgress = try container.decodeIfPresent(Double.self, forKey: .preparationProgress)
        preparationRetryCount = try container.decodeIfPresent(Int.self, forKey: .preparationRetryCount) ?? 0
        convertedMediaData = try container.decodeIfPresent(Data.self, forKey: .convertedMediaData)
        relativeVideoPath = try container.decodeIfPresent(String.self, forKey: .relativeVideoPath)
        resumeDataPath = try container.decodeIfPresent(String.self, forKey: .resumeDataPath)
        downloadTaskIdentifier = try container.decodeIfPresent(Int.self, forKey: .downloadTaskIdentifier)
        wasPausedForProfileSwitch = try container.decodeIfPresent(
            Bool.self,
            forKey: .wasPausedForProfileSwitch
        ) ?? false
        status = try container.decode(DownloadStatus.self, forKey: .status)
        progress = try container.decode(Double.self, forKey: .progress)
        downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct DownloadedShowSummary: Identifiable, Hashable {
    let serverID: String
    let ratingKey: String
    let title: String
    let thumbPath: String?
    let artPath: String?
    let downloadedEpisodeCount: Int
    let totalEpisodeCount: Int?

    var id: String {
        DownloadedMediaRecord.globalKey(serverID: serverID, ratingKey: ratingKey)
    }

    var itemID: PlexItemID {
        PlexItemID(serverID: serverID, ratingKey: ratingKey)
    }

    var subtitle: String {
        if let totalEpisodeCount, totalEpisodeCount > 0 {
            return "\(downloadedEpisodeCount) of \(totalEpisodeCount) episodes"
        }
        return MediaTextFormatter.episodeCount(downloadedEpisodeCount) ?? "\(downloadedEpisodeCount) episodes"
    }
}

struct DownloadStoreSnapshot: Codable, Sendable {
    var records: [DownloadedMediaRecord] = []
    var pendingQueueRemovals: [DownloadQueueRemoval]? = nil
}

/// Cleanup survives an offline cancellation or a Plex Home profile switch.
struct DownloadQueueRemoval: Codable, Sendable, Hashable {
    let profileID: String
    let serverID: String
    let clientIdentifier: String
    let ratingKey: String
    let queueID: String?
    let itemID: String?
}
