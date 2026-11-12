import SwiftUI

struct LiveTVView: View {
    let viewModel: LiveTVViewModel
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            LiveTVRootContent(viewModel: viewModel)
                .duskAppNavigationDestinations()
        }
    }
}

struct LiveTVRootContent: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.scenePhase) private var scenePhase
    let viewModel: LiveTVViewModel
    @State private var selectedProgram: PlexLiveProgram?
    /// Set by the program sheet's Watch Live and started once the sheet is
    /// gone. Presenting the player while the sheet was still dismissing
    /// dropped the presentation on tvOS, so nothing ever played (issue #17).
    @State private var pendingPlay: PendingLivePlay?
    #if os(tvOS)
    /// One per guide section, so each source scrolls on its own.
    @State private var tvCursors: [String: LiveTVGuideCursor] = [:]
    #else
    @State private var gridJump = LiveTVGuideJump()
    #endif

    private struct PendingLivePlay {
        let channel: PlexLiveChannel
        let program: PlexLiveProgram
        let lineup: PlexLiveTVLineup
        /// A past programme played back (catch-up or a recording), not the
        /// channel live.
        let isReplay: Bool
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.hasGuide {
                guide()
            } else if viewModel.isLoadingAny {
                FeatureLoadingView()
            } else if !viewModel.isAvailable, viewModel.error == nil {
                FeatureEmptyStateView(
                    systemImage: "dot.radiowaves.left.and.right",
                    title: "Live TV isn’t available",
                    message: "Set up a tuner and program guide on this Plex server, or add an IPTV source in Settings, to watch live channels."
                )
            } else if let error = viewModel.guideError {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load(force: true) }
                }
            }
        }
        .duskNavigationTitle("Live TV")
        .duskNavigationBarTitleDisplayModeLarge()
        // Reruns whenever the tab comes back, so a returning viewer gets a
        // current guide, then keeps it current while it stays open. Also
        // reruns when a DVR turns up after the tab opened on IPTV alone.
        .task(id: viewModel.provider?.id) {
            await viewModel.load()
            await viewModel.keepFresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.load() }
            }
        }
        .refreshable {
            await viewModel.load(force: true)
        }
        .sheet(item: $selectedProgram, onDismiss: playPending) { program in
            let match = channelAndLineup(for: program)
            let isReplay = match.map { viewModel.canReplay(program, on: $0.channel) } ?? false
            LiveTVProgramDetails(
                program: program,
                channel: match?.channel,
                canPlay: program.isAiring() || isReplay,
                isReplay: isReplay,
                play: {
                    if let match {
                        pendingPlay = PendingLivePlay(
                            channel: match.channel, program: program, lineup: match.lineup, isReplay: isReplay
                        )
                    }
                    selectedProgram = nil
                }
            )
            #if !os(tvOS)
            // Half height: the guide it came from stays in view.
            .presentationDetents([.medium, .large])
            #endif
        }
    }

    private func playPending() {
        guard let pending = pendingPlay else { return }
        pendingPlay = nil
        if pending.isReplay {
            replay(pending.program, channel: pending.channel)
        } else {
            play(channel: pending.channel, program: pending.program, lineup: pending.lineup)
        }
    }

    /// The grid: channels down the side, programmes as blocks as wide as their
    /// airtime. Plex and every IPTV source feed the same `PlexLiveTVLineup`
    /// model, so each is just another section, with its own time axis.
    private func guide() -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            GeometryReader { proxy in
                #if os(tvOS)
                let metrics = LiveTVGuideMetrics.tv
                #else
                let metrics = LiveTVGuideMetrics.forWidth(proxy.size.width)
                #endif
                let sections = guideSections(metrics: metrics, now: context.date)
                #if os(tvOS)
                LiveTVGuideTVGrid(
                    width: proxy.size.width,
                    sections: sections,
                    now: context.date,
                    imageURL: viewModel.imageURL(for:),
                    cursors: $tvCursors,
                    select: select,
                    showDetails: { selectedProgram = $0 },
                    jumpToNow: jumpToNow,
                    crossDay: crossDay,
                    corner: { section, cursor in dayMenu(section: section, cursor: cursor) }
                )
                #else
                LiveTVGuideGrid(
                    width: proxy.size.width,
                    sections: sections,
                    now: context.date,
                    metrics: metrics,
                    imageURL: viewModel.imageURL(for:),
                    jump: gridJump,
                    select: select,
                    showDetails: { selectedProgram = $0 },
                    playChannel: { channel, lineup in play(channel: channel, program: nil, lineup: lineup) }
                )
                #endif
            }
        }
        #if !os(tvOS)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Now") { jumpToNow() }
                dayMenu
            }
        }
        #endif
    }

    /// The Plex lineup, on the selected day, then each IPTV source after it
    /// with its whole guide, headed by the name it was given in Settings.
    /// A DVR with several tuner devices gets one Plex section per device,
    /// headed by the device's name, the same way IPTV sources are split.
    private func guideSections(metrics: LiveTVGuideMetrics, now: Date) -> [LiveTVGuideSection] {
        var sections: [LiveTVGuideSection] = []
        func add(id: String, title: String, lineup: PlexLiveTVLineup, window: LiveTVGuideWindow, collapsesTrailingGap: Bool) {
            let timeline = LiveTVGuideTimeline(
                window: window,
                lineup: lineup,
                now: now,
                pointsPerMinute: metrics.pointsPerMinute,
                collapsedWidth: metrics.collapsedGapWidth,
                collapsesTrailingGap: collapsesTrailingGap
            )
            sections.append(LiveTVGuideSection(
                id: id, title: title, lineup: lineup, timeline: timeline, now: now,
                isReplayable: { program, channel in viewModel.canReplay(program, on: channel, now: now) }
            ))
        }
        for plex in plexSections {
            add(
                id: plex.id, title: plex.title, lineup: plex.lineup,
                // The day the lineup holds, not the one just picked: its old
                // programmes on the new day's axis would read as a day with
                // nothing on, and a pending placement would land on that.
                window: LiveTVViewModel.timelineWindow(
                    forDayOffset: viewModel.loadedDayOffset ?? viewModel.selectedDayOffset,
                    lineups: [plex.lineup],
                    now: now
                ),
                collapsesTrailingGap: true
            )
        }
        for iptv in viewModel.iptvLineups {
            add(
                id: "iptv-\(iptv.source.id)", title: iptv.source.name, lineup: iptv.lineup,
                window: LiveTVGuideTimeline.wholeGuideWindow(of: iptv.lineup, now: now),
                collapsesTrailingGap: false
            )
        }
        return sections
    }

    /// The Plex guide sections: one per tuner device, or the whole lineup
    /// as one section when there is a single device.
    private var plexSections: [PlexLiveTVDeviceLineup] {
        if let groups = viewModel.plexDeviceLineups { return groups }
        guard let lineup = viewModel.lineup else { return [] }
        return [PlexLiveTVDeviceLineup(id: "plex", title: lineup.provider.title, lineup: lineup)]
    }

    /// Live plays; later shows the details; the past plays back when it can
    /// (catch-up or a recording) and otherwise shows the details. A gap (no
    /// guide data) tunes the channel: a guide is optional, the channel always
    /// plays (issue #17).
    private func select(_ cell: LiveTVGuideCell, row: LiveTVGuideRow, lineup: PlexLiveTVLineup) {
        let now = Date.now
        if let program = cell.program, cell.hasEnded(at: now) {
            if cell.isReplayable, viewModel.canReplay(program, on: row.channel, now: now) {
                replay(program, channel: row.channel)
            } else {
                selectedProgram = program
            }
        } else if let program = cell.program, !cell.isAiring(at: now), cell.start > now {
            selectedProgram = program
        } else {
            play(channel: row.channel, program: cell.program, lineup: lineup)
        }
    }

    /// A past programme: an IPTV channel's catch-up, or the library copy of
    /// a Plex airing (played like any library item, resume point included).
    private func replay(_ program: PlexLiveProgram, channel: PlexLiveChannel) {
        if channel.iptv != nil {
            Task { await playback.playIPTVCatchUp(channel: channel, program: program) }
        } else if let item = viewModel.recording(for: program) {
            Task {
                await playback.play(
                    id: item.id,
                    resumeOffsetMilliseconds: item.viewOffset,
                    resumeOffsetDurationMilliseconds: item.duration,
                    placeholder: PlaybackPlaceholder(item: item)
                )
            }
        }
    }

    private var dayBinding: Binding<Int> {
        Binding(
            get: { viewModel.selectedDayOffset },
            set: { offset in
                Task {
                    await viewModel.selectDayOffset(offset)
                    resetScroll()
                }
            }
        )
    }

    private func jumpToNow() {
        if viewModel.selectedDayOffset != 0 {
            dayBinding.wrappedValue = 0
        } else {
            resetScroll()
        }
    }

    /// Every source back to the selected day: now on the "Now" grid, the start
    /// of any other day. Applied by the grid, which knows the timelines it draws.
    private func resetScroll() {
        let offset = viewModel.selectedDayOffset
        let day = offset == 0 ? nil : LiveTVGuideWindow.forDayOffset(offset).start
        #if os(tvOS)
        let plexIDs = Set(plexSections.map(\.id))
        let sectionIDs = viewModel.iptvLineups.map { "iptv-\($0.source.id)" } + plexIDs
        for id in sectionIDs {
            var cursor = tvCursors[id] ?? LiveTVGuideCursor(time: .now)
            if let day, !plexIDs.contains(id) {
                cursor.pending = .day(day)
            } else {
                cursor.pending = .now
            }
            tvCursors[id] = cursor
        }
        #else
        gridJump = LiveTVGuideJump(id: gridJump.id + 1, day: day)
        #endif
    }

    #if os(tvOS)
    /// Left past the start of the Plex grid (or Right past its end): the day
    /// holding `date` takes over, with the cursor on the programme there.
    /// IPTV sources are not on a day, so they stay where they are.
    private func crossDay(_ section: LiveTVGuideSection, _ step: LiveTVGuideCursor.Step, date: Date) {
        guard let offset = viewModel.dayOffset(containing: date),
              offset != viewModel.selectedDayOffset else { return }
        var cursor = tvCursors[section.id] ?? LiveTVGuideCursor(time: .now)
        cursor.pending = .time(date, step)
        tvCursors[section.id] = cursor
        Task {
            await viewModel.selectDayOffset(offset)
            // The other tuner devices are on the same Plex day: they follow
            // to the same moment.
            for id in plexSections.map(\.id) where id != section.id {
                var other = tvCursors[id] ?? LiveTVGuideCursor(time: .now)
                other.pending = .day(date)
                tvCursors[id] = other
            }
        }
    }
    #endif

    #if os(tvOS)
    /// The corner above the channel column: the day, as a native glass menu
    /// (Up from the first channel lands here). Play/Pause anywhere in the
    /// grid also jumps back to now.
    private func dayMenu(section: LiveTVGuideSection?, cursor: LiveTVGuideCursor?) -> some View {
        Menu {
            Button("Now", systemImage: "clock.arrow.circlepath") { jumpToNow() }
            Section {
                ForEach(viewModel.dayOffsetOptions, id: \.self) { offset in
                    Button {
                        dayBinding.wrappedValue = offset
                    } label: {
                        if offset == viewModel.selectedDayOffset {
                            Label(dayLabel(offset), systemImage: "checkmark")
                        } else {
                            Text(dayLabel(offset))
                        }
                    }
                }
            }
        } label: {
            Label(dayLabel(shownDayOffset(section: section, cursor: cursor)), systemImage: "calendar")
                .font(DuskFont.TV.buttonLabel)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }

    /// The day the focused section is on: an IPTV source scrolls through its
    /// whole guide, so its day comes from where it has got to.
    private func shownDayOffset(section: LiveTVGuideSection?, cursor: LiveTVGuideCursor?) -> Int {
        guard let section, section.lineup.provider.isIPTV, let cursor else { return viewModel.selectedDayOffset }
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: cursor.time)
        ).day ?? viewModel.selectedDayOffset
    }

    #else
    private var dayMenu: some View {
        Menu {
            Picker("Day", selection: dayBinding) {
                ForEach(viewModel.dayOffsetOptions, id: \.self) { offset in
                    Text(dayLabel(offset)).tag(offset)
                }
            }
        } label: {
            Label(dayLabel(viewModel.selectedDayOffset), systemImage: "calendar")
        }
    }
    #endif

    /// A channel is always tunable; the program only labels the session and
    /// is dropped unless it is on now. Guide data is optional (issue #17).
    /// `lineup` is the channel's own (Plex or one IPTV source), which is what
    /// the in-player channel list then switches within.
    private func play(channel: PlexLiveChannel, program: PlexLiveProgram?, lineup: PlexLiveTVLineup) {
        let program = program.flatMap { $0.isAiring() ? $0 : nil }
        // A tuner device's section switches within all Plex channels, as before.
        let lineup = lineup.provider.isIPTV ? lineup : (viewModel.lineup ?? lineup)
        Task {
            await playback.playLiveTV(channel: channel, program: program, lineup: lineup)
        }
    }

    private func channelAndLineup(for program: PlexLiveProgram) -> (channel: PlexLiveChannel, lineup: PlexLiveTVLineup)? {
        let lineups = [viewModel.lineup].compactMap { $0 } + viewModel.iptvLineups.map(\.lineup)
        for lineup in lineups {
            if let channel = lineup.channel(for: program) { return (channel, lineup) }
        }
        return nil
    }

    private func dayLabel(_ dayOffset: Int) -> String {
        if dayOffset == 0 { return "Today" }
        if dayOffset == 1 { return "Tomorrow" }
        if dayOffset == -1 { return "Yesterday" }
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: .now)) ?? .now
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

