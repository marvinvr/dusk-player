import Foundation

/// The type of media item in a Plex library.
enum MediaKind: String, Codable, Sendable, Hashable {
    case movie
    case show
    case person
    case season
    case episode
    case clip
    case artist
    case album
    case track
    /// A Plex collection (manual or smart). Its children are movies or shows.
    case collection

    /// Returned when the Plex API sends a type we don't handle yet.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MediaKind(rawValue: raw) ?? .unknown
    }
}
