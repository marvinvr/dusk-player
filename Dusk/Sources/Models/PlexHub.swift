import Foundation

/// A "hub" on the Plex home screen (e.g. "Continue Watching", "Recently Added Movies").
/// Returned from `GET /hubs` and `GET /hubs/search`.
struct PlexHub: Codable, Sendable, Identifiable {
    var id: String { hubIdentifier ?? title }

    let key: String?
    let title: String
    let type: String?
    let hubIdentifier: String?
    let size: Int?
    let more: Bool?
    let items: [PlexItem]

    enum CodingKeys: String, CodingKey {
        case key, title, type, hubIdentifier, size, more
        case items = "Metadata"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        hubIdentifier = try container.decodeIfPresent(String.self, forKey: .hubIdentifier)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        more = try container.decodeIfPresent(Bool.self, forKey: .more)
        items = try container.decodeIfPresent([PlexItem].self, forKey: .items) ?? []
    }
}
