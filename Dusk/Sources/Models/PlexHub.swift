import Foundation

/// A "hub" on the Plex home screen (e.g. "Continue Watching", "Recently Added Movies").
/// Returned from `GET /hubs`, `GET /hubs/sections/{sectionId}`, and `GET /hubs/search`.
struct PlexHub: Decodable, Sendable, Identifiable, Hashable {
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
        case metadata = "Metadata"
        case directories = "Directory"
    }

    init(
        key: String?,
        title: String,
        type: String?,
        hubIdentifier: String?,
        size: Int?,
        more: Bool?,
        items: [PlexItem]
    ) {
        self.key = key
        self.title = title
        self.type = type
        self.hubIdentifier = hubIdentifier
        self.size = size
        self.more = more
        self.items = items
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

        let metadataItems = try container.decodeLossyPlexItemsIfPresent(forKey: .metadata)
        let directoryItems = try container.decodeLossyPlexItemsIfPresent(forKey: .directories)
        items = metadataItems + directoryItems
    }
}

private extension KeyedDecodingContainer where Key == PlexHub.CodingKeys {
    func decodeLossyPlexItemsIfPresent(forKey key: Key) throws -> [PlexItem] {
        guard contains(key), try !decodeNil(forKey: key) else { return [] }
        return try decode(LossyPlexItemArray.self, forKey: key).items
    }
}

private struct LossyPlexItemArray: Decodable {
    let items: [PlexItem]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [PlexItem] = []

        while !container.isAtEnd {
            do {
                items.append(try container.decode(PlexItem.self))
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
