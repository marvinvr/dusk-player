import Foundation

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

struct DownloadScope: Hashable, Sendable {
    let ratingKey: String
    let type: PlexMediaType

    init(ratingKey: String, type: PlexMediaType) {
        self.ratingKey = ratingKey
        self.type = type
    }
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

    let serverID: String
    let serverName: String?
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
    var relativeVideoPath: String?
    var resumeDataPath: String?
    var downloadTaskIdentifier: Int?
    var status: DownloadStatus
    var progress: Double
    var downloadedBytes: Int64
    var totalBytes: Int64?
    var errorMessage: String?
    var addedAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case serverID, serverName, ratingKey, type, isClip
        case title, subtitle
        case parentRatingKey, parentTitle
        case grandparentRatingKey, grandparentTitle
        case thumbPath, artPath
        case mediaID, partID
        case relativeVideoPath, resumeDataPath, downloadTaskIdentifier
        case status, progress, downloadedBytes, totalBytes
        case errorMessage, addedAt, updatedAt
    }

    var globalKey: String {
        Self.globalKey(serverID: serverID, ratingKey: ratingKey)
    }

    var displayTitle: String {
        if type == .episode, let grandparentTitle, !grandparentTitle.isEmpty {
            return "\(grandparentTitle) - \(title)"
        }
        return title
    }

    static func globalKey(serverID: String, ratingKey: String) -> String {
        "\(serverID):\(ratingKey)"
    }
}

extension DownloadedMediaRecord {
    /// Custom decoding (kept in an extension so the memberwise initializer
    /// survives) solely so `isClip` can default to false for snapshots written
    /// before the flag existed. Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
        relativeVideoPath = try container.decodeIfPresent(String.self, forKey: .relativeVideoPath)
        resumeDataPath = try container.decodeIfPresent(String.self, forKey: .resumeDataPath)
        downloadTaskIdentifier = try container.decodeIfPresent(Int.self, forKey: .downloadTaskIdentifier)
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

    var subtitle: String {
        if let totalEpisodeCount, totalEpisodeCount > 0 {
            return "\(downloadedEpisodeCount) of \(totalEpisodeCount) episodes"
        }
        return MediaTextFormatter.episodeCount(downloadedEpisodeCount) ?? "\(downloadedEpisodeCount) episodes"
    }
}

struct DownloadStoreSnapshot: Codable, Sendable {
    var records: [DownloadedMediaRecord] = []
}
