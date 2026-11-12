import Foundation

/// The time axis of one guide section (Plex, or one IPTV source): one start,
/// one scale, so its rows line up under one ruler. Stretches where none of the
/// section's channels has a programme are collapsed to a narrow `collapsedWidth`
/// so a sparse guide (sports feeds with days between sessions) stays compact.
/// Pure layout math, no view code.
struct LiveTVGuideTimeline: Hashable, Sendable {
    /// A stretch of the axis drawn at `collapsedWidth` rather than to scale.
    struct Collapse: Hashable, Sendable {
        let start: Date
        let end: Date
    }

    let start: Date
    let end: Date
    /// Horizontal points per minute of airtime.
    let pointsPerMinute: CGFloat
    /// Oldest first, never overlapping, always inside `start..<end`.
    let collapses: [Collapse]
    let collapsedWidth: CGFloat

    /// The ruler ticks every half hour.
    static let tickInterval: TimeInterval = 30 * 60

    /// A section-wide silence longer than this collapses.
    static let collapseThreshold: TimeInterval = 60 * 60

    /// How much real time stays to scale around now, even with nothing on:
    /// the now line needs somewhere to sit, and the channel a cell to tune.
    static let nowZoneLength: TimeInterval = 60 * 60

    /// A grid for `window`. It starts on the half hour at or before the
    /// window, so the ruler opens on a round time and the programme on now
    /// (which began earlier) shows as clipped rather than as a gap.
    init(window: LiveTVGuideWindow, pointsPerMinute: CGFloat) {
        let start = Self.floorToTick(window.start)
        self.start = start
        self.end = max(window.end, start.addingTimeInterval(Self.tickInterval))
        self.pointsPerMinute = pointsPerMinute
        self.collapses = []
        self.collapsedWidth = 0
    }

