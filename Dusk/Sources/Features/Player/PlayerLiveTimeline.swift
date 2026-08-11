import Foundation

/// Estimates where "live" sits on the engine's clock for a live HLS session.
///
/// A live stream produces exactly one second of content per second of wall
/// clock, so the estimate is anchored to the *playhead* and projected forward in
/// real time. It then only moves relative to the playhead when the viewer moves:
/// a pause, a rewind, or a stall. That is the only thing "behind live" should
/// ever mean.
///
/// Deliberately blind to `seekableTimeRange`. Its upper bound is the newest
/// segment the playlist advertises, which sits a play-out buffer *ahead* of
/// where any player is actually rendering — feeding it in here pinned the
/// estimate a segment or two in front of the playhead and produced a standing
/// "−0:10" that flickered across the LIVE threshold. Seeking still clamps to
/// that range; only the edge estimate ignores it.
struct LiveEdgeClock {
    private var anchorEdge: TimeInterval?
    private var anchoredAt: Date?

    var isAnchored: Bool { anchorEdge != nil }

    /// Folds one engine sample into the estimate and returns the live position
    /// on the engine clock.
    ///
    /// A playhead that overtakes the projection means the projection is stale
    /// (startup, a Go Live seek, the engine skipping ahead after a stall), so
    /// the estimate ratchets up to it. While playback is actually running, any
    /// residual smaller than the LIVE tolerance is also collapsed away: the
    /// gap can only have come from buffering hiccups too small to report, and
    /// without this they accumulate until the readout drifts off LIVE and stays
    /// there. Real gaps — a pause, a rewind — are larger than the tolerance by
    /// the time they matter and survive untouched.
    @discardableResult
    mutating func update(
        position: TimeInterval,
        isPlaying: Bool,
        now: Date
    ) -> TimeInterval {
        let observed = position.isFinite ? position : 0

        guard let anchorEdge, let anchoredAt else {
            self.anchorEdge = observed
            self.anchoredAt = now
            return observed
        }

        let projected = anchorEdge + now.timeIntervalSince(anchoredAt)
        let residual = projected - observed
        guard residual <= 0 || (isPlaying && residual < LiveTimelineSnapshot.liveEdgeTolerance) else {
            return projected
        }

        self.anchorEdge = observed
        self.anchoredAt = now
        return observed
    }

    mutating func reset() {
        anchorEdge = nil
        anchoredAt = nil
    }
}

/// A live session's timeline resolved onto wall clock: which scheduled program
/// the play bar is showing, where the playhead and the live edge sit inside it,
/// and how far back the tuned session can still be rewound.
///
/// `anchorPosition`/`anchorDate` are a matched pair — the engine position
/// sampled for this snapshot and the wall-clock instant that content was live —
/// so positions and dates convert freely in both directions. Everything the
/// play bar draws is derived from those two numbers, which is what keeps the
/// bar steady while the underlying HLS window steps around.
struct LiveTimelineSnapshot: Equatable {
    /// How far behind the live edge counts as "still live". Sits above the
    /// couple of seconds of normal HLS play-out latency so a viewer who never
    /// touched the controls always reads LIVE.
    static let liveEdgeTolerance: TimeInterval = 10
    /// Span of the bar when the guide has no program covering the playhead.
    /// Floored so a freshly tuned session (whose rewind window is only seconds
    /// long) is not scrubbed by whole minutes per pixel, and capped so a long
    /// session does not compress the playhead into the last pixel.
    static let fallbackWindowSpan: TimeInterval = 5 * 60
    static let maximumFallbackWindowSpan: TimeInterval = 4 * 60 * 60

    let anchorPosition: TimeInterval
    let anchorDate: Date
    /// Wall clock of the live edge — effectively "now", kept explicit so every
    /// value in a snapshot comes from the same instant.
    let liveDate: Date
    let secondsBehindLive: TimeInterval
    /// The span the play bar covers, in wall clock.
    let window: ClosedRange<Date>
    /// The program the window was built from. Nil when the guide has no
    /// coverage for the playhead, in which case the window is the rewindable
    /// session instead.
    let program: PlexLiveProgram?
    /// Oldest instant the tuned session can still be rewound to, when known.
    let earliestReachableDate: Date?

    var isAtLiveEdge: Bool {
        secondsBehindLive < Self.liveEdgeTolerance
    }

    var livePosition: TimeInterval {
        position(forDate: liveDate)
    }

    func date(forPosition position: TimeInterval) -> Date {
        anchorDate.addingTimeInterval(position - anchorPosition)
    }

    func position(forDate date: Date) -> TimeInterval {
        anchorPosition + date.timeIntervalSince(anchorDate)
    }

