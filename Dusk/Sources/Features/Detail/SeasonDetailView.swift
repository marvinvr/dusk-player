import SwiftUI

struct SeasonDetailView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var viewModel: SeasonDetailViewModel

    private let horizontalPadding: CGFloat = 20

    init(ratingKey: String, plexService: PlexService) {
        _viewModel = State(initialValue: SeasonDetailViewModel(
            ratingKey: ratingKey,
            plexService: plexService
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.details == nil {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.details == nil {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else if let details = viewModel.details {
                contentView(details)
            }
        }
        .duskNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private func contentView(_ details: PlexMediaDetails) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection(details, topInset: geometry.safeAreaInsets.top, containerWidth: geometry.size.width, containerHeight: geometry.size.height)

                    if let summary = details.summary, !summary.isEmpty {
                        ExpandableSummaryText(text: summary)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 20)
                    }

                    episodesSection(width: geometry.size.width)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 24)
                        .padding(.bottom, 40)
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func heroSection(_ details: PlexMediaDetails, topInset: CGFloat, containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
        let heroBase = min(max(containerHeight * 0.72, 520), 760)
        let heroHeight = heroBase + topInset
        let posterWidth = sizeClass == .regular ? 186 : 124
        let posterHeight = Int((Double(posterWidth) * 1.5).rounded())
        DetailHeroSection(
            backdropURL: viewModel.backdropURL(width: Int(containerWidth.rounded(.up)), height: Int(heroHeight.rounded(.up))),
            posterURL: viewModel.posterURL(width: posterWidth, height: posterHeight),
            title: details.title,
            topInset: topInset,
            containerWidth: containerWidth,
            heroBaseHeight: heroBase,
            posterWidth: CGFloat(posterWidth),
            supertitle: {
                if let showTitle = viewModel.showTitle {
                    showTitleLink(showTitle)
                }
            },
            subtitle: {
                metadataTagline(details)
            },
            actions: {
                if viewModel.nextEpisodeToPlay != nil {
                    actionButtons()
                }
            }
        )
    }

    @ViewBuilder
    private func showTitleLink(_ title: String) -> some View {
        if let showRatingKey = viewModel.showRatingKey {
            NavigationLink(value: AppNavigationRoute.media(type: .show, ratingKey: showRatingKey)) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.duskAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .duskSuppressTVOSButtonChrome()
        } else {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.duskAccent)
        }
    }

    @ViewBuilder
    private func metadataTagline(_ details: PlexMediaDetails) -> some View {
        let parts = [
            viewModel.episodeCountText,
            viewModel.watchedEpisodeCountText,
            details.contentRating,
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.76))
        }
    }

    @ViewBuilder
    private func actionButtons() -> some View {
        Button {
            if let ep = viewModel.nextEpisodeToPlay {
                Task { await playback.play(ratingKey: ep.ratingKey) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(viewModel.playButtonLabel)
            }
            .font(.headline)
            .frame(maxWidth: usesFullWidthActionButtons ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, usesFullWidthActionButtons ? 0 : 18)
            .background(Color.duskAccent)
            .foregroundStyle(.white)
            .clipShape(Capsule())
        }
        .duskSuppressTVOSButtonChrome()
        .contextMenu {
            if let episode = viewModel.nextEpisodeToPlay {
                PlayVersionContextMenu(versions: viewModel.nextEpisodePlayableVersions) { version in
                    Task { await playback.playVersion(ratingKey: episode.ratingKey, mediaID: version.id) }
                }
            }

            if let nextEpisodeRoute = viewModel.nextEpisodeRoute {
                NavigationLink(value: nextEpisodeRoute) {
                    Label(viewModel.nextEpisodeMenuLabel, systemImage: "play.rectangle")
                }
            }
        }
    }

    private var usesFullWidthActionButtons: Bool {
        sizeClass == .compact
    }

    @ViewBuilder
    private func episodesSection(width: CGFloat) -> some View {
        if !viewModel.episodes.isEmpty {
            let contentWidth = max(width - (horizontalPadding * 2), 280)
            let artworkWidth = min(max(contentWidth * 0.48, 170), 320)
            let imageWidth = Int(artworkWidth.rounded(.up))
            let imageHeight = Int((artworkWidth / (16.0 / 9.0)).rounded(.up))
            let showsInlineSummary = usesInlineEpisodeSummaryLayout && contentWidth >= 700

            VStack(alignment: .leading, spacing: 16) {
                Text("Episodes")
                    .font(.headline)
                    .foregroundStyle(Color.duskTextPrimary)

                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(viewModel.episodes) { episode in
                        SeasonEpisodeRow(
                            episode: episode,
                            destination: AppNavigationRoute.media(type: .episode, ratingKey: episode.ratingKey),
                            imageURL: viewModel.episodeImageURL(episode, width: imageWidth, height: imageHeight),
                            label: viewModel.episodeLabel(episode),
                            subtitle: viewModel.episodeSubtitle(episode),
                            progress: viewModel.progress(for: episode),
                            artworkWidth: artworkWidth,
                            showsInlineSummary: showsInlineSummary,
                            onPlay: {
                                Task { await playback.play(ratingKey: episode.ratingKey) }
                            }
                        )
                        .id(episode.ratingKey)
                        .contextMenu {
                            episodeContextMenu(episode)
                        }
                    }
                }
            }
        }
    }

    private var usesInlineEpisodeSummaryLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    @ViewBuilder
    private func episodeContextMenu(_ episode: PlexEpisode) -> some View {
        if episode.isPartiallyWatched {
            Button {
                Task { await playback.playFromStart(ratingKey: episode.ratingKey) }
            } label: {
                Label("Play from Start", systemImage: "arrow.counterclockwise")
            }
        }

        Button {
            Task { await viewModel.toggleWatched(for: episode) }
        } label: {
            Label(
                episode.isWatched ? "Mark Unwatched" : "Mark Watched",
                systemImage: episode.isWatched ? "eye.slash" : "eye"
            )
        }
    }

}

