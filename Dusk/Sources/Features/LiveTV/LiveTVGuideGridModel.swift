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

    func isAiring(at date: Date) -> Bool { start <= date && date < end }
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

    init(id: String, title: String, lineup: PlexLiveTVLineup, timeline: LiveTVGuideTimeline, now: Date) {
        self.id = id
        self.title = title
        self.lineup = lineup
        self.rows = lineup.guides.map { guide in
            LiveTVGuideRow(
                id: "\(id)/\(guide.channel.id)",
                channel: guide.channel,
                cells: Self.cells(for: guide, rowID: "\(id)/\(guide.channel.id)", timeline: timeline, now: now)
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
        now: Date
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
                startsBeforeTimeline: beginsAt < timeline.start
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

    enum Step { case previous, next }

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

    /// Back to the start of the grid with the time position on now.
    mutating func jumpToNow(_ now: Date, timeline: LiveTVGuideTimeline) {
        offset = 0
        time = max(now, timeline.start)
    }
}
