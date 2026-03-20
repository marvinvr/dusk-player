import SwiftUI

struct SeasonDetailView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var viewModel: SeasonDetailViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.detailHorizontalPadding

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
            let heroBackgroundWidth: CGFloat = {
                #if os(tvOS)
                geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
                #else
                geometry.size.width
                #endif
            }()
            let heroBackgroundLeadingInset: CGFloat = {
                #if os(tvOS)
                geometry.safeAreaInsets.leading
                #else
                0
                #endif
            }()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection(
                        details,
                        topInset: geometry.safeAreaInsets.top,
                        containerWidth: heroBackgroundWidth,
                        containerHeight: geometry.size.height,
                        backgroundLeadingInset: heroBackgroundLeadingInset
                    )
#if os(tvOS)
                    .focusSection()
#endif

                    if let summary = details.summary, !summary.isEmpty {
                        ExpandableSummaryText(text: summary)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 36)
                    }

                    episodesSection(width: geometry.size.width)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 40)
                        .padding(.bottom, 56)
#if os(tvOS)
                        .focusSection()
#endif
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    @ViewBuilder
    private func heroSection(
        _ details: PlexMediaDetails,
        topInset: CGFloat,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        backgroundLeadingInset: CGFloat = 0
    ) -> some View {
        let heroBase = min(max(containerHeight * 0.72, 520), 760)
        let heroHeight = heroBase + topInset
        let posterWidth: CGFloat = {
            #if os(tvOS)
            DuskPosterMetrics.heroPosterWidth
            #else
            sizeClass == .regular ? 186 : 124
            #endif
        }()
        let posterImageWidth = Int(posterWidth.rounded())
        let posterHeight = Int((Double(posterWidth) * 1.5).rounded())
        DetailHeroSection(
            backdropURL: viewModel.backdropURL(width: Int(containerWidth.rounded(.up)), height: Int(heroHeight.rounded(.up))),
            posterURL: viewModel.posterURL(width: posterImageWidth, height: posterHeight),
            title: details.title,
            topInset: topInset,
            containerWidth: containerWidth,
            backgroundLeadingInset: backgroundLeadingInset,
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
        #if os(tvOS)
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.duskAccent)
        #else
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
        #endif
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
        SeasonHeroActions(
            nextEpisode: viewModel.nextEpisodeToPlay,
            playButtonLabel: viewModel.playButtonLabel,
            nextEpisodePlayableVersions: viewModel.nextEpisodePlayableVersions,
            nextEpisodeRoute: viewModel.nextEpisodeRoute,
            nextEpisodeMenuLabel: viewModel.nextEpisodeMenuLabel,
            showRatingKey: viewModel.showRatingKey,
            usesFullWidthActionButtons: usesFullWidthActionButtons,
            onPlay: { episode in
                Task { await playback.play(ratingKey: episode.ratingKey) }
            },
            onPlayVersion: { episode, version in
                Task { await playback.playVersion(ratingKey: episode.ratingKey, mediaID: version.id) }
            }
        )
    }

    private var usesFullWidthActionButtons: Bool {
        sizeClass == .compact
    }

    @ViewBuilder
    private func episodesSection(width: CGFloat) -> some View {
        if !viewModel.episodes.isEmpty {
            let contentWidth = max(width - (horizontalPadding * 2), 280)
            let artworkWidth: CGFloat = {
                #if os(tvOS)
                min(max(contentWidth * 0.56, 260), 420)
                #else
                min(max(contentWidth * 0.48, 170), 320)
                #endif
            }()
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
        #if os(tvOS)
        TVSeasonEpisodeRow(
            episode: episode,
            destination: destination,
            imageURL: imageURL,
            label: label,
            subtitle: subtitle,
            progress: progress,
            artworkWidth: artworkWidth,
            showsInlineSummary: showsInlineSummary
        )
        #else
        IOSSeasonEpisodeRow(
            episode: episode,
            destination: destination,
            imageURL: imageURL,
            label: label,
            subtitle: subtitle,
            progress: progress,
            artworkWidth: artworkWidth,
            showsInlineSummary: showsInlineSummary,
            onPlay: onPlay
        )
        #endif
    }
}

private struct SeasonHeroActions: View {
    let nextEpisode: PlexEpisode?
    let playButtonLabel: String
    let nextEpisodePlayableVersions: [PlexMedia]
    let nextEpisodeRoute: AppNavigationRoute?
    let nextEpisodeMenuLabel: String
    let showRatingKey: String?
    let usesFullWidthActionButtons: Bool
    let onPlay: (PlexEpisode) -> Void
    let onPlayVersion: (PlexEpisode, PlexMedia) -> Void

