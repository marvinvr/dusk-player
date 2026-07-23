import Foundation

enum SeerrServiceError: LocalizedError, Equatable {
    case invalidServerURL
    case serverMismatch
    case notConfigured
    case notConnected
    case plexLoginUnavailable
    case plexUserNotAllowed
    case authenticationRequired(String)
    case permissionDenied(String)
    case requestConflict(String)
    case noSeasonsAvailable(String)
    case serverError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "Enter a valid Seerr server URL."
        case .serverMismatch:
            "This Seerr connection belongs to a different Plex server."
        case .notConfigured:
            "Set up Seerr in Settings before using request results."
        case .notConnected:
            "Connect this Plex user to Seerr in Settings."
        case .plexLoginUnavailable:
            "This Seerr server is not configured to accept Plex sign-in."
        case .plexUserNotAllowed:
            "This Plex user is not allowed to sign in to this Seerr server."
        case .authenticationRequired(let message),
             .permissionDenied(let message),
             .requestConflict(let message),
             .noSeasonsAvailable(let message),
             .serverError(let message):
            message
        case .invalidResponse:
            "Seerr returned an invalid response."
        }
    }
}
