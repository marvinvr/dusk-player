import SwiftUI

struct EpisodeDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: EpisodeDetailViewModel

    init(
        ratingKey: String,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil
    ) {
        _viewModel = State(initialValue: EpisodeDetailViewModel(
            ratingKey: ratingKey,
            plexService: plexService,
            downloadManager: downloadManager,
            offlinePlaybackSyncManager: offlinePlaybackSyncManager
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

                    if let summary = details.summary, !summary.isEmpty {
                        ExpandableSummaryText(
                            text: summary,
                            collapsedLineLimit: episodeSummaryCollapsedLineLimit,
                            foregroundStyle: episodeSummaryForegroundStyle,
                            allowsExpansion: episodeSummaryAllowsExpansion
                        )
                            .padding(.horizontal, 20)
                            .padding(.top, 24)
#if os(tvOS)
                            .focusSection()
#endif
                    }

                    if let offlineBannerText = viewModel.offlineBannerText {
                        OfflineMetadataBanner(message: offlineBannerText)
                            .padding(.horizontal, 20)
                            .padding(.top, 24)
                    }

                    if let roles = details.roles, !roles.isEmpty {
                        DetailCastSection(roles: roles, plexService: plexService)
                            .padding(.top, 24)
                    }
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
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
            posterURL: nil,
            title: details.title,
            topInset: topInset,
            containerWidth: containerWidth,
            backgroundLeadingInset: backgroundLeadingInset,
            heroBaseHeight: heroBase,
            posterWidth: DuskPosterMetrics.heroPosterWidth,
            supertitle: {
                if let showTitle = viewModel.showTitle {
                    showTitleLink(showTitle)
                }
            },
            subtitle: {
                VStack(alignment: .leading, spacing: 6) {
                    episodeMarkerRow()
                    metadataTagline(details)
                    heroMetadata(details)
                }
            },
            actions: {
                actionButtons(details)
            }
        )
    }

    @ViewBuilder
    private func episodeMarkerRow() -> some View {
        let seasonLabel = viewModel.seasonLabel
        let episodeLabel = viewModel.episodeLabel

        if seasonLabel != nil || episodeLabel != nil {
            HStack(spacing: 0) {
                if let seasonLabel {
                    seasonMetadataLink(seasonLabel)
                }

                if seasonLabel != nil, episodeLabel != nil {
                    metadataSeparator
                }

                if let episodeLabel {
                    metadataMarkerText(episodeLabel)
                }
            }
        }
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
    private func seasonMetadataLink(_ title: String) -> some View {
#if os(tvOS)
        metadataMarkerText(title)
#else
        if let seasonRatingKey = viewModel.seasonRatingKey {
            NavigationLink(value: AppNavigationRoute.media(type: .season, ratingKey: seasonRatingKey)) {
                metadataMarkerText(title)
            }
            .buttonStyle(.plain)
            .duskSuppressTVOSButtonChrome()
        } else {
            metadataMarkerText(title)
        }
#endif
    }

    private func metadataMarkerText(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.primary.opacity(0.82))
    }

    private var metadataSeparator: some View {
        Text(" · ")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.primary.opacity(0.56))
    }

    @ViewBuilder
    private func metadataTagline(_ details: PlexMediaDetails) -> some View {
        let parts = [
            details.contentRating,
            viewModel.formattedDuration,
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary.opacity(0.78))
        }
    }

    @ViewBuilder
    private func heroMetadata(_ details: PlexMediaDetails) -> some View {
        if let originalDate = MediaTextFormatter.localizedAirDate(details.originallyAvailableAt) {
            Text(originalDate)
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.72))
        }

        if let rating = details.rating {
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text(String(format: "%.1f", rating))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.84))
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ details: PlexMediaDetails) -> some View {
        if usesFullWidthActionButtons {
            VStack(spacing: detailHeroActionSpacing) {
                playButton(details)

                HStack(spacing: detailHeroActionSpacing) {
                    downloadButton(details, fillsWidth: true)
                    watchedButton(fillsWidth: true)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: detailHeroActionSpacing) {
                playButton(details)
                downloadButton(details, fillsWidth: false)
                episodeNavigationButton()
                watchedButton(fillsWidth: false)
            }
        }
    }

    private func playButton(_ details: PlexMediaDetails) -> some View {
        Button {
            guard !viewModel.isUsingCachedData || viewModel.isPlayableOffline else { return }
            Task { await playback.play(ratingKey: details.ratingKey) }
        } label: {
            DetailHeroPrimaryActionButtonLabel(
                title: "Play Episode",
                systemImage: "play.fill",
                fillsWidth: usesFullWidthActionButtons
            )
        }
        .detailHeroNativePrimaryButtonStyle()
        .disabled(viewModel.isUsingCachedData && !viewModel.isPlayableOffline)
        .contextMenu {
            if !viewModel.isUsingCachedData || viewModel.isPlayableOffline {
                PlayVersionContextMenu(versions: details.media) { version in
                    Task { await playback.playVersion(ratingKey: details.ratingKey, mediaID: version.id) }
                }
            }
        }
    }

    private func downloadButton(_ details: PlexMediaDetails, fillsWidth: Bool) -> some View {
        DownloadActionButton(
            ratingKey: details.ratingKey,
            type: .episode,
            fillsWidth: fillsWidth
        )
    }

    @ViewBuilder
    private func episodeNavigationButton() -> some View {
        #if os(tvOS)
        if let seasonRatingKey = viewModel.seasonRatingKey {
            NavigationLink(value: AppNavigationRoute.media(type: .season, ratingKey: seasonRatingKey)) {
                DetailHeroSecondaryActionButtonLabel(
                    title: "Go to Season",
                    systemImage: "rectangle.stack.fill"
                )
            }
            .detailHeroNativeSecondaryButtonStyle()
        }
        #else
        EmptyView()
        #endif
    }

    private func watchedButton(fillsWidth: Bool) -> some View {
        Button {
            Task { await viewModel.toggleWatched() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: viewModel.isWatched ? "eye.slash" : "eye")
                Text(viewModel.isWatched ? "Mark Unwatched" : "Mark Watched")
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 32)
            .contentShape(Capsule())
        }
        .detailHeroNativeSecondaryButtonStyle()
    }

    private var usesFullWidthActionButtons: Bool {
        usesFullWidthDetailActionButtons(for: sizeClass)
    }

    private var episodeSummaryCollapsedLineLimit: Int {
        #if os(iOS)
        2
        #else
        9
        #endif
    }

    private var episodeSummaryForegroundStyle: Color {
        #if os(iOS)
        Color.primary.opacity(0.78)
        #else
        Color.primary.opacity(0.76)
        #endif
    }

    private var episodeSummaryAllowsExpansion: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }

}
