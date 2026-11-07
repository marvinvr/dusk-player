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
    /// Channel name beside the logo (wide layouts) or logo + number only.
    let showsChannelName: Bool

    #if os(tvOS)
    static let tv = LiveTVGuideMetrics(
        channelWidth: 330, rowHeight: 104, rowSpacing: 10, rulerHeight: 64,
        pointsPerMinute: 9, blockGap: 8, cornerRadius: 16, showsChannelName: true
    )
    #else
    static func forWidth(_ width: CGFloat) -> LiveTVGuideMetrics {
        if width >= 900 {
            // iPad
            return LiveTVGuideMetrics(
                channelWidth: 190, rowHeight: 72, rowSpacing: 0, rulerHeight: 38,
                pointsPerMinute: 6, blockGap: 3, cornerRadius: 12, showsChannelName: true
            )
        }
        if width >= 600 {
            // iPhone landscape
            return LiveTVGuideMetrics(
                channelWidth: 160, rowHeight: 62, rowSpacing: 0, rulerHeight: 34,
                pointsPerMinute: 4.6, blockGap: 3, cornerRadius: 10, showsChannelName: true
            )
        }
        return LiveTVGuideMetrics(
            channelWidth: 74, rowHeight: 66, rowSpacing: 0, rulerHeight: 34,
            pointsPerMinute: 3.8, blockGap: 3, cornerRadius: 10, showsChannelName: false
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

    private var label: some View {
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
        } else if isDimmedPast {
            Color.duskBackground.overlay(Color.duskSurface.opacity(cell.isReplayable ? 0.75 : 0.5))
        } else if isLive {
            Color.duskBackground.overlay(Color.duskTextPrimary.opacity(0.1))
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

    private var placeholder: some View {
        Text(channel.displayNumber ?? String(channel.displayTitle.prefix(3)))
            .font(DuskFont.cardTitle(ios: .caption.weight(.bold)))
            .foregroundStyle(Color.duskTextSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// Half-hour labels across the timeline, with the current time as a pill on
/// the now line. Neutral: the pill is the inverted primary fill.
struct LiveTVGuideRuler: View {
    let timeline: LiveTVGuideTimeline
    let now: Date
    let metrics: LiveTVGuideMetrics
    /// iOS: the pinned corner's width; labels under it fade out.
    var pinnedColumnWidth: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(timeline.ticks, id: \.self) { tick in
                HStack(spacing: tickSpacing) {
                    Rectangle()
                        .fill(Color.duskTextSecondary.opacity(0.5))
                        .frame(width: 1, height: tickHeight)
                    Text(tick.formatted(date: .omitted, time: .shortened))
                        .font(DuskFont.metadata(ios: .caption.weight(.medium)).monospacedDigit())
                        .foregroundStyle(Color.duskTextSecondary)
                        .fixedSize()
                        // The now pill covers this stretch; two times on top
                        // of each other read as neither.
                        .opacity(abs(now.timeIntervalSince(tick) - 6 * 60) < 13 * 60 && timeline.contains(now) ? 0 : 1)
                }
                .offset(x: timeline.x(for: tick))
                #if !os(tvOS)
                .visualEffect { [pinnedColumnWidth, x = timeline.x(for: tick)] content, proxy in
                    // A label sliding under the pinned corner would read
                    // as the wrong time ("8:00" for 18:00). The frame here
                    // is the one before `offset`, hence `+ x`.
                    let minX = proxy.frame(in: .scrollView(axis: .horizontal)).minX + x
                    return content.opacity(minX < pinnedColumnWidth ? 0 : 1)
                }
                #endif
            }

            if timeline.contains(now) {
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(DuskFont.badge(ios: .caption2.weight(.bold)).monospacedDigit())
                    .foregroundStyle(Color.duskBackground)
                    .padding(.horizontal, pillPadding)
                    .padding(.vertical, pillPadding / 2.5)
                    .background(Color.duskTextPrimary, in: Capsule())
                    .fixedSize()
                    .alignmentGuide(.leading) { $0.width / 2 }
                    .offset(x: timeline.x(for: now))
            }
        }
        .frame(width: timeline.width, height: metrics.rulerHeight, alignment: .leading)
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

            ForEach(row.cells) { cell in
                let x0 = timeline.x(for: cell.start) + metrics.blockGap / 2
                let width = max(timeline.x(for: cell.end) - metrics.blockGap / 2 - x0, 2)
                block(cell, cell.isAiring(at: now) ? timeline.x(for: now) - x0 : 0)
                    .frame(width: width, height: metrics.rowHeight - metrics.blockGap)
                    .offset(x: x0)
            }
        }
        .frame(width: timeline.width, height: metrics.rowHeight, alignment: .leading)
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
/// One native 2-D scroll view: the ruler is the pinned section header, the
/// channel column pins itself against horizontal scrolling with
/// `visualEffect` (applied at render time, so it never lags the scroll), and
/// every row shares the single horizontal offset.
struct LiveTVGuideGrid: View {
    let sections: [LiveTVGuideSection]
    let timeline: LiveTVGuideTimeline
    let now: Date
    let metrics: LiveTVGuideMetrics
    let imageURL: (PlexLiveTVLineup) -> (String?, Int, Int) -> URL?
    @Binding var position: ScrollPosition
    /// The vertical content offset, kept so a horizontal jump (Now, a day
    /// change) leaves the channel list where it was: `scrollTo(x:)` alone
    /// also resets y.
    @Binding var scrollY: CGFloat
    /// Bumped to scroll back to now (or to the start of another day).
    let nowRequest: Int
    let select: (LiveTVGuideCell, LiveTVGuideRow, PlexLiveTVLineup) -> Void
    let showDetails: (PlexLiveProgram) -> Void
    let playChannel: (PlexLiveChannel, PlexLiveTVLineup) -> Void
    /// The horizontal content offset, so a timeline whose start moves can
    /// keep the same time in view.
    @State private var scrollX: CGFloat = 0

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: metrics.rowSpacing, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(sections) { section in
                        if sections.count > 1 {
                            sectionLabel(section.title)
                        }
                        let url = imageURL(section.lineup)
                        ForEach(section.rows) { row in
                            rowView(row, lineup: section.lineup, imageURL: url)
                        }
                    }
                } header: {
                    rulerHeader
                }
            }
            .padding(.bottom, 24)
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, offset in
            scrollY = offset.y
            scrollX = offset.x
        }
        // The grid reaches back into the past now, so it opens on now
        // rather than on its start; the past is a scroll to the left.
        .onAppear { scrollToNow(animated: false) }
        .onChange(of: nowRequest) { scrollToNow(animated: true) }
        .onChange(of: timeline) { old, new in
            // The "Now" grid rolls forward (or reaches back once older guide
            // data arrives): keep the same moment at the leading edge.
            guard old.contains(now), new.contains(now), old.start != new.start else { return }
            let x = max(0, new.x(for: old.date(forX: scrollX)))
            position.scrollTo(point: CGPoint(x: x, y: scrollY))
        }
        #if DEBUG
        .task {
            guard let minutes = ScreenshotMode.guideOffsetMinutes else { return }
            try? await Task.sleep(for: .seconds(1))
            position.scrollTo(point: CGPoint(x: CGFloat(minutes) * metrics.pointsPerMinute, y: scrollY))
        }
        #endif
    }

    private func scrollToNow(animated: Bool) {
        let point = CGPoint(x: timeline.nowOffset(now), y: scrollY)
        if animated {
            withAnimation(.smooth) { position.scrollTo(point: point) }
        } else {
            position.scrollTo(point: point)
        }
    }

    private var rulerHeader: some View {
        HStack(spacing: 0) {
            Color.duskBackground
                .padding(.leading, -Self.safeAreaBleed)
                .frame(width: metrics.channelWidth, height: metrics.rulerHeight)
                .pinnedToLeadingEdge()
                .zIndex(1)
            LiveTVGuideRuler(timeline: timeline, now: now, metrics: metrics, pinnedColumnWidth: metrics.channelWidth)
        }
        .background(Color.duskBackground)
        .overlay(alignment: .bottom) { hairline }
    }

    private func sectionLabel(_ title: String) -> some View {
        LiveTVGuideSectionLabel(title: title)
            .padding(.leading, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .pinnedToLeadingEdge()
    }

    /// In landscape the scroll view's content starts inside the leading safe
    /// area, so the pinned column sits at that inset and blocks scrolling
    /// past would show beside it; its background reaches back over the gap.
    private static let safeAreaBleed: CGFloat = 120

    private func rowView(
        _ row: LiveTVGuideRow,
        lineup: PlexLiveTVLineup,
        imageURL: @escaping (String?, Int, Int) -> URL?
    ) -> some View {
        HStack(spacing: 0) {
            Button {
                playChannel(row.channel, lineup)
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

            LiveTVGuideRowStrip(row: row, timeline: timeline, now: now, metrics: metrics) { cell, elapsed in
                Button {
                    select(cell, row, lineup)
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
                .contextMenu {
                    if cell.isAiring(at: now) {
                        Button("Watch Live", systemImage: "play.fill") { select(cell, row, lineup) }
                    } else if cell.isReplayable {
                        Button("Play", systemImage: "play.fill") { select(cell, row, lineup) }
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
}
#endif

// MARK: - tvOS

#if os(tvOS)
/// The tvOS grid. The focus engine owns which **row** is focused (rows are
/// full-width, so Up/Down is plain native focus movement with native vertical
/// scrolling); the time position and horizontal scroll are app state
/// (`LiveTVGuideCursor`), so Up/Down keeps the time and Left/Right steps
/// through programmes, the way a cable guide does. Letting the focus engine
/// pick programmes itself would land on whichever block's centre is nearest
/// and drift a little with every row.
struct LiveTVGuideTVGrid<Corner: View>: View {
    /// The width the grid gets (safe area applied). Measured by the caller:
    /// the grid's own geometry reported the full screen width, so blocks
    /// past the visible edge counted as on screen and Right never scrolled.
    let width: CGFloat
    let sections: [LiveTVGuideSection]
    let timeline: LiveTVGuideTimeline
    let now: Date
    let imageURL: (PlexLiveTVLineup) -> (String?, Int, Int) -> URL?
    @Binding var cursor: LiveTVGuideCursor
    let select: (LiveTVGuideCell, LiveTVGuideRow, PlexLiveTVLineup) -> Void
    let showDetails: (PlexLiveProgram) -> Void
    /// Back to now (switching to the "Now" grid when another day is up).
    let jumpToNow: () -> Void
    /// Left past the first programme (or Right past the last) of the grid:
    /// the day that holds `date`, if there is one, takes over.
    let crossDay: (LiveTVGuideCursor.Step, Date) -> Void
    @ViewBuilder let corner: () -> Corner

    @FocusState private var focusedRowID: String?
    /// Where focus re-enters the grid from the tab bar or the corner.
    @State private var lastFocusedRowID: String?

    private let metrics = LiveTVGuideMetrics.tv

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiveTVGuideInfoPanel(
                focus: focusedCell,
                now: now,
                imageURL: focusedLineup.map(imageURL)
            )
            .frame(height: 230, alignment: .topLeading)

            HStack(spacing: 0) {
                corner()
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
                            rowButton(row, lineup: section.lineup, imageURL: url)
                        }
                    }
                }
                .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
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
        .onChange(of: timeline, initial: true) { old, new in
            if cursor.pending != nil {
                applyPendingPlacement()
            } else if old != new, old.contains(now), new.contains(now) {
                cursor.follow(from: old, to: new, viewport: viewport)
            }
        }
        .onChange(of: cursor.pending) { _, pending in
            if pending != nil { applyPendingPlacement() }
        }
        #if DEBUG
        .task(id: sections.isEmpty) { await runScreenshotMoves() }
        #endif
    }

    private var firstRowID: String? { sections.first?.rows.first?.id }

    /// Applies `cursor.pending` once the timeline it is meant for is up: a
    /// day switch updates the cursor before the new day's grid exists.
    private func applyPendingPlacement() {
        guard let pending = cursor.pending else { return }
        var next = cursor
        switch pending {
        case .now:
            next.jumpToNow(now, timeline: timeline, viewport: viewport)
        case .time(let date, let step):
            guard timeline.contains(date) || date == timeline.end else { return }
            guard let row = focusedRow?.row ?? sections.first?.rows.first else { return }
            next.land(at: date, stepping: step, in: row, timeline: timeline, viewport: viewport)
        }
        next.pending = nil
        withAnimation(.smooth(duration: 0.3)) { cursor = next }
    }

    private var viewport: CGFloat { max(width - metrics.channelWidth, 1) }

    /// The focused row, or the last one while focus is briefly elsewhere (the
    /// day menu, a context menu, the details sheet): the info panel keeps
    /// describing what the viewer was on instead of blanking.
    private var focusedRow: (row: LiveTVGuideRow, lineup: PlexLiveTVLineup)? {
        guard let focusedRowID = focusedRowID ?? lastFocusedRowID else { return nil }
        for section in sections {
            if let row = section.rows.first(where: { $0.id == focusedRowID }) { return (row, section.lineup) }
        }
        return nil
    }

    private var focusedLineup: PlexLiveTVLineup? { focusedRow?.lineup }

    private var focusedCell: (row: LiveTVGuideRow, cell: LiveTVGuideCell)? {
        guard let row = focusedRow?.row, let cell = row.cell(at: cursor.time) else { return nil }
        return (row, cell)
    }

    private var ruler: some View {
        LiveTVGuideRuler(timeline: timeline, now: now, metrics: metrics)
            .offset(x: -cursor.offset)
            .frame(width: viewport, height: metrics.rulerHeight, alignment: .leading)
            .clipped()
    }

    private func rowButton(
        _ row: LiveTVGuideRow,
        lineup: PlexLiveTVLineup,
        imageURL: @escaping (String?, Int, Int) -> URL?
    ) -> some View {
        let highlighted = focusedRowID == row.id ? row.cell(at: cursor.time) : nil
        return Button {
            if let cell = row.cell(at: cursor.time) { select(cell, row, lineup) }
        } label: {
            HStack(spacing: 0) {
                LiveTVGuideChannelCell(
                    channel: row.channel,
                    logoURL: imageURL(row.channel.thumb, 224, 120),
                    metrics: metrics,
                    isFocusedRow: highlighted != nil
                )
                LiveTVGuideRowStrip(row: row, timeline: timeline, now: now, metrics: metrics) { cell, elapsed in
                    LiveTVGuideBlock(
                        cell: cell,
                        now: now,
                        metrics: metrics,
                        elapsedWidth: elapsed,
                        isHighlighted: cell.id == highlighted?.id,
                        stickyInset: stickyInset(for: cell)
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
            case .left: step(.previous, in: row)
            case .right: step(.next, in: row)
            default: break
            }
        }
        .contextMenu {
            if let cell = row.cell(at: cursor.time) {
                Button(cell.isAiring(at: now) ? "Watch Live" : "Watch \(row.channel.displayTitle) Live", systemImage: "play.fill") {
                    select(LiveTVGuideCell(id: cell.id, start: now, end: now, program: nil, startsBeforeTimeline: false), row, lineup)
                }
                if cell.isReplayable {
                    Button("Play", systemImage: "play.fill") { select(cell, row, lineup) }
                }
                if let program = cell.program {
                    Button("Details", systemImage: "info.circle") { showDetails(program) }
                }
            }
            Button("Jump to Now", systemImage: "clock.arrow.circlepath") { jumpToNow() }
        }
        .accessibilityLabel(accessibilityLabel(row: row))
    }

    /// How far `cell` runs off the visible leading edge, capped so a sliver
    /// of a programme never squeezes its title to nothing.
    private func stickyInset(for cell: LiveTVGuideCell) -> CGFloat {
        let x0 = timeline.x(for: cell.start) + metrics.blockGap / 2
        let width = timeline.x(for: cell.end) - metrics.blockGap / 2 - x0
        return min(max(cursor.offset - x0, 0), max(width - 160, 0))
    }

    /// Past either end of the grid the neighbouring day takes over, so Left
    /// keeps going back through the past (as far as catch-up reaches).
    private func step(_ step: LiveTVGuideCursor.Step, in row: LiveTVGuideRow) {
        var next = cursor
        guard next.step(step, in: row, timeline: timeline, viewport: viewport) else {
            crossDay(step, LiveTVGuideCursor.crossingTime(step, in: row, timeline: timeline))
            return
        }
        withAnimation(.smooth(duration: 0.28)) { cursor = next }
    }

    private func accessibilityLabel(row: LiveTVGuideRow) -> String {
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
        let rows = sections.flatMap(\.rows)
        for move in moves {
            try? await Task.sleep(for: .milliseconds(450))
            let index = rows.firstIndex { $0.id == focusedRowID } ?? 0
            switch move {
            case "down": focusedRowID = rows[min(index + 1, rows.count - 1)].id
            case "up": focusedRowID = rows[max(index - 1, 0)].id
            case "right": step(.next, in: rows[index])
            case "left": step(.previous, in: rows[index])
            default: break
            }
        }
    }
    #endif
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
                    Text(focus.cell.program?.primaryDisplayTitle ?? focus.row.channel.displayTitle)
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
                let day = Calendar.current.isDateInToday(beginsAt) ? "" : beginsAt.formatted(.dateTime.weekday(.abbreviated)) + " "
                parts.append("\(day)\(beginsAt.formatted(date: .omitted, time: .shortened)) – \(endsAt.formatted(date: .omitted, time: .shortened))")
                if program.isAiring(at: now) {
                    let left = Int(endsAt.timeIntervalSince(now) / 60)
                    parts.append(left >= 60 ? "\(left / 60) hr \(left % 60) min left" : "\(max(left, 1)) min left")
                } else if beginsAt > now {
                    let until = Int(beginsAt.timeIntervalSince(now) / 60)
                    parts.append(until >= 60 ? "in \(until / 60) hr \(until % 60) min" : "in \(max(until, 1)) min")
                } else {
                    parts.append(cell.isReplayable ? "Select to watch" : "Aired")
                }
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
