import Foundation

/// One row of a photo library query (`/library/sections/{id}/all` with photo
/// types). Mapped to `PhotoItem` by `PlexUserContentMapper`, which also tells
/// an album from a photo (both are `type: "photo"`).
struct PlexPhotoItemDTO: Decodable, Sendable {
    let itemID: String
    let key: String
    let type: String?
    let title: String
    let thumb: String?
    let composite: String?
    let originallyAvailableAt: String?
    let addedAt: Int?
    let year: Int?
    let duration: Int?
    let width: Int?
    let height: Int?
    let partKey: String?
    let make: String?
    let model: String?
    let places: [String]

    enum CodingKeys: String, CodingKey {
        case itemID = "ratingKey", key, type, title, thumb, composite
        case originallyAvailableAt, addedAt, year, duration
        case media = "Media"
        case places = "Place"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decode(String.self, forKey: .itemID)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        composite = try container.decodeIfPresent(String.self, forKey: .composite)
        originallyAvailableAt = try container.decodeIfPresent(String.self, forKey: .originallyAvailableAt)
        addedAt = try? container.decodeIfPresent(Int.self, forKey: .addedAt)
        year = try? container.decodeIfPresent(Int.self, forKey: .year)
        duration = try? container.decodeIfPresent(Int.self, forKey: .duration)
        type = try container.decodeIfPresent(String.self, forKey: .type)

        // Media fields vary by server and file type, so nothing in here may
        // fail the whole page.
        let media = (try? container.decodeIfPresent([PhotoMedia].self, forKey: .media))?.first
        width = media?.width
        height = media?.height
        partKey = media?.parts.first?.key
        make = media?.make
        model = media?.model
        places = (try? container.decodeIfPresent([PhotoPlace].self, forKey: .places))?.map(\.tag) ?? []
    }
}

/// A `Place` tag. Only the name is read.
private struct PhotoPlace: Decodable {
    let tag: String
}

private struct PhotoMedia: Decodable {
    let width: Int?
    let height: Int?
    let make: String?
    let model: String?
    let parts: [PhotoPart]

    struct PhotoPart: Decodable {
        let key: String?
    }

    enum CodingKeys: String, CodingKey {
        case width, height, make, model
        case parts = "Part"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try? container.decodeIfPresent(Int.self, forKey: .width)
        height = try? container.decodeIfPresent(Int.self, forKey: .height)
        make = try? container.decodeIfPresent(String.self, forKey: .make)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        parts = (try? container.decodeIfPresent([PhotoPart].self, forKey: .parts)) ?? []
    }
}
