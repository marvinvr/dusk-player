import Foundation

/// Errors that can occur during playback.
enum PlaybackError: Error, Sendable, Equatable {
    /// The file format cannot be played directly.
    case unsupportedFormat(container: String?, videoCodec: String?, audioCodec: String?)

    /// A network error occurred during playback.
    case networkError(String)

    /// The Plex server is unreachable.
    case serverUnreachable

    /// The auth token is invalid or expired.
    case unauthorized

    /// An unknown error occurred.
    case unknown(String)
}

extension PlaybackError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(container, videoCodec, audioCodec):
            let parts = [container, videoCodec, audioCodec].compactMap { $0 }
            let info = parts.isEmpty ? "" : " [\(parts.joined(separator: " / "))]"
            return "This file couldn't be played directly.\(info)"
        case let .networkError(message):
            return "Network error: \(message)"
        case .serverUnreachable:
            return "The Plex server is unreachable."
        case .unauthorized:
            return "Authentication expired. Please sign in again."
        case let .unknown(message):
            return message
        }
    }
}