    /// A grid for `window` with the empty stretches of `lineup` collapsed.
    /// `collapsesTrailingGap` is off when the window's end is only padding
    /// (nothing is known past it, so a marker would point at nothing).
    init(
        window: LiveTVGuideWindow,
        lineup: PlexLiveTVLineup,
        now: Date,
        pointsPerMinute: CGFloat,
        collapsedWidth: CGFloat,
        collapsesTrailingGap: Bool = true
    ) {
        let start = Self.floorToTick(window.start)
        let end = max(window.end, start.addingTimeInterval(Self.tickInterval))
        self.start = start
        self.end = end
        self.pointsPerMinute = pointsPerMinute
        self.collapsedWidth = collapsedWidth

        var busy: [(start: Date, end: Date)] = []
        for guide in lineup.guides {
            for program in guide.programs {
                guard let beginsAt = program.beginsAt, let endsAt = program.endsAt,
                      endsAt > start, beginsAt < end else { continue }
                busy.append((max(beginsAt, start), min(endsAt, end)))
            }
        }
        if now >= start, now < end {
            let zone = Self.nowZone(now)
            busy.append((max(zone.lowerBound, start), min(zone.upperBound, end)))
        }
        busy.sort { $0.start < $1.start }

        var collapses: [Collapse] = []
        var cursor = start
        for interval in busy {
            if interval.start.timeIntervalSince(cursor) > Self.collapseThreshold {
                collapses.append(Collapse(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if collapsesTrailingGap, end.timeIntervalSince(cursor) > Self.collapseThreshold {
            collapses.append(Collapse(start: cursor, end: end))
        }
        self.collapses = collapses
    }

    /// The stretch around now that is never collapsed.
    static func nowZone(_ now: Date) -> ClosedRange<Date> {
        let start = floorToTick(now.addingTimeInterval(-nowLeadIn))
        return start...start.addingTimeInterval(nowZoneLength)
    }

    /// What a source whose whole guide is in memory (IPTV) shows: everything
    /// it has, whatever day the Plex section is on, so it scrolls on its own.
    /// With nothing coming up it still runs `openEndLength` past the start of
    /// the now zone, so a channel without a guide has a tunable cell, not a stub.
    static func wholeGuideWindow(of lineup: PlexLiveTVLineup, now: Date) -> LiveTVGuideWindow {
        let zoneStart = nowZone(now).lowerBound
        var start = zoneStart
        var end = zoneStart.addingTimeInterval(openEndLength)
        for guide in lineup.guides {
            for program in guide.programs {
                if let beginsAt = program.beginsAt, beginsAt < start { start = beginsAt }
                if let endsAt = program.endsAt, endsAt > end { end = endsAt }
            }
        }
        return LiveTVGuideWindow(start: start, end: end)
    }

    static let openEndLength: TimeInterval = 3 * 60 * 60

    var width: CGFloat { x(for: end) }

    func x(for date: Date) -> CGFloat {
        var x = CGFloat(date.timeIntervalSince(start) / 60) * pointsPerMinute
        for collapse in collapses {
            guard date > collapse.start else { break }
            let span = collapse.end.timeIntervalSince(collapse.start)
            let saved = CGFloat(span / 60) * pointsPerMinute - collapsedWidth
            if date >= collapse.end {
                x -= saved
            } else {
                // Inside: the marker's width stands for its whole stretch.
                x -= saved * CGFloat(date.timeIntervalSince(collapse.start) / span)
                break
            }
        }
        return x
    }

    func date(forX x: CGFloat) -> Date {
        var edgeX: CGFloat = 0
        var edgeDate = start
        for collapse in collapses {
            let stretch = CGFloat(collapse.start.timeIntervalSince(edgeDate) / 60) * pointsPerMinute
            if x <= edgeX + stretch { break }
            edgeX += stretch
            if x <= edgeX + collapsedWidth {
                let fraction = collapsedWidth > 0 ? TimeInterval((x - edgeX) / collapsedWidth) : 0
                return collapse.start.addingTimeInterval(collapse.end.timeIntervalSince(collapse.start) * fraction)
            }
            edgeX += collapsedWidth
            edgeDate = collapse.end
        }
        return edgeDate.addingTimeInterval(TimeInterval((x - edgeX) / pointsPerMinute) * 60)
    }

    /// One label on the ruler.
    struct Mark: Hashable, Sendable {
        let date: Date
        /// Past a collapsed stretch, across midnight or at the very start the
        /// day may not be the one the viewer assumes, so the label names it.
        let namesDay: Bool
    }

    /// Every half hour to scale, plus the exact start of each stretch that
    /// follows a collapse (programmes rarely resume on the half hour).
    func marks(calendar: Calendar = .current) -> [Mark] {
        var marks: [Mark] = []
        var stretchStart = start
        var followsCollapse = false

        func addStretch(until stretchEnd: Date) {
            var tick = Self.floorToTick(stretchStart)
            if tick < stretchStart { tick = tick.addingTimeInterval(Self.tickInterval) }
            if followsCollapse {
                marks.append(Mark(date: stretchStart, namesDay: true))
                // A half hour right after that label would print over it.
                if tick.timeIntervalSince(stretchStart) < 20 * 60 { tick = tick.addingTimeInterval(Self.tickInterval) }
            }
            while tick < stretchEnd {
                marks.append(Mark(date: tick, namesDay: marks.isEmpty || calendar.startOfDay(for: tick) == tick))
                tick = tick.addingTimeInterval(Self.tickInterval)
            }
        }
        for collapse in collapses {
            addStretch(until: collapse.start)
            stretchStart = collapse.end
            followsCollapse = true
        }
        addStretch(until: end)
        return marks
    }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    static func floorToTick(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / tickInterval).rounded(.down) * tickInterval)
    }

    /// How much of the past stays in view left of the now line when the
    /// guide opens on now.
    static let nowLeadIn: TimeInterval = 10 * 60

    /// The horizontal offset that opens the grid on now: the half hour at
    /// least `nowLeadIn` before it at the leading edge, with the marker of a
    /// collapsed past still peeking in so the way back is visible. 0 when now
    /// is not on this timeline.
    func nowOffset(_ now: Date) -> CGFloat {
        guard contains(now) else { return 0 }
        let leading = Self.floorToTick(now.addingTimeInterval(-Self.nowLeadIn))
        let peek = collapses.contains { $0.end == leading } ? collapsedWidth : 0
        return max(0, x(for: leading) - peek)
    }
}

extension PlexLiveTVLineup {
    /// An airing at least this long is a placeholder, not a programme.
    static let fillerAiringLength: TimeInterval = 12 * 60 * 60

    /// The lineup with its filler airings taken out, so the guide treats
    /// them as the empty time they stand for (and collapses them). Some
    /// tuners (a Threadfin relay, say) cover the time between live events
    /// with a placeholder programme ("No live session") where an IPTV guide
    /// would leave a gap. A title that runs for `fillerAiringLength` or more
    /// at a stretch on a channel is that placeholder; its shorter airings on
    /// the same channel (between two sessions on one day) go too.
    func removingFillerAirings() -> PlexLiveTVLineup {
        PlexLiveTVLineup(provider: provider, guides: guides.map { guide in
            let fillerTitles = Set(guide.programs.compactMap { program -> String? in
                guard let beginsAt = program.beginsAt, let endsAt = program.endsAt,
                      endsAt.timeIntervalSince(beginsAt) >= Self.fillerAiringLength else { return nil }
                return program.title
            })
            guard !fillerTitles.isEmpty else { return guide }
            return PlexLiveChannelGuide(
                channel: guide.channel,
                programs: guide.programs.filter { !fillerTitles.contains($0.title) }
            )
        })
    }
}

/// One cell of a channel row: a programme, the stretch the guide says nothing
/// about, or the marker for a collapsed stretch. Gaps are cells too, so a
/// channel with a patchy (or no) guide still has something to land on and tune.
struct LiveTVGuideCell: Identifiable, Hashable, Sendable {
    let id: String
    let start: Date
    let end: Date
    /// Nil for a gap.
    let program: PlexLiveProgram?

    /// Whether the programme began before the grid does (drawn with a
    /// leading chevron, like a cable guide).
    let startsBeforeTimeline: Bool
    /// An ended programme that can be played back: IPTV catch-up, or a Plex
    /// airing with a recording in the library.
    var isReplayable = false
    /// The marker of a collapsed stretch: narrow, always a nil `program`, and
    /// Select skips across it instead of tuning.
    var isCollapsedGap = false

    func isAiring(at date: Date) -> Bool { start <= date && date < end }

    /// Over by `date`: drawn dimmed, and Select plays it only when
    /// `isReplayable`.
    func hasEnded(at date: Date) -> Bool { end <= date }
}

/// One channel row: the channel, the lineup it belongs to (Plex or one IPTV
/// source: tuning and the in-player channel list stay inside it), and its
/// cells laid edge to edge across the timeline.
struct LiveTVGuideRow: Identifiable, Hashable, Sendable {
    let id: String
    let channel: PlexLiveChannel
    let cells: [LiveTVGuideCell]

    /// The cell on at `date`, else the first after it, else the last. What a
    /// row highlights when focus arrives at a given time position.
    func cell(at date: Date) -> LiveTVGuideCell? {
        cells.first { $0.isAiring(at: date) }
            ?? cells.first { $0.start >= date }
            ?? cells.last
    }

    func index(of cell: LiveTVGuideCell) -> Int? {
        cells.firstIndex { $0.id == cell.id }
    }
}

/// A block of rows from one lineup. More than one section means Plex plus
/// IPTV sources (or several IPTV sources); each gets a slim label row, its own
/// time axis and its own horizontal scroll.
struct LiveTVGuideSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let lineup: PlexLiveTVLineup
    let timeline: LiveTVGuideTimeline
    let rows: [LiveTVGuideRow]

    init(
        id: String,
        title: String,
        lineup: PlexLiveTVLineup,
        timeline: LiveTVGuideTimeline,
        now: Date,
        isReplayable: (PlexLiveProgram, PlexLiveChannel) -> Bool = { _, _ in false }
    ) {
        self.id = id
        self.title = title
        self.lineup = lineup
        self.timeline = timeline
        self.rows = lineup.guides.map { guide in
            LiveTVGuideRow(
                id: "\(id)/\(guide.channel.id)",
                channel: guide.channel,
                cells: Self.cells(
                    for: guide,
                    rowID: "\(id)/\(guide.channel.id)",
                    timeline: timeline,
                    now: now,
                    isReplayable: isReplayable
                )
            )
        }
    }

    /// Programmes clipped to the timeline, with gaps (and overlaps, which
    /// sloppy XMLTV files do have) resolved so the row tiles exactly. A gap
    /// that is already over stays blank: Plex drops ended airings, and a
    /// "no information" cell for the last twenty minutes says nothing. A
    /// collapsed stretch always gets its marker, past or not: it is the way
    /// through to the catch-up on the other side.
    static func cells(
        for guide: PlexLiveChannelGuide,
        rowID: String,
        timeline: LiveTVGuideTimeline,
        now: Date,
        isReplayable: (PlexLiveProgram, PlexLiveChannel) -> Bool = { _, _ in false }
    ) -> [LiveTVGuideCell] {
        var cells: [LiveTVGuideCell] = []
        var cursor = timeline.start

        func toScaleGap(until end: Date) {
            guard end.timeIntervalSince(cursor) >= 60 else { return }
            guard end > now else {
                cursor = end
                return
            }
            func append(until cellEnd: Date) {
                cells.append(LiveTVGuideCell(
                    id: "\(rowID)/gap-\(Int(cursor.timeIntervalSince1970))",
                    start: cursor,
                    end: cellEnd,
                    program: nil,
                    startsBeforeTimeline: false
                ))
                cursor = cellEnd
            }
            // What tunes the channel stays the size of the now zone: a channel
            // without a guide must not turn into a screens-long "No Program
            // Information". The rest of the stretch is a quiet gap.
            if cursor <= now {
                let zone = LiveTVGuideTimeline.nowZone(now)
                cursor = max(cursor, zone.lowerBound)
                if end > zone.upperBound { append(until: zone.upperBound) }
            }
            append(until: end)
        }

        func gap(until end: Date) {
            for collapse in timeline.collapses where collapse.end > cursor && collapse.start < end {
                toScaleGap(until: collapse.start)
                cells.append(LiveTVGuideCell(
                    id: "\(rowID)/collapsed-\(Int(collapse.start.timeIntervalSince1970))",
                    start: collapse.start,
                    end: collapse.end,
                    program: nil,
                    startsBeforeTimeline: false,
                    isCollapsedGap: true
                ))
                cursor = collapse.end
            }
            toScaleGap(until: end)
        }

        for program in guide.programs {
            guard let beginsAt = program.beginsAt, let endsAt = program.endsAt else { continue }
            let start = max(beginsAt, cursor)
            let end = min(endsAt, timeline.end)
            guard end.timeIntervalSince(start) >= 60 else { continue }
            gap(until: start)
            cells.append(LiveTVGuideCell(
                id: "\(rowID)/\(program.id)",
                start: start,
                end: end,
                program: program,
                startsBeforeTimeline: beginsAt < timeline.start,
                isReplayable: endsAt <= now && isReplayable(program, guide.channel)
            ))
            cursor = end
        }
        gap(until: timeline.end)
        return cells
    }
}

/// Where the tvOS grid is: which row has focus is the focus engine's; the
/// time position and the horizontal scroll are the app's, so moving between
/// channels keeps the time a viewer was looking at (the focus engine alone
/// would jump to whichever programme's centre is nearest).
struct LiveTVGuideCursor: Equatable {
    /// The time the highlighted programme is picked at in every row.
    var time: Date
    /// Leading edge of the visible timeline, in timeline points.
    var offset: CGFloat = 0
    /// A placement waiting for the grid (which knows the timeline and the
    /// viewport) to apply it: opening on now, or landing on a time after
    /// Left/Right crossed into another day.
    var pending: Placement? = .now

