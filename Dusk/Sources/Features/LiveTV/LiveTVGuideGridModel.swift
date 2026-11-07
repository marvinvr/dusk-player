import Foundation

/// The shared time axis of the grid guide: one start, one scale, so every
/// channel row lines up under the same ruler. Pure layout math, no view code.
struct LiveTVGuideTimeline: Hashable, Sendable {
    let start: Date
    let end: Date
    /// Horizontal points per minute of airtime.
    let pointsPerMinute: CGFloat

    /// The ruler ticks every half hour.
    static let tickInterval: TimeInterval = 30 * 60

    /// A grid for `window`. It starts on the half hour at or before the
    /// window, so the ruler opens on a round time and the programme on now
    /// (which began earlier) shows as clipped rather than as a gap.
    init(window: LiveTVGuideWindow, pointsPerMinute: CGFloat) {
        let start = Self.floorToTick(window.start)
        self.start = start
        self.end = max(window.end, start.addingTimeInterval(Self.tickInterval))
        self.pointsPerMinute = pointsPerMinute
    }

    var width: CGFloat { x(for: end) }

    func x(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / 60) * pointsPerMinute
    }

    func date(forX x: CGFloat) -> Date {
        start.addingTimeInterval(TimeInterval(x / pointsPerMinute) * 60)
    }

    /// Every half hour from the start up to (not including) the end.
    var ticks: [Date] {
        stride(from: 0, to: end.timeIntervalSince(start), by: Self.tickInterval)
            .map { start.addingTimeInterval($0) }
    }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    static func floorToTick(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / tickInterval).rounded(.down) * tickInterval)
    }

    /// The horizontal offset that puts the half hour at or before `x` at the
    /// leading edge, so a scroll the app makes always lands on a ruler tick.
    func snappedOffset(atOrBefore x: CGFloat) -> CGFloat {
        let tick = CGFloat(Self.tickInterval / 60) * pointsPerMinute
        return (x / tick).rounded(.down) * tick
    }

    func snappedOffset(atOrAfter x: CGFloat) -> CGFloat {
        let tick = CGFloat(Self.tickInterval / 60) * pointsPerMinute
        return (x / tick).rounded(.up) * tick
    }

    /// How much of the past stays in view left of the now line when the
    /// guide opens on now.
    static let nowLeadIn: TimeInterval = 10 * 60

    /// The horizontal offset that opens the grid on now: the half hour at
    /// least `nowLeadIn` before it at the leading edge. 0 when now is not on
    /// this timeline. The past before it is reached by scrolling back.
    func nowOffset(_ now: Date) -> CGFloat {
        guard contains(now) else { return 0 }
        return max(0, snappedOffset(atOrBefore: x(for: now.addingTimeInterval(-Self.nowLeadIn))))
    }
}

/// One cell of a channel row: a programme, or the stretch the guide says
/// nothing about. Gaps are cells too, so a channel with a patchy (or no)
/// guide still has something to land on and tune.
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
/// IPTV sources (or several IPTV sources); each gets a slim label row.
struct LiveTVGuideSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let lineup: PlexLiveTVLineup
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
    /// "no information" cell for the last twenty minutes says nothing.
    static func cells(
        for guide: PlexLiveChannelGuide,
        rowID: String,
        timeline: LiveTVGuideTimeline,
        now: Date,
        isReplayable: (PlexLiveProgram, PlexLiveChannel) -> Bool = { _, _ in false }
    ) -> [LiveTVGuideCell] {
        var cells: [LiveTVGuideCell] = []
        var cursor = timeline.start

        func gap(until end: Date) {
            guard end.timeIntervalSince(cursor) >= 60 else { return }
            guard end > now else {
                cursor = end
                return
            }
            cells.append(LiveTVGuideCell(
                id: "\(rowID)/gap-\(Int(cursor.timeIntervalSince1970))",
                start: cursor,
                end: end,
                program: nil,
                startsBeforeTimeline: false
            ))
            cursor = end
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
    }

    /// Moves to the neighbouring cell of `row`, scrolling just enough (in
    /// half-hour steps) to show it whole. Returns false at either end.
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

    /// Scrolls so `cell` is visible, then parks the time position at its
    /// start (or the visible edge, for a programme that began off screen).
    mutating func reveal(_ cell: LiveTVGuideCell, timeline: LiveTVGuideTimeline, viewport: CGFloat) {
        let x0 = timeline.x(for: cell.start)
        let x1 = timeline.x(for: cell.end)
        let maxOffset = max(0, timeline.width - viewport)
        if x0 < offset || x1 > offset + viewport {
            let fitting = timeline.snappedOffset(atOrAfter: x1 - viewport)
            let leading = timeline.snappedOffset(atOrBefore: x0)
            offset = min(max(0, min(fitting, leading)), maxOffset)
        }
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
