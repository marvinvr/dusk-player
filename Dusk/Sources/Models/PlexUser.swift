import Foundation

/// The currently authenticated Plex account returned from `GET https://plex.tv/user`.
struct PlexUser: Codable, Sendable, Identifiable {
    let id: Int
    let uuid: String?
    let username: String?
    let title: String?
    let friendlyName: String?
    let thumb: String?

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case username
        case title
        case friendlyName
        case thumb
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int.self, forKey: .id) {
            id = value
        } else if let value = try? container.decode(String.self, forKey: .id),
                  let parsed = Int(value) {
            id = parsed
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Plex user is missing an id"
                )
            )
        }
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        friendlyName = try container.decodeIfPresent(String.self, forKey: .friendlyName)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(uuid, forKey: .uuid)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(friendlyName, forKey: .friendlyName)
        try container.encodeIfPresent(thumb, forKey: .thumb)
    }
}
