import Foundation

enum PlexServiceError: Error, Sendable, Equatable, LocalizedError {
    case notImplemented
    case notAuthenticated
    case noServerConnected
    case invalidURL
    case unauthorized
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
        case .unauthorized:
            "Authentication expired. Please sign in again."
        case .httpError(let code):
            "Server returned HTTP \(code)."
        case .decodingError(let detail):
            "Failed to parse server response: \(detail)"
        case .networkError(let detail):
            "Network error: \(detail)"
        }
    }
}
