import SwiftUI

struct ShowDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: ShowDetailViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.detailHorizontalPadding
    private let gridSpacing: CGFloat = DuskPosterMetrics.detailGridSpacing
    private let preferredPosterWidth: CGFloat = DuskPosterMetrics.detailGridPreferredWidth
    private let minimumColumnCount = 2

    init(
        ratingKey: String,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        _viewModel = State(initialValue: ShowDetailViewModel(
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

                    if detailShowsSynopsisBelowHero(for: sizeClass), let summary = details.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(Color.primary.opacity(0.76))
                            .lineSpacing(4)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 32)
                    }

                    if let offlineBannerText = viewModel.offlineBannerText {
                        OfflineMetadataBanner(message: offlineBannerText)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 24)
                    }

                    seasonsSection(width: geometry.size.width)
                        .padding(.top, 40)
#if os(tvOS)
                        .focusSection()
#endif

                    if let roles = details.roles, !roles.isEmpty {
                        DetailCastSection(roles: roles, plexService: plexService)
                            .padding(.top, 40)
                            .padding(.bottom, 56)
                    }
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .duskTVOSPageBackground()
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
        DetailHeroSection(
            backdropURL: viewModel.backdropURL(width: Int(containerWidth.rounded(.up)), height: Int(heroHeight.rounded(.up))),
            titleArtworkURL: viewModel.titleLogoURL(width: Int((containerWidth * 0.45).rounded(.up)), height: 128),
            title: details.title,
            descriptionText: details.summary,
            topInset: topInset,
            containerWidth: containerWidth,
            backgroundLeadingInset: backgroundLeadingInset,
            heroBaseHeight: heroBase
        ) {
            VStack(alignment: detailHeroContentAlignment(for: sizeClass), spacing: 6) {
                metadataTagline(details)
                heroMetadata(details)
            }
            .multilineTextAlignment(detailHeroTextAlignment(for: sizeClass))
        } actions: {
            actionButtons()
        }
    }

    @ViewBuilder
    private func metadataTagline(_ details: PlexMediaDetails) -> some View {
        let parts = [
            details.year.map(String.init),
            details.contentRating,
            viewModel.seasonCountText,
            viewModel.episodeCountText,
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary.opacity(0.78))
        }
    }

    @ViewBuilder
    private func heroMetadata(_ details: PlexMediaDetails) -> some View {
        if let genres = viewModel.genreText {
            Text(genres)
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.72))
        }

        if let rating = details.rating {
            HStack(spacing: 12) {
                ratingBadge(
                    icon: "star.fill",
                    value: String(format: "%.1f", rating),
                    color: .yellow
                )

                if let audience = details.audienceRating {
                    ratingBadge(
                        icon: "person.fill",
                        value: String(format: "%.0f%%", audience * 10),
                        color: Color.duskAccent
                    )
                }
            }
        }

        if let studio = details.studio {
            Text(studio)
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.72))
        }
    }

    private func ratingBadge(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)

            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.84))
        }
    }

    @ViewBuilder
    private func actionButtons() -> some View {
        #if os(tvOS)
        HStack(spacing: detailHeroActionSpacing) {
            playButton()
            downloadButton()
            watchedButton()
        }
        #else
        // Primary fills the stack width; secondary row is centered beneath it.
        VStack(alignment: .center, spacing: detailHeroActionSpacing) {
            playButton()

            HStack(spacing: detailHeroActionSpacing) {
                downloadButton()
                watchedButton()
            }
        }
        .detailHeroActionStackFrame(isCompactPhone: usesFullWidthActionButtons)
        #endif
    }

    @ViewBuilder
    private func playButton() -> some View {
        if viewModel.nextEpisode != nil {
            Button {
                if let ep = viewModel.nextEpisode {
                    Task { await playback.play(ratingKey: ep.ratingKey, placeholder: PlaybackPlaceholder(episode: ep)) }
                }
            } label: {
                DetailHeroPrimaryActionButtonLabel(
                    title: viewModel.playButtonShortLabel,
                    systemImage: "play.fill",
                    fillsWidth: fillsActionWidth
                )
            }
            .detailHeroNativePrimaryButtonStyle()
            .contextMenu {
                if let episode = viewModel.nextEpisode {
                    PlayVersionContextMenu(versions: viewModel.nextEpisodePlayableVersions) { version in
                        Task { await playback.playVersion(ratingKey: episode.ratingKey, mediaID: version.id, placeholder: PlaybackPlaceholder(episode: episode)) }
                    }
                }

                if let nextEpisodeRoute = viewModel.nextEpisodeRoute {
                    NavigationLink(value: nextEpisodeRoute) {
                        Label(viewModel.nextEpisodeMenuLabel, systemImage: "play.rectangle")
                    }
                }

                if let nextSeasonRoute = viewModel.nextSeasonRoute {
                    NavigationLink(value: nextSeasonRoute) {
                        Label(viewModel.nextSeasonMenuLabel, systemImage: "rectangle.stack")
                    }
                }
            }
        }
    }

    private func downloadButton() -> some View {
        DownloadActionButton(
            ratingKey: viewModel.ratingKey,
            type: .show,
            iconOnly: true
        )
    }

    private func watchedButton() -> some View {
        Button {
            Task { await viewModel.toggleWatched() }
        } label: {
            DetailHeroSecondaryIconLabel(systemImage: viewModel.isWatched ? "eye.slash" : "eye")
        }
        .detailHeroNativeSecondaryButtonStyle()
        .accessibilityLabel(viewModel.isWatched ? "Mark Unwatched" : "Mark Watched")
    }

    private var usesFullWidthActionButtons: Bool {
        usesFullWidthDetailActionButtons(for: sizeClass)
    }

    // The primary label fills its container on all iOS layouts (the action stack
    // owns the final width); tvOS keeps content-sized buttons in an inline row.
    private var fillsActionWidth: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    @ViewBuilder
    private func seasonsSection(width: CGFloat) -> some View {
        if !viewModel.visibleSeasons.isEmpty {
            let layout = AdaptivePosterGridLayout.make(
                containerWidth: width,
                horizontalPadding: horizontalPadding,
                gridSpacing: gridSpacing,
                preferredPosterWidth: preferredPosterWidth,
                minimumColumnCount: minimumColumnCount
            )
            let imageWidth = Int(layout.posterWidth.rounded(.up))
            let imageHeight = Int((layout.posterWidth * 1.5).rounded(.up))

            VStack(alignment: .leading, spacing: 16) {
                Text("Seasons")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, horizontalPadding)

                LazyVGrid(columns: layout.columns, alignment: .leading, spacing: DuskPosterMetrics.detailGridRowSpacing) {
                    ForEach(viewModel.visibleSeasons) { season in
                        PosterNavigationCard(
                            route: viewModel.detailRoute(type: .season, ratingKey: season.ratingKey),
                            imageURL: viewModel.seasonPosterURL(season, width: imageWidth, height: imageHeight),
                            title: season.title,
                            subtitle: viewModel.seasonSubtitle(season),
                            progress: viewModel.seasonProgress(season),
                            width: layout.posterWidth,
                            availabilityBadge: viewModel.seasonAvailabilityBadge(season),
                            isDimmed: viewModel.isSeasonUnavailableOffline(season),
                            isWatched: season.isFullyWatched
                        ) {
                            seasonContextMenu(season)
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
            }
        }
    }

    @ViewBuilder
    private func seasonContextMenu(_ season: PlexSeason) -> some View {
        let downloadState = downloadManager.downloadState(for: DownloadScope(ratingKey: season.ratingKey, type: .season))

        if !season.isFullyWatched {
            Button {
                Task { await viewModel.markSeason(season, watched: true) }
            } label: {
                Label("Mark Watched", systemImage: "eye")
            }
        }

        Button {
            Task { await viewModel.markSeason(season, watched: false) }
        } label: {
            Label("Mark Unwatched", systemImage: "eye.slash")
        }

        if !downloadState.isDeleting && downloadState.canDelete {
            Button(role: .destructive) {
                downloadManager.deleteDownload(scope: downloadState.scope)
            } label: {
                Label("Delete Season Download", systemImage: "trash")
            }
        }
    }
}
