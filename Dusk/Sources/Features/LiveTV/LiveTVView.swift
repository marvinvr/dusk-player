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

    private struct PendingLivePlay {
        let channel: PlexLiveChannel
        let program: PlexLiveProgram
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading, viewModel.lineup == nil {
                FeatureLoadingView()
            } else if !viewModel.isAvailable, viewModel.error == nil {
                FeatureEmptyStateView(
                    systemImage: "dot.radiowaves.left.and.right",
                    title: "Live TV isn’t available",
                    message: "Set up a tuner and program guide on this Plex server to watch live channels."
                )
            } else if let error = viewModel.error, viewModel.lineup == nil {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load(force: true) }
                }
            } else if let lineup = viewModel.lineup {
                guide(lineup)
            }
        }
        .duskNavigationTitle("Live TV")
        .duskNavigationBarTitleDisplayModeLarge()
        .task {
            // Reruns whenever the tab comes back, so a returning viewer gets
            // a current guide, then keeps it current while it stays open.
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
            LiveTVProgramDetails(
                program: program,
                channel: channel(for: program),
                canPlay: program.isAiring(),
                play: {
                    if let channel = channel(for: program) {
                        pendingPlay = PendingLivePlay(channel: channel, program: program)
                    }
                    selectedProgram = nil
                }
            )
        }
    }

    private func playPending() {
        guard let pending = pendingPlay else { return }
        pendingPlay = nil
        play(channel: pending.channel, program: pending.program)
    }

    private func guide(_ lineup: PlexLiveTVLineup) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                datePicker

                ForEach(lineup.guides) { guide in
                    LiveTVChannelGuideRow(
                        guide: guide,
                        imageURL: viewModel.imageURL,
                        selectProgram: { selectedProgram = $0 },
                        play: { play(channel: guide.channel, program: $0) }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
    }

    private var datePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(viewModel.dayOffsetOptions, id: \.self) { dayOffset in
                    dayButton(dayOffset)
                }
            }
            #if os(tvOS)
            // Room for the focused pill to lift without being clipped.
            .padding(.vertical, 12)
            #endif
        }
        .scrollIndicators(.hidden)
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }

    @ViewBuilder
    private func dayButton(_ dayOffset: Int) -> some View {
        let isSelected = dayOffset == viewModel.selectedDayOffset
        #if os(tvOS)
        // System glass: dark platter that lifts to white on focus. The picked
        // day carries a checkmark instead of a fill, which would fight the
        // focus state (STYLE.md: no tint for UI state).
        Button {
            Task { await viewModel.selectDayOffset(dayOffset) }
        } label: {
            if isSelected {
                Label(dayLabel(dayOffset), systemImage: "checkmark")
            } else {
                Text(dayLabel(dayOffset))
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        #else
        Button {
            Task { await viewModel.selectDayOffset(dayOffset) }
        } label: {
            Text(dayLabel(dayOffset))
                .font(DuskFont.buttonLabel(ios: .subheadline.weight(.semibold)))
                .foregroundStyle(isSelected ? Color.duskBackground : Color.duskTextPrimary)
                .padding(.horizontal, 18)
                .frame(height: 42)
                .background(isSelected ? Color.duskTextPrimary : Color.duskSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        #endif
    }

    /// A channel is always tunable; the program only labels the session and
    /// is dropped unless it is on now. Guide data is optional (issue #17).
    private func play(channel: PlexLiveChannel, program: PlexLiveProgram?) {
        guard let lineup = viewModel.lineup else { return }
        let program = program.flatMap { $0.isAiring() ? $0 : nil }
        Task {
            await playback.playLiveTV(channel: channel, program: program, lineup: lineup)
        }
    }

    private func channel(for program: PlexLiveProgram) -> PlexLiveChannel? {
        viewModel.lineup?.channel(for: program)
    }

    private func dayLabel(_ dayOffset: Int) -> String {
        if dayOffset == 0 { return "Now" }
        if dayOffset == 1 { return "Tomorrow" }
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: .now)) ?? .now
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

struct LiveTVChannelGuideRow: View {
    let guide: PlexLiveChannelGuide
    let imageURL: (String?, Int, Int) -> URL?
    let selectProgram: (PlexLiveProgram) -> Void
    let play: (PlexLiveProgram?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                channelLogo

                VStack(alignment: .leading, spacing: 2) {
                    Text(guide.channel.displayTitle)
                        .font(DuskFont.rowTitle(ios: .headline))
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(1)
                    if let number = guide.channel.displayNumber {
                        Text(number)
                            .font(DuskFont.caption(ios: .subheadline))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }

                Spacer()

                #if !os(tvOS)
                Button {
                    play(guide.currentProgram())
                } label: {
                    Label("Watch", systemImage: "play.fill")
                        .foregroundStyle(Color.duskPrimaryActionLabel)
                }
                .detailHeroNativePrimaryButtonStyle()
                #endif
            }

            #if os(tvOS)
            tvProgramsRow
            #else
            programsRow
            #endif
        }
    }

    #if os(tvOS)
    /// On tvOS the channel itself leads the row as a card. A Watch button in
    /// the header sat off to the right, above nothing, so the focus engine
    /// never reached it and the only thing Select could do was open a
    /// program's details (issue #17). Leading the row, it is where focus
    /// lands coming down the guide, and Left from any program gets there.
    private var tvProgramsRow: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 40) {
                Button {
                    play(guide.currentProgram())
                } label: {
                    LiveTVChannelWatchCard(
                        channel: guide.channel,
                        currentProgram: guide.currentProgram(),
                        logoURL: imageURL(guide.channel.thumb, 256, 256)
                    )
                }
                .liveTVCardButtonStyle()
                .accessibilityLabel("Watch \(guide.channel.displayTitle) live")

                ForEach(guide.programs) { program in
                    programButton(program)
                }
            }
            // Room for the system card lift.
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .focusSection()
    }
    #endif

    @ViewBuilder
    private var programsRow: some View {
        if guide.programs.isEmpty {
            // Still a card, not a caption: the channel tunes without a
            // guide.
            Button {
                play(nil)
            } label: {
                LiveTVProgramCard(
                    program: nil,
                    imageURL: nil,
                    channelLogoURL: imageURL(guide.channel.thumb, 256, 256)
                )
            }
            .liveTVCardButtonStyle()
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(guide.programs) { program in
                        programButton(program)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func programButton(_ program: PlexLiveProgram) -> some View {
        Button {
            selectProgram(program)
        } label: {
            LiveTVProgramCard(
                program: program,
                imageURL: imageURL(program.preferredLandscapePath, 480, 270),
                channelLogoURL: imageURL(guide.channel.thumb, 256, 256)
            )
        }
        .liveTVCardButtonStyle()
    }

    private var channelLogo: some View {
        Group {
            if let url = imageURL(guide.channel.thumb, 128, 128) {
                DuskAsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        channelPlaceholder
                    }
                }
            } else {
                channelPlaceholder
            }
        }
        .frame(width: 52, height: 52)
        .padding(6)
        .background(Color.duskSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var channelPlaceholder: some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .foregroundStyle(Color.duskTextSecondary)
    }
}

#if os(tvOS)
/// The channel as a card: its logo, what is on, and a play glyph, so it reads
/// as "watch this channel" rather than as another program.
private struct LiveTVChannelWatchCard: View {
    @Environment(\.isFocused) private var isFocused
    let channel: PlexLiveChannel
    let currentProgram: PlexLiveProgram?
    let logoURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                logo
                Spacer()
                Image(systemName: "play.fill")
                    .font(DuskFont.glyphLarge(ios: .title2))
            }
            Spacer(minLength: 0)
            Text("Watch Live")
                .font(DuskFont.cardTitle(ios: .subheadline.weight(.semibold)))
                .lineLimit(1)
            Text(currentProgram?.primaryDisplayTitle ?? "No program information")
                .font(DuskFont.cardSubtitle(ios: .caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .foregroundStyle(Color.duskTextPrimary)
        .padding(20)
        .frame(width: LiveTVProgramCard.cardWidth, height: LiveTVProgramCard.cardHeight, alignment: .topLeading)
        .background(LiveTVProgramCard.platter(isFocused: isFocused))
        .clipShape(RoundedRectangle(cornerRadius: LiveTVProgramCard.cornerRadius, style: .continuous))
    }

    private var logo: some View {
        Group {
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
        .frame(width: 96, height: 72, alignment: .leading)
    }

    private var placeholder: some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(DuskFont.glyphLarge(ios: .title2))
            .foregroundStyle(Color.duskTextSecondary)
    }
}
#endif

private extension View {
    /// tvOS: the system card, which lifts, scales and highlights the focused
    /// guide card like any poster in the app. A plain style with a custom
    /// effect left the focused card barely distinguishable (issue #17). No
    /// `.hoverEffect` on top: the card style already is that effect.
    @ViewBuilder
    func liveTVCardButtonStyle() -> some View {
        #if os(tvOS)
        self
            .buttonStyle(.card)
            .buttonBorderShape(.roundedRectangle(radius: LiveTVProgramCard.cornerRadius))
        #else
        self.buttonStyle(.plain)
        #endif
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

private struct LiveTVProgramDetails: View {
    @Environment(\.dismiss) private var dismiss
    #if os(tvOS)
    /// Watch Live is where Select should go first; the sheet otherwise opens
    /// on Done.
    @FocusState private var watchFocused: Bool
    #endif
    let program: PlexLiveProgram
    let channel: PlexLiveChannel?
    let canPlay: Bool
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
                            Label("Watch Live", systemImage: "play.fill")
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
