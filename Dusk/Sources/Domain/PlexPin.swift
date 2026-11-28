import Foundation

/// Response from `POST https://plex.tv/api/v2/pins` and `GET /api/v2/pins/{id}`.
struct PlexPin: Codable, Sendable {
    let id: Int
    let code: String
    let clientIdentifier: String
    let expiresAt: String

    /// Populated once the user approves the PIN in the browser.
    let authToken: String?
}
