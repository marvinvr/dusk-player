import Foundation

enum PlexLibraryType: String, Codable, Sendable, CaseIterable {
    case movie
    case show

    var tabTitle: String {
        switch self {
        case .movie:
            "Movies"
        case .show:
            "TV Shows"
        }
    }

    var systemImage: String {
        switch self {
        case .movie:
            "film"
        case .show:
            "tv.fill"
        }
    }
}

/// A library section on the Plex server (e.g. "Movies", "TV Shows").
/// Returned from `GET /library/sections` in the `Directory` array.
struct PlexLibrary: Codable, Sendable, Identifiable {
    var id: String { key }

    var libraryType: PlexLibraryType? {
        PlexLibraryType(rawValue: type)
    }

    let key: String
    let title: String
    let type: String
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
