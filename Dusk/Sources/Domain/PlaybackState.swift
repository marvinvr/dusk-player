import Foundation

/// The current state of a playback engine.
enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case stopped
    case error
}
