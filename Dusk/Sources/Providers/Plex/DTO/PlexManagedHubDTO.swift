import Foundation

/// One row of `GET /hubs/sections/{id}/manage`. Mapped to `PlexManagedHub` by
/// `PlexHubMapper`.
struct PlexManagedHubDTO: Decodable, Sendable {
    let identifier: String
    let title: String
    let promotedToRecommended: Bool
    let promotedToOwnHome: Bool
    let promotedToSharedHome: Bool

    enum CodingKeys: String, CodingKey {
        case identifier, title, promotedToRecommended, promotedToOwnHome, promotedToSharedHome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? identifier
        func flag(_ key: CodingKeys) -> Bool {
            (try? container.decodeIfPresent(Bool.self, forKey: key))
                ?? (try? container.decodeIfPresent(Int.self, forKey: key)).map { $0 != 0 }
                ?? false
        }
        promotedToRecommended = flag(.promotedToRecommended)
        promotedToOwnHome = flag(.promotedToOwnHome)
        promotedToSharedHome = flag(.promotedToSharedHome)
    }
}
