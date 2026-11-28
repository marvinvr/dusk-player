import Foundation

enum LibraryKind: String, Codable, Sendable, CaseIterable {
    case movie
    case show
    case video
    case liveTV
    case photo
    /// Not a Plex library: the account's video playlists, a destination that
    /// shares the library tabs' order and visibility settings.
    case playlists

    var tabTitle: String {
        switch self {
        case .movie:
            "Movies"
        case .show:
            "TV Shows"
        case .video:
            "Videos"
        case .liveTV:
            "Live TV"
        case .photo:
            "Photos"
        case .playlists:
            "Playlists"
        }
    }

    var systemImage: String {
        switch self {
        case .movie:
            "film"
        case .show:
            "tv"
        case .video:
            "play.rectangle"
        case .liveTV:
            "dot.radiowaves.left.and.right"
        case .photo:
            "photo.on.rectangle"
        case .playlists:
            "list.and.film"
        }
    }
}

/// A section's server-side Visibility (library › Advanced › Visibility), sent
/// as `hidden` on `/library/sections`. Unlike the account's Hidden Libraries
/// it never hides the library itself: it stays in the library list and can be
/// browsed, only its titles leave Home (and, for `.excludedFromHomeAndSearch`,
/// search and Siri). See `HiddenLibraryFilter.Scope`.
enum PlexLibraryVisibility: Int, Codable, Sendable, Hashable {
    /// "Include in home screen and global search" (`hidden="0"` or absent).
    case included = 0
    /// "Exclude from home screen".
    case excludedFromHome = 1
    /// "Exclude from home screen and global search".
    case excludedFromHomeAndSearch = 2

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

/// A library section on the Plex server (e.g. "Movies", "TV Shows").
/// Returned from `GET /library/sections` in the `Directory` array.
struct Library: Codable, Sendable, Identifiable {
    /// Section keys are per-server counters, so the server has to be part of
    /// the identity or two servers' "3" sections alias each other.
    var id: String {
        guard let serverID else { return key }
        return "\(serverID)|\(key)"
    }

    /// Stamped by `ServerPool.decoder(for:)`; never part of the Plex payload,
    /// so it is excluded from `CodingKeys` and dropped when re-encoded.
    let serverID: String?

    /// Plex reports "Other Videos" sections as `type == "movie"`, so they are
    /// told apart by their clip subtype, metadata-less agent, or video scanner.
    var libraryType: LibraryKind? {
        switch type {
        case "movie":
            isVideoSection ? .video : .movie
        case "show":
            .show
        case "photo":
            .photo
        default:
            nil
        }
    }

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
    /// The server-side Visibility setting (library › Advanced), Plex's `hidden`.
    let visibility: PlexLibraryVisibility

    enum CodingKeys: String, CodingKey {
        case key, title, type, subtype, agent, scanner, language, uuid
        case updatedAt, createdAt, scannedAt
        case thumb, art, composite
        case visibility = "hidden"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = decoder.duskServerID
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
        visibility = PlexLibraryVisibility(container, forKey: .visibility)
    }

    private static let videoSectionAgents: Set<String> = [
        "tv.plex.agents.none",
        "com.plexapp.agents.none"
    ]

    private var isVideoSection: Bool {
        if subtype == "clip" {
            return true
        }

        if let agent, Self.videoSectionAgents.contains(agent) {
            return true
        }

        if let scanner, scanner.hasPrefix("Plex Video Files") {
            return true
        }

        return false
    }
}

struct PlexLibraryFilter: Codable, Sendable, Hashable {
    let filter: String
    let filterType: String?
    let key: String
    let title: String
    let type: String?
}

struct PlexLibraryFilterValue: Codable, Sendable, Hashable, Identifiable {
    var id: String { key }

    let key: String
    let title: String
    let type: String?
}

/// One `firstCharacter` row: titles whose sort title starts with `key`
/// ("#" for digits and symbols).
struct PlexFirstCharacter: Decodable, Sendable, Hashable {
    let key: String
    let size: Int
}
