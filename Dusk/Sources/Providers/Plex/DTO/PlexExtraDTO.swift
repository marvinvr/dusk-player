import Foundation

/// The extra-specific fields of an `/extras` row. `MediaItem` decodes the rest
/// of the same payload; `PlexUserContentMapper.extras(items:fields:)` pairs
/// the two by rating key.
struct PlexExtraFieldsDTO: Decodable, Sendable {
    let itemID: String
    let extraType: Int?
    let subtype: String?

    enum CodingKeys: String, CodingKey {
        case itemID = "ratingKey", extraType, subtype
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decode(String.self, forKey: .itemID)
        // Plex's XML-to-JSON layer has sent numeric attributes as strings.
        if let value = try? container.decodeIfPresent(Int.self, forKey: .extraType) {
            extraType = value
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .extraType) {
            extraType = Int(value)
        } else {
            extraType = nil
        }
        subtype = try? container.decodeIfPresent(String.self, forKey: .subtype)
    }
}
