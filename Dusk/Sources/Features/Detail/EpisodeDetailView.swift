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

                    if detailShowsSynopsisBelowHero(for: sizeClass), let summary = details.summary, !summary.isEmpty {
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
            title: details.title,
            descriptionText: details.summary,
            topInset: topInset,
            containerWidth: containerWidth,
            backgroundLeadingInset: backgroundLeadingInset,
            heroBaseHeight: heroBase,
            // The season·episode marker rides directly under the title (so on iPad
            // it heads the right column), while the rest of the metadata stays in
            // the left column with the show logo and the actions.
            titleAccessory: AnyView(
                episodeMarkerRow()
                    .multilineTextAlignment(detailHeroTextAlignment(for: sizeClass))
            ),
            supertitle: {
                if let showTitle = viewModel.showTitle {
                    DetailHeroShowTitleLink(
                        title: showTitle,
                        logoURL: viewModel.showTitleLogoURL(
                            width: Int((containerWidth * 0.5).rounded(.up)),
                            height: 128
                        ),
                        showRoute: viewModel.showRatingKey.map {
                            AppNavigationRoute.media(type: .show, ratingKey: $0)
                        }
                    )
                }
            },
            subtitle: {
                VStack(alignment: detailHeroContentAlignment(for: sizeClass), spacing: 6) {
                    metadataTagline(details)
                    heroMetadata(details)
                }
                .multilineTextAlignment(detailHeroTextAlignment(for: sizeClass))
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
            .font(markerFont)
            .foregroundStyle(markerColor)
    }

    private var metadataSeparator: some View {
        Text(" · ")
            .font(markerFont)
            .foregroundStyle(Color.primary.opacity(0.56))
    }

    // On iPad the season·episode marker sits under the episode title in the
    // right column as a quiet subtitle, so it reads smaller and greyer there.
    // (tvOS is also `.regular`, so guard to iOS to leave it untouched.)
    private var usesQuietMarker: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        false
        #endif
    }

    private var markerFont: Font {
        usesQuietMarker ? .footnote.weight(.medium) : .subheadline.weight(.medium)
    }

    private var markerColor: Color {
        usesQuietMarker ? Color.duskTextSecondary : Color.primary.opacity(0.82)
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
        #if os(tvOS)
        HStack(spacing: detailHeroActionSpacing) {
            playButton(details)
            downloadButton(details)
            episodeNavigationButton()
            watchedButton()
        }
        #else
        // Primary fills the stack width; secondary row is centered beneath it.
        VStack(alignment: .center, spacing: detailHeroActionSpacing) {
            playButton(details)

            HStack(spacing: detailHeroActionSpacing) {
                downloadButton(details)
                watchedButton()
            }
        }
        .detailHeroActionStackFrame(isCompactPhone: usesFullWidthActionButtons)
        #endif
    }

    private func playButton(_ details: PlexMediaDetails) -> some View {
        Button {
            guard !viewModel.isUsingCachedData || viewModel.isPlayableOffline else { return }
            Task { await playback.play(ratingKey: details.ratingKey, placeholder: PlaybackPlaceholder(details: details)) }
        } label: {
            DetailHeroPrimaryActionButtonLabel(
                title: "Play Episode",
                systemImage: "play.fill",
                fillsWidth: fillsActionWidth
            )
        }
        .detailHeroNativePrimaryButtonStyle()
        .disabled(viewModel.isUsingCachedData && !viewModel.isPlayableOffline)
        .contextMenu {
            if !viewModel.isUsingCachedData || viewModel.isPlayableOffline {
                PlayVersionContextMenu(versions: details.media) { version in
                    Task { await playback.playVersion(ratingKey: details.ratingKey, mediaID: version.id, placeholder: PlaybackPlaceholder(details: details)) }
                }
            }
        }
    }

    private func downloadButton(_ details: PlexMediaDetails) -> some View {
        DownloadActionButton(
            ratingKey: details.ratingKey,
            type: .episode,
            iconOnly: true
        )
    }

    @ViewBuilder
    private func episodeNavigationButton() -> some View {
        #if os(tvOS)
        if let seasonRatingKey = viewModel.seasonRatingKey {
            NavigationLink(value: AppNavigationRoute.media(type: .season, ratingKey: seasonRatingKey)) {
                DetailHeroSecondaryIconLabel(systemImage: "rectangle.stack.fill")
            }
            .detailHeroNativeSecondaryButtonStyle()
            .accessibilityLabel("Go to Season")
        }
        #else
        EmptyView()
        #endif
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
