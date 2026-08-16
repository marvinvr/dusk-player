import Foundation

enum PlexServiceError: Error, Sendable, Equatable, LocalizedError {
    case notImplemented
    case notAuthenticated
    case noServerConnected
    case invalidURL
    case authenticationPending
    case unauthorized
    case homeUserUnavailable
    case homePINRequired
    case homePINIncorrect
    case httpError(statusCode: Int)
    case decodingError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            "This feature is not yet implemented."
        case .notAuthenticated:
            "Not signed in to Plex."
        case .noServerConnected:
            "No Plex server connected."
        case .invalidURL:
            "Invalid URL."
        case .authenticationPending:
            "Finishing Plex sign-in. Please wait a moment and try again."
        case .unauthorized:
            "Authentication expired. Please sign in again."
        case .homeUserUnavailable:
            "That Plex Home user is no longer available."
        case .homePINRequired:
            "Enter this user’s Plex Home PIN."
        case .homePINIncorrect:
            "That Plex Home PIN is incorrect."
        case .httpError(let code):
            "Server returned HTTP \(code)."
        case .decodingError(let detail):
            "Failed to parse server response: \(detail)"
        case .networkError(let detail):
            "Network error: \(detail)"
        }
    }

    /// The stored Plex account session is missing or rejected. Retrying the
    /// failed request cannot recover it; the user has to sign in again.
    var requiresReauthentication: Bool {
        switch self {
        case .unauthorized, .notAuthenticated:
            true
        default:
            false
        }
    }
}