    func secondsBehindLive(atPosition position: TimeInterval) -> TimeInterval {
        max(0, liveDate.timeIntervalSince(date(forPosition: position)))
    }

    func isAtLiveEdge(atPosition position: TimeInterval) -> Bool {
        secondsBehindLive(atPosition: position) < Self.liveEdgeTolerance
    }

    /// The window expressed on the engine clock, so the shared seek-bar and
    /// scrubbing code can keep working in playback positions.
    var positionRange: ClosedRange<TimeInterval> {
        let lower = position(forDate: window.lowerBound)
        let upper = position(forDate: window.upperBound)
        return lower...max(lower, upper)
    }

    static func make(
        context: PlexLivePlaybackContext,
        position: TimeInterval,
        liveEdge: TimeInterval,
        seekableRange: ClosedRange<TimeInterval>?,
        now: Date
    ) -> LiveTimelineSnapshot {
        let secondsBehindLive = max(0, liveEdge - position)
        // The playhead's broadcast time. Everything else hangs off this.
        let anchorDate = now.addingTimeInterval(-secondsBehindLive)
        let earliestReachableDate = seekableRange.map {
            anchorDate.addingTimeInterval($0.lowerBound - position)
        }

        // Prefer the guide's program for wherever the playhead actually is: a
        // viewer who rewound across a program boundary is watching the earlier
        // program, and the bar should say so. The tuned program is the
        // fallback for lineups whose guide never loaded.
        let program = context.program(at: anchorDate)
            ?? context.program.flatMap { $0.isAiring(at: anchorDate) ? $0 : nil }

        let window: ClosedRange<Date>
        if let program,
           let start = program.beginsAt,
           let end = program.endsAt,
           end > start {
            // Start the bar at the oldest instant the session can still reach
            // rather than at the program's start. A tuner only begins buffering
            // when the channel is tuned, so the stretch before that is not
            // recoverable on any client — drawing it just gives the bar a dead
            // zone where dragging does nothing. Clipped this way every point
            // left of the playhead is seekable, and the left edge slides back
            // to the program's start on its own as the session buffers.
            let lower = max(start, earliestReachableDate ?? start)
            window = lower...max(end, lower.addingTimeInterval(60))
        } else {
            let reachableSpan = earliestReachableDate.map { now.timeIntervalSince($0) } ?? 0
            let span = min(
                max(reachableSpan, fallbackWindowSpan),
                maximumFallbackWindowSpan
            )
            window = now.addingTimeInterval(-span)...now
        }

        return LiveTimelineSnapshot(
            anchorPosition: position,
            anchorDate: anchorDate,
            liveDate: now,
            secondsBehindLive: secondsBehindLive,
            window: window,
            program: program,
            earliestReachableDate: earliestReachableDate
        )
    }
}

extension PlayerViewModel {
    /// Recomputes the live snapshot from the latest engine sample. Called from
    /// `sync()`, so the whole live HUD updates on one cadence from one instant.
    func updateLiveTimeline(now: Date) {
        guard let liveTVContext else {
            if liveTimeline != nil { liveTimeline = nil }
            liveEdgeClock.reset()
            return
        }

        // Always the engine's own position, never `currentTime`: the latter
        // freezes at the scrub preview while dragging, and a frozen playhead
        // would read to the clock as a session falling behind live.
        let position = engine.currentTime

        // Nothing to anchor to until the engine reports a real position; the
        // HUD falls back to a plain LIVE badge until then.
        guard position > 0 || liveEdgeClock.isAnchored else { return }

        let liveEdge = liveEdgeClock.update(
            position: position,
            isPlaying: engine.state == .playing,
            now: now
        )

        liveTimeline = .make(
            context: liveTVContext,
            position: position,
            liveEdge: liveEdge,
            seekableRange: seekableRange,
            now: now
        )
    }

    /// The program the play bar is currently showing. Falls back to the program
    /// that was airing when the channel was tuned.
    var liveProgram: PlexLiveProgram? {
        liveTimeline?.program ?? liveTVContext?.program
    }

    /// "20:15 – 21:00" for the program on the bar, used as the live session's
    /// stand-in for the position/duration readout.
    var liveProgramWindowLabel: String? {
        guard let program = liveTimeline?.program,
              let beginsAt = program.beginsAt,
              let endsAt = program.endsAt else {
            return nil
        }
        return "\(Self.liveClockFormat(beginsAt)) – \(Self.liveClockFormat(endsAt))"
    }

    /// Wall-clock label for a playback position, shown while scrubbing a live
    /// session (which has no thumbnail previews to show instead).
    func liveClockLabel(for position: TimeInterval) -> String? {
        guard let liveTimeline else { return nil }
        return Self.liveClockFormat(liveTimeline.date(forPosition: position))
    }

    private static func liveClockFormat(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
