import Foundation

enum PlexLibraryType: String, Codable, Sendable, CaseIterable {
    case movie
    case show
    case video
    case liveTV

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
        }
    }
}

/// A library section on the Plex server (e.g. "Movies", "TV Shows").
/// Returned from `GET /library/sections` in the `Directory` array.
struct PlexLibrary: Codable, Sendable, Identifiable {
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
    var libraryType: PlexLibraryType? {
        switch type {
        case "movie":
            isVideoSection ? .video : .movie
        case "show":
            .show
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

    enum CodingKeys: String, CodingKey {
        case key, title, type, subtype, agent, scanner, language, uuid
        case updatedAt, createdAt, scannedAt
        case thumb, art, composite
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