    var body: some View {
        let layout = usesFullWidthActionButtons
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            Button {
                guard let nextEpisode else { return }
                onPlay(nextEpisode)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(playButtonLabel)
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
                if let nextEpisode {
                    PlayVersionContextMenu(versions: nextEpisodePlayableVersions) { version in
                        onPlayVersion(nextEpisode, version)
                    }
                }

                if let nextEpisodeRoute {
                    NavigationLink(value: nextEpisodeRoute) {
                        Label(nextEpisodeMenuLabel, systemImage: "play.rectangle")
                    }
                }
            }

            #if os(tvOS)
            if let showRatingKey {
                NavigationLink(value: AppNavigationRoute.media(type: .show, ratingKey: showRatingKey)) {
                    DetailHeroSecondaryActionButtonLabel(
                        title: "Go to Show",
                        systemImage: "tv.fill"
                    )
                }
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(Capsule())
            }
            #endif
        }
    }
}

#if os(tvOS)
private struct TVSeasonEpisodeRow: View {
    let episode: PlexEpisode
    let destination: AppNavigationRoute
    let imageURL: URL?
    let label: String?
    let subtitle: String?
    let progress: Double?
    let artworkWidth: CGFloat
    let showsInlineSummary: Bool

    private let posterDetailsSpacing: CGFloat = 56

    private var artworkHeight: CGFloat {
        artworkWidth / (16.0 / 9.0)
    }

    private var artworkShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: posterDetailsSpacing) {
                NavigationLink(value: destination) {
                    SeasonEpisodePosterArtwork(
                        imageURL: imageURL,
                        progress: progress,
                        artworkWidth: artworkWidth,
                        showsPlayOverlay: false
                    )
                    .contentShape(.contextMenuPreview, artworkShape)
                }
                .buttonStyle(.card)
                .accessibilityLabel("View \(episode.title)")
                .frame(width: artworkWidth, height: artworkHeight, alignment: .leading)

                SeasonEpisodeTextContent(
                    episode: episode,
                    label: label,
                    subtitle: subtitle,
                    showsInlineSummary: true,
                    inlineSummaryLineLimit: 5
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            SeasonEpisodeDivider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif

private struct IOSSeasonEpisodeRow: View {
    let episode: PlexEpisode
    let destination: AppNavigationRoute
    let imageURL: URL?
    let label: String?
    let subtitle: String?
    let progress: Double?
    let artworkWidth: CGFloat
    let showsInlineSummary: Bool
    let onPlay: () -> Void

    private let posterDetailsSpacing: CGFloat = 18

    private var artworkHeight: CGFloat {
        artworkWidth / (16.0 / 9.0)
    }

    private var artworkShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: posterDetailsSpacing) {
                Button(action: onPlay) {
                    SeasonEpisodePosterArtwork(
                        imageURL: imageURL,
                        progress: progress,
                        artworkWidth: artworkWidth,
                        showsPlayOverlay: true
                    )
                }
                .buttonStyle(.plain)
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(artworkShape)
                .accessibilityLabel("Play \(episode.title)")
                .frame(width: artworkWidth, height: artworkHeight, alignment: .leading)

                NavigationLink(value: destination) {
                    SeasonEpisodeTextContent(
                        episode: episode,
                        label: label,
                        subtitle: subtitle,
                        showsInlineSummary: showsInlineSummary
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if !showsInlineSummary {
                NavigationLink(value: destination) {
                    SeasonEpisodeSummaryText(episode: episode, lineLimit: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(Rectangle())
            }

            SeasonEpisodeDivider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SeasonEpisodePosterArtwork: View {
    let imageURL: URL?
    let progress: Double?
    let artworkWidth: CGFloat
    let showsPlayOverlay: Bool

    var body: some View {
        PosterArtwork(
            imageURL: imageURL,
            progress: progress,
            width: artworkWidth,
            imageAspectRatio: 16.0 / 9.0,
            showsPlayOverlay: showsPlayOverlay
        )
    }
}

private struct SeasonEpisodeTextContent: View {
    let episode: PlexEpisode
    let label: String?
    let subtitle: String?
    let showsInlineSummary: Bool
    var inlineSummaryLineLimit: Int = 3

    var body: some View {
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
                SeasonEpisodeSummaryText(episode: episode, lineLimit: inlineSummaryLineLimit)
            }
        }
    }
}

private struct SeasonEpisodeSummaryText: View {
    let episode: PlexEpisode
    let lineLimit: Int

    @ViewBuilder
    var body: some View {
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
}

private struct SeasonEpisodeDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }
}
