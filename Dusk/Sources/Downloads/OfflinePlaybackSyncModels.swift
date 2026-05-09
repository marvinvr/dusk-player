import Foundation

enum OfflinePlaybackSyncActionKind: String, Codable, Sendable {
    case progress
    case watched
    case unwatched
}

struct OfflinePlaybackSyncAction: Codable, Sendable, Identifiable, Hashable {
    var id: String { globalKey }

    let serverID: String
    let ratingKey: String
    var kind: OfflinePlaybackSyncActionKind
    var viewOffsetMs: Int?
    var durationMs: Int?
    var shouldMarkWatched: Bool
    var plexState: String?
    var needsSync: Bool
    var attemptCount: Int
    var lastAttemptAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var globalKey: String {
        DownloadedMediaRecord.globalKey(serverID: serverID, ratingKey: ratingKey)
    }
}

struct OfflinePlaybackSyncSnapshot: Codable, Sendable {
    var actions: [OfflinePlaybackSyncAction] = []
}
