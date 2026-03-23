import Foundation

/// The currently authenticated Plex account returned from `GET https://plex.tv/user`.
struct PlexUser: Codable, Sendable, Identifiable {
    let id: Int
    let username: String?
    let title: String?
    let friendlyName: String?
    let thumb: String?
}
