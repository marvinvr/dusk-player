import Foundation

/// A playback history entry returned from `GET /status/sessions/history/all`.
struct PlaybackHistoryEntry: Codable, Sendable, Identifiable {
    var id: String {
        let base = historyKey ?? "\(itemID)-\(viewedAt ?? 0)"
        guard let serverID else { return base }
        return "\(serverID)|\(base)"
    }

    /// Stamped by `ServerPool.decoder(for:)`; never part of the Plex payload,
    /// so it is excluded from `CodingKeys` and dropped when re-encoded.
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

    enum CodingKeys: String, CodingKey {
        case historyKey
        case itemID = "ratingKey"
        case libraryID = "librarySectionID"
        case parentID = "parentKey"
        case grandparentID = "grandparentKey"
        case type
        case title
        case parentTitle
        case grandparentTitle
        case viewedAt
        case accountID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = decoder.duskServerID
        historyKey = try container.decodeIfPresent(String.self, forKey: .historyKey)
        itemID = try container.decode(String.self, forKey: .itemID)
        libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        grandparentID = try container.decodeIfPresent(String.self, forKey: .grandparentID)
        type = try container.decode(MediaKind.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        viewedAt = try container.decodeIfPresent(Int.self, forKey: .viewedAt)
        accountID = try container.decodeIfPresent(Int.self, forKey: .accountID)
    }
}
