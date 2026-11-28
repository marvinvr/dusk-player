import Foundation

/// Progress reports, watched state and favourites
/// (docs/jellyfin/04-architecture.md §12.5). Empty until P0-10, which also
/// settles `PlaybackReport`.
protocol UserDataProviding: Sendable {}

/// One playback report.
struct PlaybackReport: Sendable {
    enum State: Sendable, Hashable {
        case started
        case progress
        case paused
        case buffering
        case stopped
    }

    let item: MediaItemID
    let sessionID: String
    let versionID: String?
    let state: State
    let positionMs: Int
    let durationMs: Int?
    let playMethod: PlayMethod
    let audioStreamID: String?
    let subtitleStreamID: String?
}
