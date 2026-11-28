import Foundation

/// Jellyfin's progress reports and watched state (02 §8, 04 §12.5).
///
/// - A session's first report opens it with `POST /Sessions/Playing`; later
///   ones go to `/Progress`, the last to `/Stopped`. Every `Playing` call
///   counts a play (`PlayCount` +1, measured on 12.4 even with the same
///   `PlaySessionId`), so a session is opened once, however many engines it
///   goes through (`JellyfinPlaybackSessions`).
/// - The server marks an item played from the stopped report (past 90 %), so
///   the coordinator's 90 % rule never calls `setWatched` here
///   (`PlaybackTraits.serverAppliesWatchedThreshold`); a second write would
///   count the play twice.
/// - Resume points below the server's minimum (5 %, and items under 5 min)
///   are dropped by the server; Dusk takes its answer.
/// - The reported track indexes become the item's remembered tracks when the
///   user has `RememberAudioSelections` / `RememberSubtitleSelections` on. A
///   report without them leaves the remembered ones as they are.
@MainActor
struct JellyfinUserData: UserDataProviding {
    let server: JellyfinServerProvider

    nonisolated init(server: JellyfinServerProvider) {
        self.server = server
    }

    func report(_ event: PlaybackReport) async throws {
        try await JellyfinPlaybackSessions.shared.send(event, client: server.client())
    }

    /// `date` is when it happened, for an offline replay (`datePlayed=`).
    func setWatched(_ watched: Bool, item: MediaItemID, at date: Date?) async throws {
        let client = try server.client()
        if watched {
            _ = try await client.send(JellyfinAPI.markPlayed(itemID: item.itemID, datePlayed: date))
        } else {
            _ = try await client.send(JellyfinAPI.markUnplayed(itemID: item.itemID))
        }
    }
}

/// The player sessions this app run has opened on a Jellyfin server, so each
/// is opened (`/Sessions/Playing`) exactly once. Shared because a server's
/// provider (and its facets) can be rebuilt while a session plays. Reports
/// of one session are sent in order behind its opening call.
@MainActor
final class JellyfinPlaybackSessions {
    static let shared = JellyfinPlaybackSessions()

    /// Opening calls by player session id, oldest first. Kept after the
    /// session stops: a report that arrives late must not open it again.
    private var openings: [(sessionID: String, task: Task<Void, Error>)] = []
    private static let remembered = 32

    func send(_ event: PlaybackReport, client: JellyfinClient) async throws {
        let requests = Self.requests(for: event)
        if let sessionID = event.sessionID, event.state != .stopped || isOpen(sessionID) {
            let opening = openingTask(for: sessionID, event: event, client: client)
            do {
                try await opening.value
            } catch {
                // Not opened: the next report tries again.
                openings.removeAll { $0.sessionID == sessionID }
                throw error
            }
            if event.state == .started { return }
        } else if event.state == .started {
            // An offline replay has no session to open.
            return
        }
        try await client.send(requests.follow)
    }

    func isOpen(_ sessionID: String) -> Bool {
        openings.contains { $0.sessionID == sessionID }
    }

    private func openingTask(for sessionID: String, event: PlaybackReport, client: JellyfinClient) -> Task<Void, Error> {
        if let existing = openings.first(where: { $0.sessionID == sessionID }) {
            return existing.task
        }
        let start = Self.requests(for: event).start
        let task = Task<Void, Error> { _ = try await client.send(start) }
        openings.append((sessionID, task))
        if openings.count > Self.remembered {
            openings.removeFirst(openings.count - Self.remembered)
        }
        return task
    }

    /// The opening call for `event`'s session and the call `event` itself
    /// maps to. Pure; tests read it.
    nonisolated static func requests(
        for event: PlaybackReport
    ) -> (start: JellyfinRequest<JellyfinNoContent>, follow: JellyfinRequest<JellyfinNoContent>) {
        var body = JellyfinPlaybackReportDTO(itemID: JellyfinID.normalized(event.item.itemID))
        body.mediaSourceID = event.versionID.map(JellyfinID.normalized) ?? body.itemID
        body.playSessionID = event.sessionID
        body.positionTicks = JellyfinTicks(milliseconds: max(0, event.positionMs))

        var start = body
        start.playMethod = playMethod(event.playMethod)
        start.canSeek = true
        start.isPaused = false
        start.audioStreamIndex = event.audioStreamID.flatMap(Int.init)
        start.subtitleStreamIndex = event.subtitleStreamID.flatMap(Int.init)

        let follow: JellyfinRequest<JellyfinNoContent>
        switch event.state {
        case .stopped:
            follow = JellyfinAPI.reportPlaybackStopped(body)
        case .started, .progress, .paused, .buffering:
            var progress = start
            progress.isPaused = event.state == .paused
            progress.eventName = event.state == .paused ? "Pause" : "TimeUpdate"
            follow = JellyfinAPI.reportPlaybackProgress(progress)
        }
        return (JellyfinAPI.reportPlaybackStart(start), follow)
    }

    nonisolated static func playMethod(_ method: PlayMethod?) -> JellyfinPlayMethod {
        switch method {
        case .directPlay?, nil: .directPlay
        case .directStream?: .directStream
        case .transcode?: .transcode
        }
    }
}