    enum Step: Equatable { case previous, next }

    enum Placement: Equatable {
        case now
        /// The cell at `date`, entered by stepping in `step`'s direction.
        case time(Date, Step)
        /// The cell at `date` near the leading edge: a day picked from the
        /// menu, on a section that has its whole guide on one axis.
        case day(Date)
    }

    /// How much of a block a step keeps in view, as a share of the viewport.
    /// Longer programmes only show this much (the title sticks to the visible
    /// edge), so a step never throws the grid across the screen.
    static let comfortableShare: CGFloat = 0.35
    /// The breathing room kept past the block, as a share of the viewport.
    static let marginShare: CGFloat = 0.06

    /// Moves to the neighbouring cell of `row`, scrolling just enough to keep
    /// it comfortably in view. Returns false at either end.
    mutating func step(
        _ step: Step,
        in row: LiveTVGuideRow,
        timeline: LiveTVGuideTimeline,
        viewport: CGFloat
    ) -> Bool {
        guard let current = row.cell(at: time), let index = row.index(of: current) else { return false }
        let target = step == .next ? index + 1 : index - 1
        guard row.cells.indices.contains(target) else { return false }
        reveal(row.cells[target], timeline: timeline, viewport: viewport)
        return true
    }

    /// Scrolls as little as keeps `cell` comfortably visible, then parks the
    /// time position at its start (or the visible edge, for a programme that
    /// began off screen).
    mutating func reveal(_ cell: LiveTVGuideCell, timeline: LiveTVGuideTimeline, viewport: CGFloat) {
        let x0 = timeline.x(for: cell.start)
        let x1 = timeline.x(for: cell.end)
        let shown = min(x1 - x0, viewport * Self.comfortableShare)
        let margin = viewport * Self.marginShare
        var target = offset
        if x0 + shown + margin > offset + viewport {
            target = x0 + shown + margin - viewport
        } else if x1 - shown - margin < offset {
            target = x1 - shown - margin
        }
        offset = min(max(0, target), max(0, timeline.width - viewport))
        time = max(cell.start, timeline.date(forX: offset))
    }

