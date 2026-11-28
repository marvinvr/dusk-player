import Foundation

/// A `Hub` row from `GET /hubs`, `/hubs/sections/{id}`, `/hubs/promoted`,
/// `/hubs/continueWatching` and `/hubs/search`. `PlexItemMapper` builds
/// `HomeRow`, including its single-server `sources` entry.
struct PlexHubDTO: Decodable, Sendable {
    let key: String?
    let title: String
    let type: String?
    let hubIdentifier: String?
    let size: Int?
    let more: Bool?
    let librarySectionID: String?
    let librarySectionTitle: String?
    /// `Metadata` rows followed by `Directory` rows. Rows that are not
    /// item-shaped (search suggestion directories) are dropped.
    let items: [PlexItemDTO]

    enum CodingKeys: String, CodingKey {
        case key, title, type, hubIdentifier, size, more
        case librarySectionID, librarySectionTitle
        case metadata = "Metadata"
        case directories = "Directory"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        hubIdentifier = try container.decodeIfPresent(String.self, forKey: .hubIdentifier)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        more = try container.decodeIfPresent(Bool.self, forKey: .more) ??
            (try container.decodeIfPresent(Int.self, forKey: .more).map { $0 != 0 })
        // Plex serializes librarySectionID as a number; tolerate strings too.
        if let numericSectionID = try? container.decodeIfPresent(Int.self, forKey: .librarySectionID) {
            librarySectionID = String(numericSectionID)
        } else {
            librarySectionID = (try? container.decodeIfPresent(String.self, forKey: .librarySectionID)) ?? nil
        }
        librarySectionTitle = try container.decodeIfPresent(String.self, forKey: .librarySectionTitle)

        let metadataItems = try container.decodeLossyPlexItemsIfPresent(forKey: .metadata)
        let directoryItems = try container.decodeLossyPlexItemsIfPresent(forKey: .directories)
        items = metadataItems + directoryItems
    }
}

/// `MediaContainer.Hub` envelope.
struct PlexHubResponseDTO: Decodable, Sendable {
    let MediaContainer: Container

    struct Container: Decodable, Sendable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Hub: [PlexHubDTO]?
    }
}

/// A hub's own item page (`GET {hub.key}`): items under `Metadata` and/or
/// `Directory`.
struct PlexHubItemsResponseDTO: Decodable, Sendable {
    let MediaContainer: Container

    struct Container: Decodable, Sendable {
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let Metadata: [PlexItemDTO]?
        let Directory: [PlexItemDTO]?
    }
}

private extension KeyedDecodingContainer where Key == PlexHubDTO.CodingKeys {
    func decodeLossyPlexItemsIfPresent(forKey key: Key) throws -> [PlexItemDTO] {
        guard contains(key), try !decodeNil(forKey: key) else { return [] }
        return try decode(LossyPlexItemArray.self, forKey: key).items
    }
}

private struct LossyPlexItemArray: Decodable {
    let items: [PlexItemDTO]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [PlexItemDTO] = []

        while !container.isAtEnd {
            do {
                items.append(try container.decode(PlexItemDTO.self))
            } catch {
                // Plex short-search responses can include suggestion directories that do not
                // conform to the media item shape the UI expects.
                _ = try container.decode(IgnoredJSONValue.self)
            }
        }

        self.items = items
    }
}

private struct IgnoredJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                _ = try container.decode(IgnoredJSONValue.self)
            }
            return
        }

        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in container.allKeys {
                _ = try container.decode(IgnoredJSONValue.self, forKey: key)
            }
            return
        }

        let container = try decoder.singleValueContainer()

        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(Int.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
