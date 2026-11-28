import Foundation

/// One `Marker` entry of a Plex item (intro, credits, …). Also the shape the
/// offline metadata cache holds; see `PlexMediaVersionDTO`.
struct PlexMarkerDTO: Decodable, Sendable {
    let id: String
    let type: String
    let startTimeOffset: Int
    let endTimeOffset: Int

    enum CodingKeys: String, CodingKey {
        case id, type, startTimeOffset, endTimeOffset
    }

    /// The id may be a number (Plex) or a string.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeID(forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        startTimeOffset = try container.decode(Int.self, forKey: .startTimeOffset)
        endTimeOffset = try container.decode(Int.self, forKey: .endTimeOffset)
    }
}
