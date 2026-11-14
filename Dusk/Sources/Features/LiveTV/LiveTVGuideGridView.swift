import SwiftUI

/// Sizes for the grid guide. One shared scale per layout so every row lines
/// up; the numbers are picked so iPhone portrait shows about 80 minutes,
/// landscape/iPad about 2½ hours and the TV close to 3.
struct LiveTVGuideMetrics {
    let channelWidth: CGFloat
    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    let rulerHeight: CGFloat
    let pointsPerMinute: CGFloat
    let blockGap: CGFloat
    let cornerRadius: CGFloat
    /// How wide a collapsed stretch of the timeline is drawn.
    let collapsedGapWidth: CGFloat
    /// Channel name beside the logo (wide layouts) or logo + number only.
    let showsChannelName: Bool

    #if os(tvOS)
    static let tv = LiveTVGuideMetrics(
        channelWidth: 330, rowHeight: 104, rowSpacing: 10, rulerHeight: 64,
        pointsPerMinute: 9, blockGap: 8, cornerRadius: 16, collapsedGapWidth: 136, showsChannelName: true
    )
    #else
    static func forWidth(_ width: CGFloat) -> LiveTVGuideMetrics {
        if width >= 900 {
            // iPad
            return LiveTVGuideMetrics(
                channelWidth: 190, rowHeight: 72, rowSpacing: 0, rulerHeight: 38,
                pointsPerMinute: 6, blockGap: 3, cornerRadius: 12, collapsedGapWidth: 76, showsChannelName: true
            )
        }
        if width >= 600 {
            // iPhone landscape
            return LiveTVGuideMetrics(
                channelWidth: 160, rowHeight: 62, rowSpacing: 0, rulerHeight: 34,
                pointsPerMinute: 4.6, blockGap: 3, cornerRadius: 10, collapsedGapWidth: 68, showsChannelName: true
            )
        }
        return LiveTVGuideMetrics(
            channelWidth: 74, rowHeight: 66, rowSpacing: 0, rulerHeight: 34,
            pointsPerMinute: 3.8, blockGap: 3, cornerRadius: 10, collapsedGapWidth: 64, showsChannelName: false
        )
    }
    #endif
}

// MARK: - Shared pieces

/// One programme (or guide gap) as a block whose width is its airtime.
struct LiveTVGuideBlock: View {
    let cell: LiveTVGuideCell
    let now: Date
    let metrics: LiveTVGuideMetrics
    /// How far into the block now is, in points; 0 unless it is on now.
    var elapsedWidth: CGFloat = 0
    /// tvOS: the highlighted programme of the focused row.
    var isHighlighted = false
    /// tvOS: how far the block runs off the visible leading edge; the title
    /// slides in by that much so it stays readable (a "sticky" title).
    var stickyInset: CGFloat = 0
    /// iOS: the pinned channel column's width. The title keeps clear of it
    /// while the block scrolls underneath (applied at render time).
    var pinnedColumnWidth: CGFloat = 0

    private var isLive: Bool { cell.isAiring(at: now) }
    /// Over and not highlighted: drawn receded, the way the past reads in a
    /// cable guide. A replayable one keeps more of its contrast.
    private var isDimmedPast: Bool { cell.hasEnded(at: now) && !isHighlighted }

    var body: some View {
        label
            #if os(tvOS)
            // Padding, not an offset, so the title still truncates with an
            // ellipsis inside what is left of the block.
            .padding(.leading, stickyInset)
            #else
            .visualEffect { [pinnedColumnWidth] content, proxy in
                let minX = proxy.frame(in: .scrollView(axis: .horizontal)).minX
                let hidden = pinnedColumnWidth - minX
                let shift = min(max(hidden, 0), max(proxy.size.width - 96, 0))
                // A sliver too narrow to carry its title stays blank rather
                // than showing the middle of a word.
                return content.offset(x: shift).opacity(hidden > proxy.size.width - 96 && hidden > 0 ? 0 : 1)
            }
            #endif
            .clipShape(shape)
            .background {
                fill.overlay(alignment: .leading) {
                    // What has aired of the live programme, ending on the now line.
                    (isHighlighted ? Color.duskBackground.opacity(0.1) : Color.duskTextPrimary.opacity(0.09))
                        .frame(width: max(elapsedWidth, 0))
                }
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(Color.duskTextPrimary.opacity(isHighlighted ? 0 : 0.06), lineWidth: 1)
            }
            .contentShape(shape)
            #if os(tvOS)
            .shadow(color: .black.opacity(isHighlighted ? 0.45 : 0), radius: 18, y: 8)
            #endif
    }

    @ViewBuilder
    private var label: some View {
        if cell.isCollapsedGap {
            gapMarker
        } else if cell.program == nil, !isLive {
            // A short stretch with nothing listed: no words, nothing to do.
            ellipsis
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            programLabel
        }
    }