struct LiveTVProgramCard: View {
    @Environment(\.isFocused) private var isFocused
    /// Nil for a channel without guide data; the card then offers the channel
    /// itself.
    let program: PlexLiveProgram?
    let imageURL: URL?
    /// Shown when the program carries no artwork of its own, which is common
    /// on XMLTV and cloud lineups. A centered channel logo says what the card
    /// is; an empty rectangle says nothing.
    var channelLogoURL: URL?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let imageURL {
                    DuskAsyncImage(url: imageURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.86)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(program?.displayTitle ?? "Watch Live")
                    .font(DuskFont.cardTitle(ios: .subheadline.weight(.semibold)))
                    .lineLimit(2)
                if program == nil {
                    Text("No program information")
                        .font(DuskFont.cardSubtitle(ios: .caption))
                        .foregroundStyle(.white.opacity(0.78))
                } else if let beginsAt = program?.beginsAt, let endsAt = program?.endsAt {
                    Text("\(beginsAt.formatted(date: .omitted, time: .shortened)) – \(endsAt.formatted(date: .omitted, time: .shortened))")
                        .font(DuskFont.cardSubtitle(ios: .caption))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .foregroundStyle(.white)
            .padding(12)

            if let program, let progress = program.progress(), program.isAiring() {
                VStack {
                    Spacer()
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: proxy.size.width * progress, height: 4)
                    }
                    .frame(height: 4)
                }
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(Color.duskSurface)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        Self.platter(isFocused: isFocused).overlay {
            if let channelLogoURL {
                DuskAsyncImage(url: channelLogoURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(cardHeight * 0.22)
                    } else {
                        placeholderSymbol
                    }
                }
            } else {
                placeholderSymbol
            }
        }
    }

    private var placeholderSymbol: some View {
        Image(systemName: "tv")
            .font(DuskFont.glyphLarge(ios: .title2))
            .foregroundStyle(Color.duskTextSecondary)
    }

    static var cardWidth: CGFloat {
        #if os(tvOS)
        360
        #else
        260
        #endif
    }

    static var cardHeight: CGFloat {
        cardWidth * 9 / 16
    }

    static let cornerRadius: CGFloat = 16

    /// The card surface. Guides without artwork (most XMLTV and HDHomeRun
    /// lineups) are rows of identical dark tiles, where the system card's lift
    /// alone is easy to miss across the room, so the focused tile also turns
    /// a lighter neutral grey, the way tvOS platters brighten on focus.
    static func platter(isFocused: Bool) -> some View {
        #if os(tvOS)
        Color.duskSurface.overlay(Color.white.opacity(isFocused ? 0.22 : 0))
        #else
        Color.duskSurface
        #endif
    }

    private var cardWidth: CGFloat { Self.cardWidth }
    private var cardHeight: CGFloat { Self.cardHeight }
}

