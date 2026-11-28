import Foundation

/// One entry of a Plex photo library: an album (folder), a photo, or a video
/// clip that lives among the photos.
///
/// Photo libraries are decoded separately from `MediaItem` on purpose: an album
/// and a photo both arrive as `type: "photo"` (only an album's `key` ends in
/// `/children`), and `MediaItem` keeps photos as `.unknown`, which is what keeps
/// them off Home, Search and the detail routes.
struct PhotoItem: Decodable, Sendable, Identifiable, Hashable {
    enum Kind: Sendable {
        case album
        case photo
        case clip
    }

    var id: MediaItemID { MediaItemID(serverID: serverID, ratingKey: ratingKey) }

    /// Stamped by `ServerPool.decoder(for:)`, like `MediaItem.serverID`.
    let serverID: String?
    let ratingKey: String
    let key: String
    /// nil for a type photo libraries never hold; such entries are dropped.
    let kind: Kind?
    let title: String
    let thumb: String?
    /// Albums carry a collage of their photos here.
    let composite: String?
    /// The camera-local day the photo was taken, `yyyy-MM-dd`.
    let originallyAvailableAt: String?
    let addedAt: Int?
    let year: Int?
    /// Clips only, in milliseconds.
    let duration: Int?
    let width: Int?
    let height: Int?
    /// The original file (`/library/parts/…`). The photo transcoder resizes it
    /// for the viewer and applies the EXIF rotation.
    let partKey: String?
    let make: String?
    let model: String?
    /// Place names, only present when the server saves location names.
    let places: [String]

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, thumb, composite
        case originallyAvailableAt, addedAt, year, duration
        case media = "Media"
        case places = "Place"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = decoder.duskServerID
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        composite = try container.decodeIfPresent(String.self, forKey: .composite)
        originallyAvailableAt = try container.decodeIfPresent(String.self, forKey: .originallyAvailableAt)
        addedAt = try? container.decodeIfPresent(Int.self, forKey: .addedAt)
        year = try? container.decodeIfPresent(Int.self, forKey: .year)
        duration = try? container.decodeIfPresent(Int.self, forKey: .duration)

        switch try container.decodeIfPresent(String.self, forKey: .type) {
        case "photo":
            kind = key.hasSuffix("/children") ? .album : .photo
        case "clip":
            kind = .clip
        default:
            kind = nil
        }

        // Media fields vary by server and file type, so nothing in here may
        // fail the whole page.
        let media = (try? container.decodeIfPresent([PhotoMedia].self, forKey: .media))?.first
        width = media?.width
        height = media?.height
        partKey = media?.parts.first?.key
        make = media?.make
        model = media?.model
        places = (try? container.decodeIfPresent([Tag].self, forKey: .places))?.map(\.tag) ?? []
    }

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
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

extension PhotoItem {
    var isAlbum: Bool { kind == .album }
    var isClip: Bool { kind == .clip }

    /// "2 Mar 2024". `originallyAvailableAt` is a camera-local calendar day,
    /// so it is read in the device's time zone, never as UTC midnight (which
    /// shows the day before anywhere west of Greenwich).
    var displayDate: String? {
        if let day = originallyAvailableAt?.prefix(10),
           let date = Self.dayFormatter.date(from: String(day)) {
            return Self.displayFormatter.string(from: date)
        }
        guard let addedAt else { return nil }
        return Self.displayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(addedAt)))
    }

    var displayPlace: String? {
        places.joined(separator: ", ").nilIfEmpty
    }

    /// "Apple iPhone 15 Pro"; the make is dropped when the model already
    /// starts with it, as most cameras write it.
    var displayCamera: String? {
        guard let model = model?.nilIfEmpty else { return make?.nilIfEmpty }
        guard let make = make?.nilIfEmpty,
              !model.lowercased().hasPrefix(make.lowercased()) else { return model }
        return "\(make) \(model)"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("d MMM y")
        return formatter
    }()
}

/// An album opened from a photo grid. It carries its library because the
/// album's contents are queried through the section (`parent=`), and the
/// library's server is the only server that knows the album's rating key.
struct PhotoAlbumRoute: Hashable {
    let library: Library
    let ratingKey: String
    let title: String
}
