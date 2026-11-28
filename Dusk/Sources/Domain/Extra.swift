import Foundation

/// The kind of a Plex extra (trailer, deleted scene, featurette, …), from the
/// clip's numeric `extraType`. The codes are Plex's own; `subtype` carries the
/// same thing as a camelCase name (`behindTheScenes`) and stands in when a
/// server leaves the number out.
enum PlexExtraType: Int, Sendable, Hashable, CaseIterable {
    case trailer = 1
    case deletedScene = 2
    case interview = 3
    case musicVideo = 4
    case behindTheScenes = 5
    case sceneOrSample = 6
    case liveMusicVideo = 7
    case lyricMusicVideo = 8
    case concert = 9
    case featurette = 10
    case short = 11
    case other = 12

    init?(extraType: Int?, subtype: String?) {
        if let extraType, let kind = PlexExtraType(rawValue: extraType) {
            self = kind
            return
        }
        guard let subtype,
              let kind = Self.allCases.first(where: {
                  $0.subtypeName.caseInsensitiveCompare(subtype) == .orderedSame
              }) else {
            return nil
        }
        self = kind
    }

    /// Plex's `subtype` spelling of the kind.
    var subtypeName: String {
        switch self {
        case .trailer: "trailer"
        case .deletedScene: "deletedScene"
        case .interview: "interview"
        case .musicVideo: "musicVideo"
        case .behindTheScenes: "behindTheScenes"
        case .sceneOrSample: "sceneOrSample"
        case .liveMusicVideo: "liveMusicVideo"
        case .lyricMusicVideo: "lyricMusicVideo"
        case .concert: "concert"
        case .featurette: "featurette"
        case .short: "short"
        case .other: "other"
        }
    }

    /// The label on an extra's card. "Other" says nothing, so it reads "Extra".
    var label: String {
        switch self {
        case .trailer: "Trailer"
        case .deletedScene: "Deleted Scene"
        case .interview: "Interview"
        case .musicVideo: "Music Video"
        case .behindTheScenes: "Behind the Scenes"
        case .sceneOrSample: "Scene"
        case .liveMusicVideo: "Live Music Video"
        case .lyricMusicVideo: "Lyric Video"
        case .concert: "Concert"
        case .featurette: "Featurette"
        case .short: "Short"
        case .other: "Extra"
        }
    }
}

/// One extra of a movie, show, season, or episode: a playable clip with its own
/// rating key (`/library/metadata/{key}/extras`).
struct Extra: Identifiable, Sendable, Hashable {
    let item: MediaItem
    let kind: PlexExtraType?

    var id: MediaItemID { item.id }

    /// "Trailer · 2 min". Extras rarely have an air date worth showing, so
    /// this replaces the clip card's date line. An extra titled after its kind
    /// (a lone "Trailer") does not repeat it.
    var cardSubtitle: String? {
        let label = kind?.label ?? "Extra"
        let showsLabel = item.title.caseInsensitiveCompare(label) != .orderedSame
        return [showsLabel ? label : nil, MediaTextFormatter.compactDuration(milliseconds: item.duration)]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }
}

/// The extra-specific fields of an `/extras` row. `MediaItem` decodes the rest;
/// both read the same payload.
struct PlexExtraFields: Decodable, Sendable {
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

extension Extra {
    /// Pairs decoded items with their extra fields by rating key, in Plex's
    /// order. Only clips are extras; anything else in the payload is dropped.
    static func extras(items: [MediaItem], fields: [PlexExtraFields]) -> [Extra] {
        let fieldsByKey = Dictionary(fields.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        return items.compactMap { item in
            guard item.isClip else { return nil }
            let field = fieldsByKey[item.itemID]
            return Extra(
                item: item,
                kind: PlexExtraType(extraType: field?.extraType, subtype: field?.subtype ?? item.subtype)
            )
        }
    }
}
