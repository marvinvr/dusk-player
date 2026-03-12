import Foundation

/// A library section on the Plex server (e.g. "Movies", "TV Shows").
/// Returned from `GET /library/sections` in the `Directory` array.
struct PlexLibrary: Codable, Sendable, Identifiable {
    var id: String { key }

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