    /// The marker of a collapsed stretch: "···" and how much time it skips.
    private var gapMarker: some View {
        VStack(spacing: 2) {
            ellipsis
            if let span = LiveTVGuideCell.spanLabel(from: cell.start, to: cell.end) {
                Text(span)
                    .font(DuskFont.cardSubtitle(ios: .caption2).monospacedDigit())
                    .foregroundStyle(secondaryStyle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ellipsis: some View {
        Image(systemName: "ellipsis")
            .font(DuskFont.glyphSmall(ios: .caption.weight(.semibold)))
            .foregroundStyle(secondaryStyle)
    }

    private var programLabel: some View {
        HStack(spacing: 4) {
            if cell.startsBeforeTimeline || stickyInset > 0 {
                Image(systemName: "chevron.left")
                    .font(DuskFont.glyphSmall(ios: .caption2.weight(.semibold)))
                    .foregroundStyle(secondaryStyle)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: replayGlyphSpacing) {
                    if cell.isReplayable {
                        // The only mark a playable past programme gets.
                        Image(systemName: "play.fill")
                            .font(DuskFont.glyphSmall(ios: .caption2.weight(.semibold)))
                            .foregroundStyle(secondaryStyle)
                            .accessibilityLabel("Available to watch")
                    }
                    Text(title)
                        .font(DuskFont.cardTitle(ios: .subheadline.weight(.semibold)))
                        .foregroundStyle(primaryStyle)
                        .lineLimit(1)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(DuskFont.cardSubtitle(ios: .caption))
                        .foregroundStyle(secondaryStyle)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    }

    private var title: String {
        cell.program?.primaryDisplayTitle ?? "No Program Information"
    }

    /// The episode when a series leads, else the airtime. Hidden while the
    /// block is too narrow for a second readable line.
    private var subtitle: String? {
        if let episode = cell.program?.episodeDisplayTitle { return episode }
        guard let program = cell.program, let beginsAt = program.beginsAt, let endsAt = program.endsAt else {
            return cell.program == nil ? "Watch live" : nil
        }
        return "\(beginsAt.formatted(date: .omitted, time: .shortened)) – \(endsAt.formatted(date: .omitted, time: .shortened))"
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        18
        #else
        8
        #endif
    }

    private var replayGlyphSpacing: CGFloat {
        #if os(tvOS)
        10
        #else
        4
        #endif
    }

    /// Neutral fills only (STYLE.md): what is on now reads a step lighter than
    /// what comes later; the tvOS highlight is the inverted primary fill, the
    /// same as a focused tvOS platter.
    /// Always opaque: the now line runs behind the blocks.
    @ViewBuilder
    private var fill: some View {
        if isHighlighted {
            Color.duskTextPrimary
        } else if cell.isCollapsedGap {
            Color.duskBackground.overlay(Color.duskSurface.opacity(0.35))
        } else if isDimmedPast {
            Color.duskBackground.overlay(Color.duskSurface.opacity(cell.isReplayable ? 0.75 : 0.5))
        } else if isLive {
            #if os(macOS)
            // One surface for what is on and what comes next; "now" is the
            // elapsed shading and the now line, not a second fill.
            Color.duskSurface
            #else
            Color.duskBackground.overlay(Color.duskTextPrimary.opacity(0.1))
            #endif
        } else if cell.program == nil {
            Color.duskBackground.overlay(Color.duskSurface.opacity(0.6))
        } else {
            Color.duskSurface
        }
    }

    private var primaryStyle: Color {
        if isHighlighted { return Color.duskBackground }
        if isDimmedPast { return Color.duskTextPrimary.opacity(cell.isReplayable ? 0.78 : 0.5) }
        return Color.duskTextPrimary
    }

    private var secondaryStyle: Color {
        if isHighlighted { return Color.duskBackground.opacity(0.7) }
        if isDimmedPast { return Color.duskTextSecondary.opacity(cell.isReplayable ? 0.9 : 0.6) }
        return Color.duskTextSecondary
    }
}

extension LiveTVGuideCell {
    private static let spanFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    /// "3d 21h": how long a collapsed stretch really is.
    @MainActor
    static func spanLabel(from start: Date, to end: Date) -> String? {
        spanFormatter.string(from: start, to: end)
    }
}

/// The pinned leading cell: logo, plus number and name when there is room.
struct LiveTVGuideChannelCell: View {
    let channel: PlexLiveChannel
    let logoURL: URL?
    let metrics: LiveTVGuideMetrics
    var isFocusedRow = false

    var body: some View {
        Group {
            if metrics.showsChannelName {
                HStack(spacing: logoSpacing) {
                    logoTile
                    VStack(alignment: .leading, spacing: 1) {
                        Text(channel.displayTitle)
                            .font(DuskFont.cardTitle(ios: .footnote.weight(.semibold)))
                            .foregroundStyle(isFocusedRow ? Color.duskTextPrimary : Color.duskTextPrimary.opacity(0.88))
                            .lineLimit(1)
                        if let number = channel.displayNumber {
                            Text(number)
                                .font(DuskFont.cardSubtitle(ios: .caption2).monospacedDigit())
                                .foregroundStyle(Color.duskTextSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 3) {
                    logoTile
                    if let number = channel.displayNumber {
                        Text(number)
                            .font(DuskFont.cardSubtitle(ios: .caption2.weight(.medium)).monospacedDigit())
                            .foregroundStyle(Color.duskTextSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(width: metrics.channelWidth, height: metrics.rowHeight)
    }

    private var logoSize: CGSize {
        #if os(tvOS)
        CGSize(width: 120, height: 68)
        #else
        metrics.showsChannelName ? CGSize(width: 56, height: 34) : CGSize(width: 56, height: 32)
        #endif
    }

    private var logoSpacing: CGFloat {
        #if os(tvOS)
        20
        #else
        10
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        0
        #else
        metrics.showsChannelName ? 12 : 4
        #endif
    }

    /// Channel logos are mostly drawn for dark backgrounds (white on
    /// transparent), so they sit on a small dark tile in both appearances.
    private var logoTile: some View {
        logo
            .padding(.horizontal, logoInset)
            .padding(.vertical, logoInset * 0.6)
            .frame(width: logoSize.width, height: logoSize.height)
            .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: logoInset * 1.5, style: .continuous))
            .environment(\.colorScheme, .dark)
    }

    private var logoInset: CGFloat {
        #if os(tvOS)
        10
        #else
        5
        #endif
    }

    @ViewBuilder
    private var logo: some View {
        if let logoURL {
            DuskAsyncImage(url: logoURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        #if os(macOS)
        if metrics.showsChannelName, channel.displayNumber != nil {
            // The number is already written under the name beside the tile.
            Image(systemName: "tv")
                .font(.body)
                .foregroundStyle(Color.duskTextSecondary)
                .accessibilityHidden(true)
        } else {
            placeholderText
        }
        #else
        placeholderText
        #endif
    }

    private var placeholderText: some View {
        Text(channel.displayNumber ?? String(channel.displayTitle.prefix(3)))
            .font(DuskFont.cardTitle(ios: .caption.weight(.bold)))
            .foregroundStyle(Color.duskTextSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// Half-hour labels across the timeline, a "···" over each collapsed stretch,
/// and the current time as a pill on the now line. Neutral: the pill is the
/// inverted primary fill.
struct LiveTVGuideRuler: View {
    let timeline: LiveTVGuideTimeline
    let now: Date
    let metrics: LiveTVGuideMetrics
    /// iOS: the pinned corner's width; labels under it fade out.
    var pinnedColumnWidth: CGFloat = 0
    /// The stretch of the axis worth drawing, in timeline points. A source's
    /// whole week of half hours would otherwise all be laid out, off screen.
    var visibleRange: ClosedRange<CGFloat>?

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(visibleMarks, id: \.self) { mark in
                HStack(spacing: tickSpacing) {
                    Rectangle()
                        .fill(Color.duskTextSecondary.opacity(0.5))
                        .frame(width: 1, height: tickHeight)
                    Text(label(for: mark))
                        .font(DuskFont.metadata(ios: .caption.weight(.medium)).monospacedDigit())
                        .foregroundStyle(Color.duskTextSecondary)
                        .fixedSize()
                        #if !os(macOS)
                        // The now pill covers this stretch; two times on top
                        // of each other read as neither.
                        .opacity(isCoveredByNowPill(mark) ? 0 : 1)
                        #endif
                }
                #if os(macOS)
                // The tick goes with its label: a bare tick beside the pill
                // reads as a stray line.
                .opacity(isCoveredByNowPill(mark) ? 0 : 1)
                #endif
                .offset(x: timeline.x(for: mark.date))
                #if !os(tvOS)
                .visualEffect { [pinnedColumnWidth, x = timeline.x(for: mark.date)] content, proxy in
                    // A label sliding under the pinned corner would read
                    // as the wrong time ("8:00" for 18:00). The frame here
                    // is the one before `offset`, hence `+ x`.
                    let minX = proxy.frame(in: .scrollView(axis: .horizontal)).minX + x
                    return content.opacity(minX < pinnedColumnWidth ? 0 : 1)
                }
                #endif
            }

            ForEach(timeline.collapses, id: \.self) { collapse in
                Image(systemName: "ellipsis")
                    .font(DuskFont.glyphSmall(ios: .caption2.weight(.semibold)))
                    .foregroundStyle(Color.duskTextSecondary)
                    .frame(width: timeline.collapsedWidth)
                    .offset(x: timeline.x(for: collapse.start))
            }

            if timeline.contains(now) {
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(DuskFont.badge(ios: .caption2.weight(.bold)).monospacedDigit())
                    .foregroundStyle(Color.duskBackground)
                    .padding(.horizontal, pillPadding)
                    .padding(.vertical, pillPadding / 2.5)
                    .background(Color.duskTextPrimary, in: Capsule())
                    .fixedSize()
                    // Centred on the now line by a zero-width frame. A leading
                    // alignment guide at half the pill's width pushed the
                    // ZStack's leading edge out by that much, which shifted the
                    // whole ruler (ticks and pill) right of the grid below.
                    .frame(width: 0)
                    .offset(x: timeline.x(for: now))
            }
        }
        .frame(width: timeline.width, height: metrics.rulerHeight, alignment: .leading)
    }

    private func isCoveredByNowPill(_ mark: LiveTVGuideTimeline.Mark) -> Bool {
        guard timeline.contains(now) else { return false }
        #if os(macOS)
        // By distance on the axis: the centred pill is about 50pt wide, a
        // tick and its "18:30" about 45pt, plus a little air either side.
        let distance = timeline.x(for: now) - timeline.x(for: mark.date)
        return distance > -32 && distance < 76
        #else
        return abs(now.timeIntervalSince(mark.date) - 6 * 60) < 13 * 60
        #endif
    }

    private var visibleMarks: [LiveTVGuideTimeline.Mark] {
        let marks = timeline.marks()
        guard let visibleRange else { return marks }
        return marks.filter { visibleRange.contains(timeline.x(for: $0.date)) }
    }

    /// Today needs no name, whatever the mark says.
    private func label(for mark: LiveTVGuideTimeline.Mark) -> String {
        let time = mark.date.formatted(date: .omitted, time: .shortened)
        guard mark.namesDay, !Calendar.current.isDate(mark.date, inSameDayAs: now) else { return time }
        return "\(LiveTVGuideDayName.short(mark.date, now: now)) \(time)"
    }

    private var tickSpacing: CGFloat {
        #if os(tvOS)
        10
        #else
        5
        #endif
    }

    private var tickHeight: CGFloat {
        #if os(tvOS)
        22
        #else
        12
        #endif
    }

    private var pillPadding: CGFloat {
        #if os(tvOS)
        12
        #else
        7
        #endif
    }
}

/// The cells of one row placed on the timeline, plus the now line.
struct LiveTVGuideRowStrip<Block: View>: View {
    let row: LiveTVGuideRow
    let timeline: LiveTVGuideTimeline
    let now: Date
    let metrics: LiveTVGuideMetrics
    /// The stretch of the axis worth drawing, in timeline points.
    var visibleRange: ClosedRange<CGFloat>?
    /// The block for a cell, given how far into it (in points) now is.
    @ViewBuilder let block: (LiveTVGuideCell, CGFloat) -> Block

    var body: some View {
        ZStack(alignment: .leading) {
            // Behind the blocks: it shows in the gaps between rows and
            // blocks and never runs through a title. Inside the live blocks
            // the elapsed fill ends on the same x, so the line still reads
            // as one continuous "now".
            if timeline.contains(now) {
                Rectangle()
                    .fill(Color.duskTextPrimary.opacity(0.9))
                    .frame(width: nowLineWidth, height: metrics.rowHeight + metrics.rowSpacing)
                    .offset(x: timeline.x(for: now) - nowLineWidth / 2)
                    .allowsHitTesting(false)
            }

            ForEach(visibleCells) { cell in
                let x0 = timeline.x(for: cell.start) + metrics.blockGap / 2
                let width = max(timeline.x(for: cell.end) - metrics.blockGap / 2 - x0, 2)
                block(cell, cell.isAiring(at: now) ? timeline.x(for: now) - x0 : 0)
                    .frame(width: width, height: metrics.rowHeight - metrics.blockGap)
                    .offset(x: x0)
            }
        }
        .frame(width: timeline.width, height: metrics.rowHeight, alignment: .leading)
    }

    private var visibleCells: [LiveTVGuideCell] {
        guard let visibleRange else { return row.cells }
        return row.cells.filter {
            timeline.x(for: $0.end) >= visibleRange.lowerBound && timeline.x(for: $0.start) <= visibleRange.upperBound
        }
    }

    private var nowLineWidth: CGFloat {
        #if os(tvOS)
        3
        #else
        1.5
        #endif
    }
}

/// A slim label above each source's channels when there is more than one
/// (Plex plus IPTV sources).
struct LiveTVGuideSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DuskFont.groupHeader(ios: .footnote.weight(.semibold)))
            .foregroundStyle(Color.duskTextSecondary)
            .textCase(.uppercase)
            .lineLimit(1)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - iOS / iPadOS

#if !os(tvOS)
/// Scrolls every section to the same place: now, or a day from the menu.
struct LiveTVGuideJump: Equatable {
    var id = 0
    /// Nil for now. Only sections with their whole guide on one axis (IPTV)
    /// use it; the Plex grid is the picked day already.
    var day: Date?
}

/// A vertical scroll view of sections, each with its own horizontal scroll
/// view, ruler and time axis, so moving through one source leaves the others
/// where they are. The channel column pins itself against horizontal scrolling
/// and the ruler against vertical scrolling with `visualEffect` (applied at
/// render time, so neither lags the scroll).
struct LiveTVGuideGrid: View {
    let width: CGFloat
    let sections: [LiveTVGuideSection]
    let now: Date
    let metrics: LiveTVGuideMetrics
    let imageURL: (PlexLiveTVLineup) -> (String?, Int, Int) -> URL?
    let jump: LiveTVGuideJump
    let select: (LiveTVGuideCell, LiveTVGuideRow, PlexLiveTVLineup) -> Void
    let showDetails: (PlexLiveProgram) -> Void
    let playChannel: (PlexLiveChannel, PlexLiveTVLineup) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    if sections.count > 1 {
                        LiveTVGuideSectionLabel(title: section.title)
                            .padding(.leading, 14)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                    }
                    LiveTVGuideSectionScroller(
                        width: width,
                        section: section,
                        now: now,
                        metrics: metrics,
                        imageURL: imageURL(section.lineup),
                        jump: jump,
                        select: select,
                        showDetails: showDetails,
                        playChannel: playChannel
                    )
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(LiveTVGuideShortMomentum())
    }
}

/// A flick travels a fraction of what `UIScrollView` would give it, and never
/// more than a screenful, so the guide stays where the viewer is reading
/// instead of sailing past whole hours (or channels). Drags are untouched: the
/// behaviour only sees where the scroll view would come to rest.
private struct LiveTVGuideShortMomentum: ScrollTargetBehavior {
    /// Points a flick coasts per point/millisecond of velocity (the unit
    /// `TargetContext.velocity` is in, measured): `UIScrollView`'s normal
    /// deceleration rate gives about 499, its `.fast` rate about 99.
    private static let normalCoast: CGFloat = 499
    private static let shortCoast: CGFloat = 120
    private static let maxCoastShare: CGFloat = 0.6

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        if context.axes.contains(.horizontal) {
            target.rect.origin.x = shortened(
                target.rect.minX, from: context.originalTarget.rect.minX, velocity: context.velocity.dx,
                container: context.containerSize.width, content: context.contentSize.width
            )
        }
        if context.axes.contains(.vertical) {
            target.rect.origin.y = shortened(
                target.rect.minY, from: context.originalTarget.rect.minY, velocity: context.velocity.dy,
                container: context.containerSize.height, content: context.contentSize.height
            )
        }
    }

    private func shortened(
        _ target: CGFloat, from origin: CGFloat, velocity: CGFloat, container: CGFloat, content: CGFloat
    ) -> CGFloat {
        let maxTarget = max(content - container, 0)
        // Programmatic scrolls have no velocity, and resting against an end
        // says nothing about where the finger let go.
        guard velocity != 0, target > 0, target < maxTarget else { return target }
        // Where the finger let go, never behind where the gesture began.
        let estimate = target - velocity * Self.normalCoast
        let released = velocity > 0 ? max(estimate, min(origin, target)) : min(estimate, max(origin, target))
        let limit = container * Self.maxCoastShare
        let coast = min(max(velocity * Self.shortCoast, -limit), limit)
        return min(max(released + coast, 0), maxTarget)
    }
}

/// One source's block of the iOS grid: its ruler and rows in one horizontal
/// scroll view of their own.
private struct LiveTVGuideSectionScroller: View {
    let width: CGFloat
    let section: LiveTVGuideSection
    let now: Date
    let metrics: LiveTVGuideMetrics
    let imageURL: (String?, Int, Int) -> URL?
    let jump: LiveTVGuideJump
    let select: (LiveTVGuideCell, LiveTVGuideRow, PlexLiveTVLineup) -> Void
    let showDetails: (PlexLiveProgram) -> Void
    let playChannel: (PlexLiveChannel, PlexLiveTVLineup) -> Void

    @State private var position = ScrollPosition()
    /// Which screenful of the axis is up: drawing is windowed around it, and
    /// only a change of page redraws the section.
    @State private var page = 0
    /// Read when the timeline moves; not state, so a scroll redraws nothing.
    @State private var scroll = ScrollTracker()

    private final class ScrollTracker { var x: CGFloat = 0 }

    private var timeline: LiveTVGuideTimeline { section.timeline }
    private var viewport: CGFloat { max(width - metrics.channelWidth, 1) }

    private var visibleRange: ClosedRange<CGFloat> {
        let lower = CGFloat(page - 1) * viewport
        return lower...(lower + viewport * 4)
    }

    /// Ruler plus rows: how far the ruler can stay pinned inside the section.
    private var contentHeight: CGFloat {
        let rows = CGFloat(section.rows.count)
        return metrics.rulerHeight + rows * metrics.rowHeight + max(rows - 1, 0) * metrics.rowSpacing
    }

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                // Outside the lazy stack, which would drop it once its slot
                // has scrolled away while it is still pinned on screen.
                rulerHeader
                    .pinnedToTopEdge(maxOffset: max(contentHeight - metrics.rulerHeight, 0))
                    .zIndex(2)

                LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(LiveTVGuideShortMomentum())
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
            scroll.x = x
        }
        .onScrollGeometryChange(for: Int.self) { [viewport] geometry in
            Int((geometry.contentOffset.x / viewport).rounded(.down))
        } action: { _, new in
            page = new
        }
        // The guide reaches back into the past now, so it opens on now rather
        // than on its start; the past is a scroll to the left.
        .onAppear { scrollToNow(animated: false) }
        .onChange(of: jump) { _, jump in
            if let day = jump.day {
                scroll(toDay: day)
            } else {
                scrollToNow(animated: true)
            }
        }
        .onChange(of: timeline) { old, new in
            // The axis moves under the viewer (the now zone rolls on, a guide
            // reload): keep the same moment at the leading edge.
            guard old.contains(now), new.contains(now), old != new else { return }
            let x = max(0, new.x(for: old.date(forX: scroll.x)))
            if abs(x - scroll.x) > 0.5 { position.scrollTo(x: x) }
        }
        #if DEBUG
        .task {
            guard let minutes = ScreenshotMode.guideOffsetMinutes else { return }
            try? await Task.sleep(for: .seconds(1))
            position.scrollTo(x: CGFloat(minutes) * metrics.pointsPerMinute)
        }
        #endif
    }

    private func scrollToNow(animated: Bool) {
        let x = timeline.nowOffset(now)
        if animated {
            withAnimation(.smooth) { position.scrollTo(x: x) }
        } else {
            position.scrollTo(x: x)
        }
    }

    private func scroll(toDay day: Date) {
        let x = timeline.x(for: min(max(day, timeline.start), timeline.end))
        withAnimation(.smooth) {
            position.scrollTo(x: min(x, max(timeline.width - viewport, 0)))
        }
    }

    /// Tapping a marker hops to the far side of it: away from now, which is
    /// the only direction it can be headed in.
    private func skip(_ cell: LiveTVGuideCell) {
        let x = cell.start >= now
            ? timeline.x(for: cell.end) - viewport * LiveTVGuideCursor.marginShare
            : timeline.x(for: cell.start) - viewport * (1 - LiveTVGuideCursor.comfortableShare)
        withAnimation(.smooth) {
            position.scrollTo(x: min(max(x, 0), max(timeline.width - viewport, 0)))
        }
    }

    private var rulerHeader: some View {
        HStack(spacing: 0) {
            Color.duskBackground
                .padding(.leading, -Self.safeAreaBleed)
                .frame(width: metrics.channelWidth, height: metrics.rulerHeight)
                .pinnedToLeadingEdge()
                .zIndex(1)
            LiveTVGuideRuler(
                timeline: timeline, now: now, metrics: metrics,
                pinnedColumnWidth: metrics.channelWidth, visibleRange: visibleRange
            )
        }
        .background(Color.duskBackground)
        .overlay(alignment: .bottom) { hairline }
    }

    /// In landscape the scroll view's content starts inside the leading safe
    /// area, so the pinned column sits at that inset and blocks scrolling
    /// past would show beside it; its background reaches back over the gap.
    private static let safeAreaBleed: CGFloat = 120

    private func rowView(_ row: LiveTVGuideRow) -> some View {
        HStack(spacing: 0) {
            Button {
                playChannel(row.channel, section.lineup)
            } label: {
                LiveTVGuideChannelCell(
                    channel: row.channel,
                    logoURL: imageURL(row.channel.thumb, 160, 96),
                    metrics: metrics
                )
                .background(Color.duskBackground.padding(.leading, -Self.safeAreaBleed))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.duskTextPrimary.opacity(0.08)).frame(width: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Watch \(row.channel.displayTitle) live")
            .pinnedToLeadingEdge()
            .zIndex(1)

            LiveTVGuideRowStrip(
                row: row, timeline: timeline, now: now, metrics: metrics, visibleRange: visibleRange
            ) { cell, elapsed in
                Button {
                    if cell.isCollapsedGap {
                        skip(cell)
                    } else {
                        select(cell, row, section.lineup)
                    }
                } label: {
                    LiveTVGuideBlock(
                        cell: cell,
                        now: now,
                        metrics: metrics,
                        elapsedWidth: elapsed,
                        pinnedColumnWidth: metrics.channelWidth
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cell.isCollapsedGap ? "Skip the time without programs" : (cell.program?.primaryDisplayTitle ?? "No program information"))
                .contextMenu {
                    if cell.isAiring(at: now) {
                        Button("Watch Live", systemImage: "play.fill") { select(cell, row, section.lineup) }
                    } else if cell.isReplayable {
                        Button("Play", systemImage: "play.fill") { select(cell, row, section.lineup) }
                    }
                    if let program = cell.program {
                        Button("Details", systemImage: "info.circle") { showDetails(program) }
                    }
                }
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.duskTextPrimary.opacity(0.08)).frame(height: 1)
    }
}

private extension View {
    /// Counter-offsets the view by the horizontal scroll so it stays on the
    /// leading edge (the channel column, the ruler's corner).
    func pinnedToLeadingEdge() -> some View {
        visualEffect { content, proxy in
            content.offset(x: max(0, -proxy.frame(in: .scrollView(axis: .horizontal)).minX))
        }
    }

    /// Counter-offsets the view by the outer vertical scroll so it stays at the
    /// top of the guide while its section is on screen (the ruler). A pinned
    /// section header cannot do this: the rows' horizontal scroll view sits
    /// between it and the vertical one.
    func pinnedToTopEdge(maxOffset: CGFloat) -> some View {
        visualEffect { content, proxy in
            content.offset(y: min(max(0, -proxy.frame(in: .scrollView(axis: .vertical)).minY), maxOffset))
        }
    }
}
#endif

// MARK: - tvOS

#if os(tvOS)
/// The tvOS grid. The focus engine owns which **row** is focused (rows are
/// full-width, so Up/Down is plain native focus movement with native vertical
/// scrolling); the time position and horizontal scroll are app state, one
/// `LiveTVGuideCursor` per section, so Up/Down keeps the time, Left/Right steps
/// through programmes the way a cable guide does, and moving through one source
/// leaves the others where they are. Letting the focus engine pick programmes
/// itself would land on whichever block's centre is nearest and drift a little
/// with every row.
struct LiveTVGuideTVGrid<Corner: View>: View {
    /// The width the grid gets (safe area applied). Measured by the caller:
    /// the grid's own geometry reported the full screen width, so blocks
    /// past the visible edge counted as on screen and Right never scrolled.
    let width: CGFloat
    let sections: [LiveTVGuideSection]
    let now: Date
    let imageURL: (PlexLiveTVLineup) -> (String?, Int, Int) -> URL?
    /// By section id. A section without one yet opens on now.
    @Binding var cursors: [String: LiveTVGuideCursor]
    let select: (LiveTVGuideCell, LiveTVGuideRow, PlexLiveTVLineup) -> Void
    let showDetails: (PlexLiveProgram) -> Void
    /// Back to now.
    let jumpToNow: () -> Void
    /// The focused section, for the day the corner should name.
    @ViewBuilder let corner: (LiveTVGuideSection?, LiveTVGuideCursor?) -> Corner

    @FocusState private var focusedRowID: String?
    /// Where focus re-enters the grid from the tab bar or the corner.
    @State private var lastFocusedRowID: String?

    private let metrics = LiveTVGuideMetrics.tv

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiveTVGuideInfoPanel(
                focus: focusedCell,
                now: now,
                imageURL: focusedRow.map { imageURL($0.section.lineup) }
            )
            .frame(height: 230, alignment: .topLeading)

            HStack(spacing: 0) {
                corner(rulerSection, rulerSection.map(cursor(for:)))
                    .frame(width: metrics.channelWidth, alignment: .leading)
                ruler
            }
            .frame(height: metrics.rulerHeight + 16)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    ForEach(sections) { section in
                        if sections.count > 1 {
                            LiveTVGuideSectionLabel(title: section.title)
                                .padding(.top, section.id == sections.first?.id ? 4 : 22)
                        }
                        let url = imageURL(section.lineup)
                        ForEach(section.rows) { row in
                            rowButton(row, section: section, imageURL: url)
                        }
                    }
                }
                .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .scrollTargetBehavior(LiveTVGuideRowPacing(maxStep: metrics.rowHeight + metrics.rowSpacing))
            .mask(alignment: .top) {
                // The rows end at the ruler; the system clip would cut the
                // highlighted block's shadow.
                Rectangle().padding(.top, -2)
            }
        }
        .focusSection()
        .defaultFocus($focusedRowID, lastFocusedRowID ?? firstRowID)
        .onChange(of: focusedRowID) { _, id in
            if let id { lastFocusedRowID = id }
        }
        .onPlayPauseCommand { jumpToNow() }
        .onChange(of: timelines, initial: true) { old, new in
            for section in sections {
                if cursor(for: section).pending != nil {
                    applyPendingPlacement(in: section)
                } else if let previous = old[section.id], let timeline = new[section.id], previous != timeline,
                          previous.contains(now), timeline.contains(now) {
                    var next = cursor(for: section)
                    next.follow(from: previous, to: timeline, viewport: viewport)
                    cursors[section.id] = next
                }
            }
        }
        .onChange(of: cursors.mapValues(\.pending)) {
            for section in sections { applyPendingPlacement(in: section) }
        }
        #if DEBUG
        .task(id: sections.isEmpty) { await runScreenshotMoves() }
        #endif
    }

    private var timelines: [String: LiveTVGuideTimeline] {
        Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.timeline) })
    }

    private func cursor(for section: LiveTVGuideSection) -> LiveTVGuideCursor {
        cursors[section.id] ?? LiveTVGuideCursor(time: now)
    }

    private var firstRowID: String? { sections.first?.rows.first?.id }

    /// Applies a section's pending placement once the timeline it is meant for
    /// is up: a day switch updates the cursor before the new day's grid exists.
    private func applyPendingPlacement(in section: LiveTVGuideSection) {
        var next = cursor(for: section)
        guard let pending = next.pending else { return }
        let timeline = section.timeline
        let focused = focusedRow?.section.id == section.id ? focusedRow?.row : nil
        switch pending {
        case .now:
            next.jumpToNow(now, timeline: timeline, viewport: viewport)
        case .time(let date, let step):
            guard timeline.contains(date) || date == timeline.end else { return }
            guard let row = focused ?? section.rows.first else { return }
            next.land(at: date, stepping: step, in: row, timeline: timeline, viewport: viewport)
        case .day(let date):
            guard let row = focused ?? section.rows.first else { return }
            next.place(at: date, in: row, timeline: timeline, viewport: viewport)
        }
        next.pending = nil
        withAnimation(.smooth(duration: 0.3)) { cursors[section.id] = next }
    }

    private var viewport: CGFloat { max(width - metrics.channelWidth, 1) }

    /// The focused row, or the last one while focus is briefly elsewhere (the
    /// day menu, a context menu, the details sheet): the info panel keeps
    /// describing what the viewer was on instead of blanking.
    private var focusedRow: (row: LiveTVGuideRow, section: LiveTVGuideSection)? {
        guard let focusedRowID = focusedRowID ?? lastFocusedRowID else { return nil }
        for section in sections {
            if let row = section.rows.first(where: { $0.id == focusedRowID }) { return (row, section) }
        }
        return nil
    }

    private var focusedCell: (row: LiveTVGuideRow, cell: LiveTVGuideCell)? {
        guard let focused = focusedRow,
              let cell = focused.row.cell(at: cursor(for: focused.section).time) else { return nil }
        return (focused.row, cell)
    }

    /// The one ruler follows the section focus is in: only that section's axis
    /// and scroll position are being read.
    private var rulerSection: LiveTVGuideSection? { focusedRow?.section ?? sections.first }

    @ViewBuilder
    private var ruler: some View {
        if let section = rulerSection {
            let offset = cursor(for: section).offset
            LiveTVGuideRuler(
                timeline: section.timeline, now: now, metrics: metrics,
                visibleRange: drawnRange(offset: offset)
            )
            .id(section.id)
            .offset(x: -offset)
            .frame(width: viewport, height: metrics.rulerHeight, alignment: .leading)
            .clipped()
        }
    }

    /// A screenful either side of the view, so the blocks a step brings in
    /// are already there when the slide starts.
    private func drawnRange(offset: CGFloat) -> ClosedRange<CGFloat> {
        (offset - viewport)...(offset + viewport * 2)
    }

    private func rowButton(
        _ row: LiveTVGuideRow,
        section: LiveTVGuideSection,
        imageURL: @escaping (String?, Int, Int) -> URL?
    ) -> some View {
        let cursor = cursor(for: section)
        let timeline = section.timeline
        let highlighted = focusedRowID == row.id ? row.cell(at: cursor.time) : nil
        return Button {
            guard let cell = row.cell(at: cursor.time) else { return }
            if cell.isCollapsedGap {
                // A marker is only a way through: on, away from now.
                step(cell.start >= now ? .next : .previous, in: row, section: section)
            } else {
                select(cell, row, section.lineup)
            }
        } label: {
            HStack(spacing: 0) {
                LiveTVGuideChannelCell(
                    channel: row.channel,
                    logoURL: imageURL(row.channel.thumb, 224, 120),
                    metrics: metrics,
                    isFocusedRow: highlighted != nil
                )
                LiveTVGuideRowStrip(
                    row: row, timeline: timeline, now: now, metrics: metrics,
                    visibleRange: drawnRange(offset: cursor.offset)
                ) { cell, elapsed in
                    LiveTVGuideBlock(
                        cell: cell,
                        now: now,
                        metrics: metrics,
                        elapsedWidth: elapsed,
                        isHighlighted: cell.id == highlighted?.id,
                        stickyInset: stickyInset(for: cell, timeline: timeline, offset: cursor.offset)
                    )
                }
                .offset(x: -cursor.offset)
                .frame(width: viewport, height: metrics.rowHeight, alignment: .leading)
                // Clip only the sides: the highlighted block's shadow may
                // spill into the row gaps.
                .mask(Rectangle().padding(.vertical, -metrics.rowSpacing))
            }
        }
        .buttonStyle(LiveTVGuideRowButtonStyle())
        .focused($focusedRowID, equals: row.id)
        .onMoveCommand { direction in
            switch direction {
            case .left: step(.previous, in: row, section: section)
            case .right: step(.next, in: row, section: section)
            default: break
            }
        }
        .contextMenu {
            if let cell = row.cell(at: cursor.time) {
                Button(cell.isAiring(at: now) ? "Watch Live" : "Watch \(row.channel.displayTitle) Live", systemImage: "play.fill") {
                    select(LiveTVGuideCell(id: cell.id, start: now, end: now, program: nil, startsBeforeTimeline: false), row, section.lineup)
                }
                if cell.isReplayable {
                    Button("Play", systemImage: "play.fill") { select(cell, row, section.lineup) }
                }
                if let program = cell.program {
                    Button("Details", systemImage: "info.circle") { showDetails(program) }
                }
            }
            Button("Jump to Now", systemImage: "clock.arrow.circlepath") { jumpToNow() }
        }
        .accessibilityLabel(accessibilityLabel(row: row, cursor: cursor))
    }

    /// How far `cell` runs off the visible leading edge, capped so a sliver
    /// of a programme never squeezes its title to nothing.
    private func stickyInset(for cell: LiveTVGuideCell, timeline: LiveTVGuideTimeline, offset: CGFloat) -> CGFloat {
        let x0 = timeline.x(for: cell.start) + metrics.blockGap / 2
        let width = timeline.x(for: cell.end) - metrics.blockGap / 2 - x0
        return min(max(offset - x0, 0), max(width - 160, 0))
    }

    /// Every section (Plex and IPTV) has its whole guide on one axis, so a
    /// step past either end just stops.
    private func step(_ step: LiveTVGuideCursor.Step, in row: LiveTVGuideRow, section: LiveTVGuideSection) {
        var next = cursor(for: section)
        guard next.step(step, in: row, timeline: section.timeline, viewport: viewport) else { return }
        withAnimation(.smooth(duration: 0.28)) { cursors[section.id] = next }
    }

    private func accessibilityLabel(row: LiveTVGuideRow, cursor: LiveTVGuideCursor) -> String {
        let cell = row.cell(at: cursor.time)
        return [row.channel.displayTitle, cell?.program?.primaryDisplayTitle ?? "No program information"]
            .joined(separator: ", ")
    }

    #if DEBUG
    /// `-DuskScreenshotGuideMoves "down,down,right"` replays remote presses
    /// once the guide is up, for the screenshot runs.
    private func runScreenshotMoves() async {
        guard !sections.isEmpty, let moves = ScreenshotMode.guideMoves else { return }
        try? await Task.sleep(for: .seconds(1.5))
        focusedRowID = firstRowID
        let rows = sections.flatMap { section in section.rows.map { (row: $0, section: section) } }
        for move in moves {
            try? await Task.sleep(for: .milliseconds(450))
            let index = rows.firstIndex { $0.row.id == focusedRowID } ?? 0
            switch move {
            case "down": focusedRowID = rows[min(index + 1, rows.count - 1)].row.id
            case "up": focusedRowID = rows[max(index - 1, 0)].row.id
            case "right": step(.next, in: rows[index].row, section: rows[index].section)
            case "left": step(.previous, in: rows[index].row, section: rows[index].section)
            default: break
            }
        }
    }
    #endif
}

/// The focus engine would rather park the focused row mid-screen and moves the
/// list by several rows to do it. It still decides the direction; each scroll
/// is held to one row, so the channels shift gently under the focus.
private struct LiveTVGuideRowPacing: ScrollTargetBehavior {
    let maxStep: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard context.axes.contains(.vertical) else { return }
        let from = context.originalTarget.rect.minY
        let delta = target.rect.minY - from
        guard abs(delta) > maxStep else { return }
        target.rect.origin.y = from + (delta > 0 ? maxStep : -maxStep)
    }
}

/// No system lift: the row itself is only the focus anchor. Its highlighted
/// block carries the focus look, and the row gets the faint `TextPrimary`
/// band STYLE.md gives custom rows.
private struct LiveTVGuideRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LiveTVGuideRowButtonBody(configuration: configuration)
    }
}

private struct LiveTVGuideRowButtonBody: View {
    @Environment(\.isFocused) private var isFocused
    let configuration: ButtonStyle.Configuration

    var body: some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.duskTextPrimary.opacity(isFocused ? 0.06 : 0))
                    .padding(.horizontal, -12)
                    .padding(.vertical, -4)
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.smooth(duration: 0.2), value: isFocused)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}

/// What the focused block is, above the grid. The blocks only
/// have room for a title; this is where the episode, airtime, time left and
/// synopsis go, so Select can always just play.
struct LiveTVGuideInfoPanel: View {
    let focus: (row: LiveTVGuideRow, cell: LiveTVGuideCell)?
    let now: Date
    let imageURL: ((String?, Int, Int) -> URL?)?

    var body: some View {
        if let focus {
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 10) {
                    channelLine(focus.row.channel, cell: focus.cell)
                    Text(focus.cell.program?.primaryDisplayTitle ?? (focus.cell.isCollapsedGap ? "No Programs" : focus.row.channel.displayTitle))
                        .font(DuskFont.TV.pageTitle)
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(1)
                    metadataLine(focus.cell)
                    if let summary = focus.cell.program?.summary?.nilIfEmpty {
                        Text(summary)
                            .font(DuskFont.TV.body)
                            .foregroundStyle(Color.duskTextSecondary)
                            .lineLimit(2)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(nil, value: focus.cell.id)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Guide")
                    .font(DuskFont.TV.pageTitle)
                    .foregroundStyle(Color.duskTextPrimary)
                Text(now.formatted(date: .complete, time: .omitted))
                    .font(DuskFont.TV.metadata)
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
    }

    private func channelLine(_ channel: PlexLiveChannel, cell: LiveTVGuideCell) -> some View {
        HStack(spacing: 14) {
            if cell.isReplayable {
                Image(systemName: "play.fill")
                    .font(DuskFont.TV.badge)
                    .foregroundStyle(Color.duskTextSecondary)
            } else if cell.isAiring(at: now) {
                Text("LIVE")
                    .font(DuskFont.TV.badge)
                    .foregroundStyle(Color.duskBackground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.duskTextPrimary, in: Capsule())
            }
            Text([channel.displayNumber, channel.displayTitle].compactMap { $0 }.joined(separator: " · "))
                .font(DuskFont.TV.metadata)
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    @ViewBuilder
    private func metadataLine(_ cell: LiveTVGuideCell) -> some View {
        let parts: [String] = {
            var parts: [String] = []
            if let episode = cell.program?.episodeDisplayTitle { parts.append(episode) }
            if let program = cell.program, let beginsAt = program.beginsAt, let endsAt = program.endsAt {
                let day = Calendar.current.isDateInToday(beginsAt) ? "" : LiveTVGuideDayName.short(beginsAt, now: now) + " "
                parts.append("\(day)\(beginsAt.formatted(date: .omitted, time: .shortened)) – \(endsAt.formatted(date: .omitted, time: .shortened))")
                if program.isAiring(at: now) {
                    let left = Int(endsAt.timeIntervalSince(now) / 60)
                    parts.append(left >= 60 ? "\(left / 60) hr \(left % 60) min left" : "\(max(left, 1)) min left")
                } else if beginsAt > now {
                    let until = Int(beginsAt.timeIntervalSince(now) / 60)
                    if until >= 24 * 60 {
                        let days = until / (24 * 60)
                        parts.append(days == 1 ? "in 1 day" : "in \(days) days")
                    } else {
                        parts.append(until >= 60 ? "in \(until / 60) hr \(until % 60) min" : "in \(max(until, 1)) min")
                    }
                } else {
                    parts.append(cell.isReplayable ? "Select to watch" : "Aired")
                }
            } else if cell.isCollapsedGap {
                let span = [cell.start, cell.end]
                    .map { "\(LiveTVGuideDayName.short($0, now: now)) \($0.formatted(date: .omitted, time: .shortened))" }
                    .joined(separator: " – ")
                parts.append("\(span) · Select to skip")
            } else if cell.program == nil {
                parts.append("No program information · Select to watch live")
            }
            return parts
        }()
        HStack(spacing: 18) {
            Text(parts.joined(separator: "  ·  "))
                .font(DuskFont.TV.metadata)
                .foregroundStyle(Color.duskTextPrimary.opacity(0.85))
                .lineLimit(1)
            if let program = cell.program, program.isAiring(at: now), let progress = program.progress(at: now) {
                Capsule()
                    .fill(Color.duskTextSecondary.opacity(0.35))
                    .frame(width: 160, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.duskTextPrimary).frame(width: 160 * progress, height: 6)
                    }
            }
        }
    }
}
#endif

/// The day a guide label names. A weekday alone is fine within the week;
/// the guide reaches up to three weeks ahead, where "Thu" could be any of
/// three Thursdays, so from 6 days away it carries the date too ("Thu 19").
enum LiveTVGuideDayName {
    static func short(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        guard abs(days) >= 6 else { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }
}
