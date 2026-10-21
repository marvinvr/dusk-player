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
    let viewModel: LiveTVViewModel
    @State private var selectedProgram: PlexLiveProgram?

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
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load(force: true)
        }
        .sheet(item: $selectedProgram) { program in
            LiveTVProgramDetails(
                program: program,
                channel: channel(for: program),
                canPlay: program.isAiring(),
                play: {
                    selectedProgram = nil
                    if let channel = channel(for: program) {
                        play(channel: channel, program: program)
                    }
                }
            )
        }
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
                ForEach(viewModel.dateOptions, id: \.self) { date in
                    Button {
                        Task { await viewModel.selectDate(date) }
                    } label: {
                        Text(dateLabel(date))
                            .font(DuskFont.buttonLabel(ios: .subheadline.weight(.semibold)))
                            .foregroundStyle(
                                Calendar.current.isDate(date, inSameDayAs: viewModel.selectedDate)
                                    ? Color.duskBackground
                                    : Color.duskTextPrimary
                            )
                            .padding(.horizontal, 18)
                            .frame(height: 42)
                            .background(
                                Calendar.current.isDate(date, inSameDayAs: viewModel.selectedDate)
                                    ? Color.duskTextPrimary
                                    : Color.duskSurface
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .duskTVOSFocusEffectShape(Capsule())
                }
            }
        }
        .scrollIndicators(.hidden)
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

    private func dateLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
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

                Button {
                    play(guide.currentProgram())
                } label: {
                    Label("Watch", systemImage: "play.fill")
                        #if !os(tvOS)
                        .foregroundStyle(Color.duskPrimaryActionLabel)
                        #endif
                }
                .detailHeroNativePrimaryButtonStyle()
            }

            if guide.programs.isEmpty {
                // Still a card, not a caption: the channel tunes without a
                // guide, and on tvOS a row with nothing focusable stops the
                // focus engine from moving down the list.
                Button {
                    play(nil)
                } label: {
                    LiveTVProgramCard(
                        program: nil,
                        imageURL: nil,
                        channelLogoURL: imageURL(guide.channel.thumb, 256, 256)
                    )
                }
                .buttonStyle(.plain)
                .duskTVOSFocusEffectShape(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(guide.programs) { program in
                            Button {
                                selectProgram(program)
                            } label: {
                                LiveTVProgramCard(
                                    program: program,
                                    imageURL: imageURL(program.preferredLandscapePath, 480, 270),
                                    channelLogoURL: imageURL(guide.channel.thumb, 256, 256)
                                )
                            }
                            .buttonStyle(.plain)
                            .duskTVOSFocusEffectShape(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
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

struct LiveTVProgramCard: View {
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
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var placeholder: some View {
        Color.duskSurface.overlay {
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

    private var cardWidth: CGFloat {
        #if os(tvOS)
        360
        #else
        260
        #endif
    }

    private var cardHeight: CGFloat {
        cardWidth * 9 / 16
    }
}

private struct LiveTVProgramDetails: View {
    @Environment(\.dismiss) private var dismiss
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
