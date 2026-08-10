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
                    play(program: program)
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
                        play: { play(program: $0, channel: guide.channel) }
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
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(
                                Calendar.current.isDate(date, inSameDayAs: viewModel.selectedDate)
                                    ? Color.duskBackground
                                    : Color.duskTextPrimary
                            )
                            .padding(.horizontal, 18)
                            .frame(height: 42)
                            .background(
                                Calendar.current.isDate(date, inSameDayAs: viewModel.selectedDate)
                                    ? Color.duskAccent
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

    private func play(program: PlexLiveProgram, channel preferredChannel: PlexLiveChannel? = nil) {
        guard program.isAiring(),
              let lineup = viewModel.lineup,
              let channel = preferredChannel ?? channel(for: program) else { return }
        Task {
            await playback.playLiveTV(channel: channel, program: program, lineup: lineup)
        }
    }

    private func channel(for program: PlexLiveProgram) -> PlexLiveChannel? {
        viewModel.lineup?.channels.first {
            $0.gridKey == program.channelGridKey ||
                $0.id == program.channelIdentifier
        }
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
    let play: (PlexLiveProgram) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                channelLogo

                VStack(alignment: .leading, spacing: 2) {
                    Text(guide.channel.displayTitle)
                        .font(.headline)
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(1)
                    if let number = guide.channel.displayNumber {
                        Text(number)
                            .font(.subheadline)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }

                Spacer()

                if let current = guide.currentProgram() {
                    Button {
                        play(current)
                    } label: {
                        Label("Watch", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.duskAccent)
                }
            }

            if guide.programs.isEmpty {
                Text("No program information")
                    .font(.subheadline)
                    .foregroundStyle(Color.duskTextSecondary)
                    .frame(height: 120)
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
    let program: PlexLiveProgram
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
                Text(program.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let beginsAt = program.beginsAt, let endsAt = program.endsAt {
                    Text("\(beginsAt.formatted(date: .omitted, time: .shortened)) – \(endsAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .foregroundStyle(.white)
            .padding(12)

            if let progress = program.progress(), program.isAiring() {
                VStack {
                    Spacer()
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.duskAccent)
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
            .font(.title2)
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
                        .font(.title.bold())
                        .foregroundStyle(Color.duskTextPrimary)
                    if let subtitle = program.displaySubtitle {
                        Text(subtitle)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                    if let channel {
                        Label(
                            [channel.displayNumber, channel.displayTitle]
                                .compactMap { $0 }
                                .joined(separator: " · "),
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                        .foregroundStyle(Color.duskTextSecondary)
                    }
                    if let beginsAt = program.beginsAt, let endsAt = program.endsAt {
                        Text("\(beginsAt.formatted(date: .abbreviated, time: .shortened)) – \(endsAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                    if let summary = program.summary?.nilIfEmpty {
                        Text(summary)
                            .foregroundStyle(Color.duskTextPrimary)
                    }
                    if canPlay {
                        Button(action: play) {
                            Label("Watch Live", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.duskAccent)
                    } else {
                        Text(program.endsAt.map { $0 < .now } == true
                            ? "This program is no longer live."
                            : "This program hasn’t started yet.")
                            .font(.subheadline)
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
