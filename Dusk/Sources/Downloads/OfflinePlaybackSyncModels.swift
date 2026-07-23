import Foundation

enum OfflinePlaybackSyncActionKind: String, Codable, Sendable {
    case progress
    case watched
    case unwatched
}

struct OfflinePlaybackSyncAction: Codable, Sendable, Identifiable, Hashable {
    var id: String { globalKey }

    /// Stable Plex Home identity that owns this local watch-state mutation.
    /// Nil identifies an action written before Plex Home support.
    var accountProfileID: String? = nil
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
        DownloadedMediaRecord.globalKey(
            accountProfileID: accountProfileID,
            serverID: serverID,
            ratingKey: ratingKey
        )
    }

    enum CodingKeys: String, CodingKey {
        case accountProfileID, serverID, ratingKey, kind
        case viewOffsetMs, durationMs, shouldMarkWatched, plexState
        case needsSync, attemptCount, lastAttemptAt, createdAt, updatedAt
    }
}

extension OfflinePlaybackSyncAction {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountProfileID = try container.decodeIfPresent(String.self, forKey: .accountProfileID)
        serverID = try container.decode(String.self, forKey: .serverID)
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        kind = try container.decode(OfflinePlaybackSyncActionKind.self, forKey: .kind)
        viewOffsetMs = try container.decodeIfPresent(Int.self, forKey: .viewOffsetMs)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        shouldMarkWatched = try container.decode(Bool.self, forKey: .shouldMarkWatched)
        plexState = try container.decodeIfPresent(String.self, forKey: .plexState)
        needsSync = try container.decode(Bool.self, forKey: .needsSync)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct OfflinePlaybackSyncSnapshot: Codable, Sendable {
    var actions: [OfflinePlaybackSyncAction] = []
}