struct LiveTVProgramDetails: View {
    @Environment(\.dismiss) private var dismiss
    #if os(tvOS)
    /// Watch Live is where Select should go first; the sheet otherwise opens
    /// on Done.
    @FocusState private var watchFocused: Bool
    #endif
    let program: PlexLiveProgram
    let channel: PlexLiveChannel?
    let canPlay: Bool
    /// A past programme that plays back (catch-up or a recording).
    var isReplay = false
    let play: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(program.displayTitle)
                        .font(DuskFont.pageTitle(ios: .title.bold()))
                        .foregroundStyle(Color.duskTextPrimary)
                    if let subtitle = program.displaySubtitle {
                        Text(subtitle)
                            .duskFont(tvOnly: DuskFont.TV.pageSubtitle)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                    if let channel {
                        Label(
                            [channel.displayNumber, channel.displayTitle]
                                .compactMap { $0 }
                                .joined(separator: " · "),
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                        .duskFont(tvOnly: DuskFont.TV.metadata)
                        .foregroundStyle(Color.duskTextSecondary)
                    }
                    if let beginsAt = program.beginsAt, let endsAt = program.endsAt {
                        Text("\(beginsAt.formatted(date: .abbreviated, time: .shortened)) – \(endsAt.formatted(date: .omitted, time: .shortened))")
                            .duskFont(tvOnly: DuskFont.TV.metadata)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                    if let summary = program.summary?.nilIfEmpty {
                        Text(summary)
                            .duskFont(tvOnly: DuskFont.TV.body)
                            .foregroundStyle(Color.duskTextPrimary)
                    }
                    if canPlay {
                        Button(action: play) {
                            Label(isReplay ? "Play" : "Watch Live", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                                #if !os(tvOS)
                                .foregroundStyle(Color.duskPrimaryActionLabel)
                                #endif
                        }
                        .detailHeroNativePrimaryButtonStyle()
                        #if os(tvOS)
                        .focused($watchFocused)
                        #endif
                    } else {
                        Text(program.endsAt.map { $0 < .now } == true
                            ? "This program is no longer live."
                            : "This program hasn’t started yet.")
                            .font(DuskFont.caption(ios: .subheadline))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .background(Color.duskBackground.ignoresSafeArea())
            #if os(tvOS)
            .defaultFocus($watchFocused, true)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
