import Foundation

/// A playback history entry returned from `GET /status/sessions/history/all`.
struct PlaybackHistoryEntry: Sendable, Identifiable {
    var id: String {
        let base = historyKey ?? "\(itemID)-\(viewedAt ?? 0)"
        guard let serverID else { return base }
        return "\(serverID)|\(base)"
    }

    /// Stamped by the provider mapper; never part of the server payload.
    let serverID: String?

    /// Server-scoped identity of the item this entry refers to.
    var mediaItemID: MediaItemID { MediaItemID(serverID: serverID, itemID: itemID) }

    let historyKey: String?
    let itemID: String
    let libraryID: String?
    let parentID: String?
    let grandparentID: String?
    let type: MediaKind
    let title: String
    let parentTitle: String?
    let grandparentTitle: String?
    let viewedAt: Int?
    let accountID: Int?
}