private struct SeasonEpisodeRow: View {
    let episode: PlexEpisode
    let destination: AppNavigationRoute
    let imageURL: URL?
    let label: String?
    let subtitle: String?
    let progress: Double?
    let artworkWidth: CGFloat
    let showsInlineSummary: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                Button(action: onPlay) {
                    artwork
                }
                .frame(width: artworkWidth, height: artworkWidth / (16.0 / 9.0), alignment: .leading)
                .buttonStyle(.plain)
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityLabel("Play \(episode.title)")

                episodeLink {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let label, !label.isEmpty {
                                Text(label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.duskTextSecondary)
                            }

                            if episode.isWatched {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.duskAccent)
                            }
                        }

                        Text(episode.title)
                            .font(.headline)
                            .foregroundStyle(Color.duskTextPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(Color.duskTextSecondary)
                        }

                        if showsInlineSummary {
                            summaryText(lineLimit: 3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if !showsInlineSummary && hasSummary {
                episodeLink {
                    summaryText(lineLimit: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func episodeLink<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationLink(value: destination) {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .duskSuppressTVOSButtonChrome()
        .duskTVOSFocusEffectShape(Rectangle())
    }

    @ViewBuilder
    private func summaryText(lineLimit: Int) -> some View {
        if let summary = episode.summary, !summary.isEmpty {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(Color.duskTextSecondary)
                .lineSpacing(4)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasSummary: Bool {
        episode.summary?.isEmpty == false
    }

    @ViewBuilder
    private var artwork: some View {
        PosterArtwork(
            imageURL: imageURL,
            progress: progress,
            width: artworkWidth,
            imageAspectRatio: 16.0 / 9.0,
            showsPlayOverlay: true
        )
    }
}
