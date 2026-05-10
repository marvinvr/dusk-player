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
        case .paused, .failed, .cancelled:
            return true
        case .queued, .preparing, .downloading, .completed:
            return false
        }
    }

    var canCancel: Bool {
        switch self {
        case .queued, .preparing, .downloading, .paused:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    var canDelete: Bool {
        switch self {
        case .completed, .failed, .cancelled, .paused:
            return true
        case .queued, .preparing, .downloading:
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
