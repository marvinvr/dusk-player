import Foundation

/// A `GET /library/sections` `Directory` row. `PlexItemMapper` builds `Library`.
/// Encodes back to the same keys it decodes (`hidden` as an integer).
struct PlexLibraryDTO: Codable, Sendable {
    let key: String
    let title: String
    let type: String
    let subtype: String?
    let agent: String?
    let scanner: String?
    let language: String?
    let uuid: String?
    let updatedAt: Int?
    let createdAt: Int?
    let scannedAt: Int?
    let thumb: String?
    let art: String?
    let composite: String?
    /// The section's server-side Visibility, read leniently.
    let hidden: LibraryVisibility

    enum CodingKeys: String, CodingKey {
        case key, title, type, subtype, agent, scanner, language, uuid
        case updatedAt, createdAt, scannedAt
        case thumb, art, composite
        case hidden
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        type = try container.decode(String.self, forKey: .type)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        scanner = try container.decodeIfPresent(String.self, forKey: .scanner)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
        scannedAt = try container.decodeIfPresent(Int.self, forKey: .scannedAt)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        composite = try container.decodeIfPresent(String.self, forKey: .composite)
        hidden = LibraryVisibility(container, forKey: .hidden)
    }
}

extension LibraryVisibility {
    /// Lenient: PMS sends an integer, but a string or bool must not fail the
    /// whole section list, and an unknown value counts as included.
    init<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) {
        let raw: Int?
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            raw = value
        } else if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            raw = Int(value)
        } else if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            raw = value ? 1 : 0
        } else {
            raw = nil
        }
        self = raw.flatMap(Self.init(rawValue:)) ?? .included
    }
}
