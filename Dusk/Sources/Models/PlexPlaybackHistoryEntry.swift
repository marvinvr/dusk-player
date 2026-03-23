import Foundation

/// A playback history entry returned from `GET /status/sessions/history/all`.
struct PlexPlaybackHistoryEntry: Codable, Sendable, Identifiable {
    var id: String { historyKey ?? "\(ratingKey)-\(viewedAt ?? 0)" }

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
}
