import Foundation

/// The type of media item in a Plex library.
enum PlexMediaType: String, Codable, Sendable {
    case movie
    case show
    case person
    case season
    case episode
    case clip
    case artist
    case album
    case track

    /// Returned when the Plex API sends a type we don't handle yet.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlexMediaType(rawValue: raw) ?? .unknown
    }
}
