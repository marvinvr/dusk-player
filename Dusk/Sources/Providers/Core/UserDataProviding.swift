import Foundation

/// Progress reports and watched state for one server
/// (docs/jellyfin/04-architecture.md §12.5).
///
/// Dusk keeps the 90 % rule: the coordinator decides when an item is finished
/// and calls `setWatched` (skipped when the server's
/// `PlaybackTraits.serverAppliesWatchedThreshold` says it marks the item itself).
///
/// Main-actor isolated so a report reaches the server in the order the player
/// sent it, as it did when the facade called Plex directly.
///
/// `setResumeOffset` and `setFavourite` (04 §12.5) are not declared yet: no Plex
/// flow uses them, and a facet method that exists must work. The Jellyfin
/// packages that need them add them.
@MainActor
protocol UserDataProviding: Sendable {
    /// Sends one playback report. Throws so offline replay can tell a report
    /// the server took from one it did not; live playback ignores the error.
    func report(_ event: PlaybackReport) async throws

    /// Marks an item watched or unwatched on this server. `date` is when it
    /// happened, for an offline replay; a provider without that notion ignores it.
    func setWatched(_ watched: Bool, item: MediaItemID, at date: Date?) async throws
}

/// One playback report.
struct PlaybackReport: Sendable, Hashable {
    enum State: Sendable, Hashable {
        case started
        case progress
        case paused
        case buffering
        case stopped
    }

    /// The item played. Its `serverID` picks the server the report goes to;
    /// nil means the primary server, as every unrouted call has always meant.
    let item: MediaItemID
    let state: State
    let positionMs: Int
    let durationMs: Int
    /// The player's session id. nil for a report replayed offline, which
    /// belongs to no session.
    let sessionID: String?
    /// Plex Live TV only: the tuned session's path, which Plex wants as the
    /// timeline's key instead of the item's metadata path.
    let liveSessionPath: String?
    let versionID: String?
    let playMethod: PlayMethod?
    /// The tracks the viewer picked, as server stream ids; nil when they
    /// picked none (the automatic choice is not reported).
    let audioStreamID: String?
    /// `PlaybackReport.subtitlesOff` when subtitles are off.
    let subtitleStreamID: String?

    /// `subtitleStreamID` for "no subtitle playing" (Jellyfin's own `-1`).
    static let subtitlesOff = "-1"

    init(
        item: MediaItemID,
        state: State,
        positionMs: Int,
        durationMs: Int,
        sessionID: String? = nil,
        liveSessionPath: String? = nil,
        versionID: String? = nil,
        playMethod: PlayMethod? = nil,
        audioStreamID: String? = nil,
        subtitleStreamID: String? = nil
    ) {
        self.item = item
        self.state = state
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.sessionID = sessionID
        self.liveSessionPath = liveSessionPath
        self.versionID = versionID
        self.playMethod = playMethod
        self.audioStreamID = audioStreamID
        self.subtitleStreamID = subtitleStreamID
    }
}

extension PlaybackReport.State {
    /// The report state for an engine/player state. Loading is "buffering"
    /// so the server keeps the session (and any transcoder) alive while the
    /// engine opens or refills; idle, stopped and error all end the session.
    init(_ state: PlaybackState) {
        switch state {
        case .playing: self = .progress
        case .paused: self = .paused
        case .loading: self = .buffering
        case .idle, .stopped, .error: self = .stopped
        }
    }
}
