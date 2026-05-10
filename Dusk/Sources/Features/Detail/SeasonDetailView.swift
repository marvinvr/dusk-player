import SwiftUI

struct SeasonDetailView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var viewModel: SeasonDetailViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.detailHorizontalPadding

    init(
        ratingKey: String,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        _viewModel = State(initialValue: SeasonDetailViewModel(
            ratingKey: ratingKey,
            plexService: plexService,
            downloadManager: downloadManager,
            offlinePlaybackSyncManager: offlinePlaybackSyncManager,
            prefersOfflineAvailability: prefersOfflineAvailability
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

                    if let offlineBannerText = viewModel.offlineBannerText {
                        OfflineMetadataBanner(message: offlineBannerText)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 24)
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
            NavigationLink(value: viewModel.detailRoute(type: .show, ratingKey: showRatingKey)) {
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
        let layout = usesFullWidthActionButtons
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            SeasonHeroActions(
                nextEpisode: viewModel.nextEpisodeToPlay,
                playButtonLabel: viewModel.playButtonLabel,
                nextEpisodePlayableVersions: viewModel.nextEpisodePlayableVersions,
                nextEpisodeRoute: viewModel.nextEpisodeRoute,
                nextEpisodeMenuLabel: viewModel.nextEpisodeMenuLabel,
                showRoute: viewModel.showRatingKey.map { viewModel.detailRoute(type: .show, ratingKey: $0) },
                usesFullWidthActionButtons: usesFullWidthActionButtons,
                onPlay: { episode in
                    Task { await playback.play(ratingKey: episode.ratingKey) }
                },
                onPlayVersion: { episode, version in
                    Task { await playback.playVersion(ratingKey: episode.ratingKey, mediaID: version.id) }
                }
            )

            DownloadActionButton(
                ratingKey: viewModel.ratingKey,
                type: .season,
                fillsWidth: usesFullWidthActionButtons
            )
        }
    }

    private var usesFullWidthActionButtons: Bool {
        usesFullWidthDetailActionButtons(for: sizeClass)
    }

    @ViewBuilder
    private func episodesSection(width: CGFloat) -> some View {
        if !viewModel.displayEpisodes.isEmpty {
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
                    ForEach(viewModel.displayEpisodes) { episode in
                        SeasonEpisodeRow(
                            episode: episode,
                            destination: viewModel.detailRoute(type: .episode, ratingKey: episode.ratingKey),
                            imageURL: viewModel.episodeImageURL(episode, width: imageWidth, height: imageHeight),
                            label: viewModel.episodeLabel(episode),
                            subtitle: viewModel.episodeSubtitle(episode),
                            progress: viewModel.progress(for: episode),
                            downloadStatus: viewModel.downloadStatus(for: episode),
                            isPlayableOffline: viewModel.isPlayableOffline(episode),
                            isUnavailableOffline: viewModel.isUnavailableOffline(episode),
                            isWatched: viewModel.isWatched(episode),
                            isUsingCachedData: viewModel.isUsingCachedData,
                            showsOfflineAvailability: viewModel.showsOfflineAvailability,
                            artworkWidth: artworkWidth,
                            showsInlineSummary: showsInlineSummary,
                            onPlay: {
                                guard !viewModel.isUsingCachedData || viewModel.isPlayableOffline(episode) else { return }
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
        if viewModel.isPartiallyWatched(episode) {
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
                viewModel.isWatched(episode) ? "Mark Unwatched" : "Mark Watched",
                systemImage: viewModel.isWatched(episode) ? "eye.slash" : "eye"
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
    let downloadStatus: DownloadStatus?
    let isPlayableOffline: Bool
    let isUnavailableOffline: Bool
    let isWatched: Bool
    let isUsingCachedData: Bool
    let showsOfflineAvailability: Bool
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
            downloadStatus: downloadStatus,
            isPlayableOffline: isPlayableOffline,
            isUnavailableOffline: isUnavailableOffline,
            isWatched: isWatched,
            isUsingCachedData: isUsingCachedData,
            showsOfflineAvailability: showsOfflineAvailability,
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
            downloadStatus: downloadStatus,
            isPlayableOffline: isPlayableOffline,
            isUnavailableOffline: isUnavailableOffline,
            isWatched: isWatched,
            isUsingCachedData: isUsingCachedData,
            showsOfflineAvailability: showsOfflineAvailability,
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
    let showRoute: AppNavigationRoute?
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
                DetailHeroPrimaryActionButtonLabel(
                    title: playButtonLabel,
                    systemImage: "play.fill",
                    fillsWidth: usesFullWidthActionButtons
                )
            }
            #if os(tvOS)
            .buttonStyle(.glassProminent)
            .tint(Color.duskAccent)
            #else
            .duskSuppressTVOSButtonChrome()
            #endif
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
            if let showRoute {
                NavigationLink(value: showRoute) {
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
    let downloadStatus: DownloadStatus?
    let isPlayableOffline: Bool
    let isUnavailableOffline: Bool
    let isWatched: Bool
    let isUsingCachedData: Bool
    let showsOfflineAvailability: Bool
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
                        showsPlayOverlay: false,
                        isUnavailableOffline: isUnavailableOffline
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
                    downloadStatus: downloadStatus,
                    isPlayableOffline: isPlayableOffline,
                    isUnavailableOffline: isUnavailableOffline,
                    isWatched: isWatched,
                    isUsingCachedData: isUsingCachedData,
                    showsOfflineAvailability: showsOfflineAvailability,
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
    let downloadStatus: DownloadStatus?
    let isPlayableOffline: Bool
    let isUnavailableOffline: Bool
    let isWatched: Bool
    let isUsingCachedData: Bool
    let showsOfflineAvailability: Bool
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
                        showsPlayOverlay: !isUsingCachedData || isPlayableOffline,
                        isUnavailableOffline: isUnavailableOffline
                    )
                }
                .buttonStyle(.plain)
                .disabled(isUsingCachedData && !isPlayableOffline)
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(artworkShape)
                .accessibilityLabel("Play \(episode.title)")
                .frame(width: artworkWidth, height: artworkHeight, alignment: .leading)

                NavigationLink(value: destination) {
                    SeasonEpisodeTextContent(
                        episode: episode,
                        label: label,
                        subtitle: subtitle,
                        downloadStatus: downloadStatus,
                        isPlayableOffline: isPlayableOffline,
                        isUnavailableOffline: isUnavailableOffline,
                        isWatched: isWatched,
                        isUsingCachedData: isUsingCachedData,
                        showsOfflineAvailability: showsOfflineAvailability,
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
    let isUnavailableOffline: Bool

    var body: some View {
        PosterArtwork(
            imageURL: imageURL,
            progress: progress,
            width: artworkWidth,
            imageAspectRatio: 16.0 / 9.0,
            showsPlayOverlay: showsPlayOverlay
        )
        .opacity(isUnavailableOffline ? 0.46 : 1)
    }
}

private struct SeasonEpisodeTextContent: View {
    let episode: PlexEpisode
    let label: String?
    let subtitle: String?
    let downloadStatus: DownloadStatus?
    let isPlayableOffline: Bool
    let isUnavailableOffline: Bool
    let isWatched: Bool
    let isUsingCachedData: Bool
    let showsOfflineAvailability: Bool
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

                if isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.duskAccent)
                }

                downloadStatusBadge
            }

            Text(episode.title)
                .font(.headline)
                .foregroundStyle(isUnavailableOffline ? Color.duskTextSecondary : Color.duskTextPrimary)
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

    @ViewBuilder
    private var downloadStatusBadge: some View {
        if isPlayableOffline {
            Label("Downloaded", systemImage: "arrow.down.circle.fill")
                .labelStyle(.iconOnly)
                .font(.caption)
                .foregroundStyle(Color.duskAccent)
        } else if showsOfflineAvailability {
            Text(isUsingCachedData ? "Unavailable Offline" : "Not Downloaded")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.duskTextSecondary)
        } else if let downloadStatus, downloadStatus != .completed {
            Text(downloadStatus.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(downloadStatus == .failed ? .red : Color.duskTextSecondary)
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