    /// Puts the cell of `row` at `date` near the leading edge.
    mutating func place(at date: Date, in row: LiveTVGuideRow, timeline: LiveTVGuideTimeline, viewport: CGFloat) {
        guard let cell = row.cell(at: date) else { return }
        let x = timeline.x(for: max(cell.start, min(date, cell.end)))
        offset = min(max(0, x - viewport * Self.marginShare), max(0, timeline.width - viewport))
        time = max(cell.start, timeline.date(forX: offset))
    }

    /// The time a step past the first or last cell of `row` lands on: just
    /// before the grid's start, or its end. Where the day before (or after)
    /// picks up.
    static func crossingTime(_ step: Step, in row: LiveTVGuideRow, timeline: LiveTVGuideTimeline) -> Date {
        switch step {
        case .previous:
            return (row.cells.first?.start ?? timeline.start).addingTimeInterval(-1)
        case .next:
            return row.cells.last?.end ?? timeline.end
        }
    }

    /// Lands on the cell of `row` at `date`, scrolled in from the side the
    /// step came from: a step back starts from the end of the grid (so the
    /// cell shows at the trailing edge), a step forward from its start.
    mutating func land(
        at date: Date,
        stepping step: Step,
        in row: LiveTVGuideRow,
        timeline: LiveTVGuideTimeline,
        viewport: CGFloat
    ) {
        guard let cell = row.cell(at: date) else {
            jumpToNow(date, timeline: timeline, viewport: viewport)
            return
        }
        offset = step == .previous ? max(0, timeline.width - viewport) : 0
        reveal(cell, timeline: timeline, viewport: viewport)
    }

    /// Opens on now (the now line just right of the leading edge), or on the
    /// start of a grid that does not contain now (another day).
    mutating func jumpToNow(_ now: Date, timeline: LiveTVGuideTimeline, viewport: CGFloat? = nil) {
        if timeline.contains(now) {
            let maxOffset = viewport.map { max(0, timeline.width - $0) } ?? .greatestFiniteMagnitude
            offset = min(timeline.nowOffset(now), maxOffset)
            time = now
        } else {
            offset = 0
            time = timeline.start
        }
    }

    /// Keeps the same moment at the leading edge when the timeline's start
    /// moves (the "Now" grid rolls forward every half hour, or reaches back
    /// further once older guide data arrives).
    mutating func follow(from old: LiveTVGuideTimeline, to new: LiveTVGuideTimeline, viewport: CGFloat) {
        let leading = old.date(forX: offset)
        offset = min(max(0, new.x(for: leading)), max(0, new.width - viewport))
        if !new.contains(time) { time = max(min(time, new.end), new.start) }
    }
}
