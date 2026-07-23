import Foundation

enum PlexLibraryType: String, Codable, Sendable, CaseIterable {
    case movie
    case show
    case video

    var tabTitle: String {
        switch self {
        case .movie:
            "Movies"
        case .show:
            "TV Shows"
        case .video:
            "Videos"
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
        }
    }
}

/// A library section on the Plex server (e.g. "Movies", "TV Shows").
/// Returned from `GET /library/sections` in the `Directory` array.
struct PlexLibrary: Codable, Sendable, Identifiable {
    var id: String { key }

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
