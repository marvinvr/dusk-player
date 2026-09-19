import Foundation

/// A playback history entry returned from `GET /status/sessions/history/all`.
struct PlexPlaybackHistoryEntry: Codable, Sendable, Identifiable {
    var id: String {
        let base = historyKey ?? "\(ratingKey)-\(viewedAt ?? 0)"
        guard let serverID else { return base }
        return "\(serverID)|\(base)"
    }

    /// Stamped by `ServerPool.decoder(for:)`; never part of the Plex payload,
    /// so it is excluded from `CodingKeys` and dropped when re-encoded.
    let serverID: String?

    /// Server-scoped identity of the item this entry refers to.
    var itemID: PlexItemID { PlexItemID(serverID: serverID, ratingKey: ratingKey) }

    let historyKey: String?
    let ratingKey: String
    let librarySectionID: String?
    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let type: PlexMediaType
    let title: String
    let parentTitle: String?
    let grandparentTitle: String?
    let viewedAt: Int?
    let accountID: Int?

    enum CodingKeys: String, CodingKey {
        case historyKey
        case ratingKey
        case librarySectionID
        case parentRatingKey = "parentKey"
        case grandparentRatingKey = "grandparentKey"
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
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        librarySectionID = try container.decodeIfPresent(String.self, forKey: .librarySectionID)
        parentRatingKey = try container.decodeIfPresent(String.self, forKey: .parentRatingKey)
        grandparentRatingKey = try container.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        type = try container.decode(PlexMediaType.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        viewedAt = try container.decodeIfPresent(Int.self, forKey: .viewedAt)
        accountID = try container.decodeIfPresent(Int.self, forKey: .accountID)
    }
}
