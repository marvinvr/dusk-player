#if !os(tvOS)
import SwiftUI

struct SeasonDetailView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: SeasonDetailViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.detailHorizontalPadding

    init(
        id: PlexItemID,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        _viewModel = State(initialValue: SeasonDetailViewModel(
            id: id,
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
        .onChange(of: playback.showPlayer) { _, isShowing in
            if !isShowing {
                Task { await viewModel.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, viewModel.details != nil else { return }
            Task { await viewModel.refresh() }
        }
    }

    @ViewBuilder
    private func contentView(_ details: PlexMediaDetails) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection(
                        details,
                        topInset: geometry.safeAreaInsets.top,
                        containerWidth: geometry.size.width,
                        containerHeight: geometry.size.height
                    )

                    if detailShowsSynopsisBelowHero(for: sizeClass), let summary = details.summary, !summary.isEmpty {
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
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func heroSection(
        _ details: PlexMediaDetails,
        topInset: CGFloat,
        containerWidth: CGFloat,
        containerHeight: CGFloat
    ) -> some View {
        let heroBase = min(max(containerHeight * 0.72, 520), 760)
        let heroHeight = heroBase + topInset
        DetailHeroSection(
            backdropURL: viewModel.backdropURL(width: Int(containerWidth.rounded(.up)), height: Int(heroHeight.rounded(.up))),
            title: details.title,
            descriptionText: details.summary,
            topInset: topInset,
            containerWidth: containerWidth,
            heroBaseHeight: heroBase,
            supertitle: {
                if let showTitle = viewModel.showTitle {
                    DetailHeroShowTitleLink(
                        title: showTitle,
                        logoURL: viewModel.showTitleLogoURL(
                            width: Int((containerWidth * 0.5).rounded(.up)),
                            height: 128
                        ),
                        showRoute: viewModel.showID.map {
                            viewModel.detailRoute(type: .show, id: $0)
                        }
                    )
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
    private func metadataTagline(_ details: PlexMediaDetails) -> some View {
        let parts = [
            viewModel.episodeCountText,
            viewModel.watchedEpisodeCountText,
            details.contentRating,
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(DuskFont.metadata(ios: .subheadline.weight(.medium)))
                .foregroundStyle(Color.primary.opacity(0.78))
        }
    }

    @ViewBuilder
    private func actionButtons() -> some View {
        // Primary fills the stack width; secondary row is centered beneath it.
        VStack(alignment: .center, spacing: detailHeroActionSpacing) {
            seasonPlayActions(label: viewModel.playButtonShortLabel)

            HStack(spacing: detailHeroActionSpacing) {
                DownloadActionButton(
                    id: viewModel.id,
                    type: .season,
                    iconOnly: true
                )
                watchedButton()
            }
        }
        .detailHeroActionStackFrame(isCompactPhone: usesFullWidthDetailActionButtons(for: sizeClass))
    }

    private func seasonPlayActions(label: String) -> some View {
        SeasonHeroActions(
            nextEpisode: viewModel.nextEpisodeToPlay,
            playButtonLabel: label,
            nextEpisodePlayableVersions: viewModel.nextEpisodePlayableVersions,
            nextEpisodeRoute: viewModel.nextEpisodeRoute,
            nextEpisodeMenuLabel: viewModel.nextEpisodeMenuLabel,
            onPlay: { episode in
                guard !viewModel.constrainsPlaybackToOfflineAvailability || viewModel.isPlayableOffline(episode) else { return }
                Task {
                    await playback.play(
                        id: episode.id,
                        resumeOffsetMilliseconds: episode.viewOffset,
                        resumeOffsetDurationMilliseconds: episode.duration,
                        placeholder: PlaybackPlaceholder(episode: episode)
                    )
                }
            },
            onPlayVersion: { episode, version in
                Task {
                    await playback.playVersion(
                        id: episode.id,
                        mediaID: version.id,
                        resumeOffsetMilliseconds: episode.viewOffset,
                        placeholder: PlaybackPlaceholder(episode: episode)
                    )
                }
            }
        )
    }

    private func watchedButton() -> some View {
        Button {
            Task { await viewModel.toggleSeasonWatched() }
        } label: {
            DetailHeroSecondaryIconLabel(systemImage: viewModel.isSeasonWatched ? "eye.slash" : "eye")
        }
        .detailHeroNativeSecondaryButtonStyle()
        .accessibilityLabel(viewModel.isSeasonWatched ? "Mark Season Unwatched" : "Mark Season Watched")
    }

    @ViewBuilder
    private func episodesSection(width: CGFloat) -> some View {
        if !viewModel.displayEpisodes.isEmpty {
            let contentWidth = max(width - (horizontalPadding * 2), 280)
            let artworkWidth = min(max(contentWidth * 0.48, 170), 320)
            let imageWidth = Int(artworkWidth.rounded(.up))
            let imageHeight = Int((artworkWidth / (16.0 / 9.0)).rounded(.up))
            let showsInlineSummary = usesInlineEpisodeSummaryLayout && contentWidth >= 700

            VStack(alignment: .leading, spacing: 16) {
                Text("Episodes")
                    .font(DuskFont.sectionHeader(ios: .headline))
                    .foregroundStyle(Color.primary)

                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(viewModel.displayEpisodes) { episode in
                        SeasonEpisodeRow(
                            episode: episode,
                            destination: viewModel.detailRoute(type: .episode, id: episode.id),
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
                            constrainsPlaybackToOfflineAvailability: viewModel.constrainsPlaybackToOfflineAvailability,
                            artworkWidth: artworkWidth,
                            showsInlineSummary: showsInlineSummary,
                            onPlay: {
                                guard !viewModel.constrainsPlaybackToOfflineAvailability || viewModel.isPlayableOffline(episode) else { return }
                                Task {
                                    await playback.play(
                                        id: episode.id,
                                        resumeOffsetMilliseconds: episode.viewOffset,
                                        resumeOffsetDurationMilliseconds: episode.duration,
                                        placeholder: PlaybackPlaceholder(episode: episode)
                                    )
                                }
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
        UIDevice.current.userInterfaceIdiom == .pad
    }

    @ViewBuilder
    private func episodeContextMenu(_ episode: PlexEpisode) -> some View {
        let downloadState = downloadManager.downloadState(for: DownloadScope(id: episode.id, type: .episode))

        if viewModel.isPartiallyWatched(episode) {
            Button {
                Task { await playback.playFromStart(id: episode.id, placeholder: PlaybackPlaceholder(episode: episode)) }
            } label: {
                Label("Play from Start", systemImage: "arrow.counterclockwise")
            }
        }

        if viewModel.isPartiallyWatched(episode) {
            Button {
                Task { await viewModel.setWatched(true, for: episode) }
            } label: {
                Label("Mark Watched", systemImage: "eye")
            }

            Button {
                Task { await viewModel.setWatched(false, for: episode) }
            } label: {
                Label("Mark Unwatched", systemImage: "eye.slash")
            }
        } else {
            Button {
                Task { await viewModel.toggleWatched(for: episode) }
            } label: {
                Label(
                    viewModel.isWatched(episode) ? "Mark Unwatched" : "Mark Watched",
                    systemImage: viewModel.isWatched(episode) ? "eye.slash" : "eye"
                )
            }
        }

        if DownloadsFeature.isVisible {
            if downloadState.hasRecords {
                DownloadContextMenuContent(
                    state: downloadState,
                    showsDelete: downloadState.canDelete,
                    showsCancel: downloadState.canCancel,
                    onPause: { downloadManager.pauseDownload(scope: downloadState.scope) },
                    onResume: { downloadManager.resumeDownload(scope: downloadState.scope) },
                    onCancel: { downloadManager.cancelDownload(scope: downloadState.scope) },
                    onDelete: { downloadManager.deleteDownload(scope: downloadState.scope) },
                    onRetry: { downloadManager.retryDownload(id: episode.id) }
                )
            } else {
                Button {
                    Task {
                        await downloadManager.queueDownload(episode: episode)
                    }
                } label: {
                    Label("Download Episode", systemImage: "arrow.down.circle")
                }
            }
        }
    }

}

private struct SeasonHeroActions: View {
    let nextEpisode: PlexEpisode?
    let playButtonLabel: String
    let nextEpisodePlayableVersions: [PlexMedia]
    let nextEpisodeRoute: AppNavigationRoute?
    let nextEpisodeMenuLabel: String
    let onPlay: (PlexEpisode) -> Void
    let onPlayVersion: (PlexEpisode, PlexMedia) -> Void

    var body: some View {
        Button {
            guard let nextEpisode else { return }
            onPlay(nextEpisode)
        } label: {
            DetailHeroPrimaryActionButtonLabel(
                title: playButtonLabel,
                systemImage: "play.fill",
                fillsWidth: true
            )
        }
        .detailHeroNativePrimaryButtonStyle()
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
    let constrainsPlaybackToOfflineAvailability: Bool
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
                        showsPlayOverlay: !constrainsPlaybackToOfflineAvailability || isPlayableOffline,
                        isUnavailableOffline: isUnavailableOffline
                    )
                }
                .buttonStyle(.plain)
                .disabled(constrainsPlaybackToOfflineAvailability && !isPlayableOffline)
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
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if !showsInlineSummary {
                NavigationLink(value: destination) {
                    SeasonEpisodeSummaryText(episode: episode, lineLimit: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let label, !label.isEmpty {
                    Text(label)
                        .font(DuskFont.caption(ios: .caption.weight(.semibold)))
                        .foregroundStyle(Color.primary.opacity(0.78))
                }

                if isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(DuskFont.glyphSmall(ios: .caption))
                        .foregroundStyle(Color.duskAccent)
                }

                downloadStatusBadge
            }

            Text(episode.title)
                .font(DuskFont.rowTitle(ios: .headline))
                .foregroundStyle(isUnavailableOffline ? Color.primary.opacity(0.55) : Color.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(DuskFont.caption(ios: .caption))
                    .foregroundStyle(Color.primary.opacity(0.76))
            }

            if showsInlineSummary {
                SeasonEpisodeSummaryText(episode: episode, lineLimit: 3)
            }
        }
    }

    @ViewBuilder
    private var downloadStatusBadge: some View {
        if !DownloadsFeature.isVisible {
            EmptyView()
        } else if isPlayableOffline {
            Label("Downloaded", systemImage: "arrow.down.circle.fill")
                .labelStyle(.iconOnly)
                .font(DuskFont.glyphSmall(ios: .caption))
                .foregroundStyle(Color.duskAccent)
        } else if showsOfflineAvailability {
            Text(isUsingCachedData ? "Unavailable Offline" : "Not Downloaded")
                .font(DuskFont.badge(ios: .caption2.weight(.semibold)))
                .foregroundStyle(Color.duskTextSecondary)
        } else if let downloadStatus, downloadStatus != .completed {
            Text(downloadStatus.displayName)
                .font(DuskFont.badge(ios: .caption2.weight(.semibold)))
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
                .font(DuskFont.body(ios: .subheadline))
                .foregroundStyle(Color.primary.opacity(0.76))
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
#endif
