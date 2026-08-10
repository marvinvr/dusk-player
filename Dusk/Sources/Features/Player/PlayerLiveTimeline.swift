import Foundation

/// Estimates where "live" sits on the engine's clock for a live HLS session.
///
/// AVPlayer only advances `seekableTimeRanges` when a new segment lands, so the
/// gap between the playhead and that upper bound steps by whole segments and
/// then shrinks again as playback rolls into them. Anything derived from it
/// directly — a progress fraction, a "behind live" readout — visibly jitters.
///
/// A live stream instead produces exactly one second of content per second of
/// wall clock, so this keeps the highest live position ever observed and
/// projects it forward in real time. The estimate then only moves relative to
/// the playhead when the *viewer* moves: a pause, a rewind, or a stall. That is
/// the only thing "behind live" should ever mean.
struct LiveEdgeClock {
    private var anchorEdge: TimeInterval?
    private var anchoredAt: Date?

    var isAnchored: Bool { anchorEdge != nil }

    /// Folds one engine sample into the estimate and returns the live position
    /// on the engine clock. The estimate only ratchets upwards: both inputs
    /// advance in real time while playing at the edge, so a signal that
    /// overtakes the projection means the projection, not the signal, is stale
    /// (startup, a Go Live seek, or the engine skipping ahead after a stall).
    @discardableResult
    mutating func update(
        position: TimeInterval,
        seekableEnd: TimeInterval?,
        now: Date
    ) -> TimeInterval {
        var observed = position.isFinite ? position : 0
        if let seekableEnd, seekableEnd.isFinite, seekableEnd > observed {
            observed = seekableEnd
        }

        guard let anchorEdge, let anchoredAt else {
            self.anchorEdge = observed
            self.anchoredAt = now
            return observed
        }

        let projected = anchorEdge + now.timeIntervalSince(anchoredAt)
        guard observed > projected else { return projected }

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
    /// long) still gets a sanely scaled bar, and capped so a long session does
    /// not compress the playhead into the last pixel.
    static let fallbackWindowSpan: TimeInterval = 30 * 60
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
            window = start...end
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

        // Nothing to anchor to until the engine reports a real position; the
        // HUD falls back to a plain LIVE badge until then.
        guard currentTime > 0 || liveEdgeClock.isAnchored else { return }

        let liveEdge = liveEdgeClock.update(
            position: currentTime,
            seekableEnd: seekableRange?.upperBound,
            now: now
        )

        liveTimeline = .make(
            context: liveTVContext,
            position: currentTime,
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
