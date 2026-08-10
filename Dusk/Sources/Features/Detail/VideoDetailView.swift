import SwiftUI

/// Detail screen for video clips ("Other Videos" / YouTube-style libraries).
/// Modeled on `MovieDetailView` but trimmed for clip metadata: no tagline,
/// ratings, cast, collections, or media-info sections. The hero backdrop is the
/// clip's `art` (falling back to its 16:9 `thumb` frame grab), the metadata line
/// is "channel · upload date · duration", and a 16:9 "More from this channel"
/// carousel replaces the movie extras.
struct VideoDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: VideoDetailViewModel

    private let horizontalPadding: CGFloat = DuskPosterMetrics.detailHorizontalPadding

    init(
        ratingKey: String,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil
    ) {
        _viewModel = State(initialValue: VideoDetailViewModel(
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
                    Task { await viewModel.loadDetails() }
                }
            } else if let details = viewModel.details {
                contentView(details)
            }
        }
        .duskNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await viewModel.loadDetails()
        }
        .onChange(of: playback.showPlayer) { _, isShowing in
            if !isShowing {
                Task { await viewModel.refreshDetails() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, viewModel.details != nil else { return }
            Task { await viewModel.refreshDetails() }
        }
    }

    // MARK: - Content

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
                    // On iPad the description lives in the hero's right column;
                    // the centered iPhone hero (and tvOS) keep it as a section below.
                    if detailShowsSynopsisBelowHero(for: sizeClass), let summary = details.summary, !summary.isEmpty {
                        descriptionSection(summary)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 40)
#if os(tvOS)
                            .focusSection()
#endif
                    }
                    if let offlineBannerText = viewModel.offlineBannerText {
                        OfflineMetadataBanner(message: offlineBannerText)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 24)
                    }
                    channelSection()
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .padding(.bottom, 56)
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

    // MARK: - Hero

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
            heroBaseHeight: heroBase
        ) {
            metadataLine()
                .multilineTextAlignment(detailHeroTextAlignment(for: sizeClass))
        } actions: {
            actionButtons(details)
        }
    }

    @ViewBuilder
    private func metadataLine() -> some View {
        if let line = viewModel.metadataLine {
            Text(line)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary.opacity(0.78))
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionButtons(_ details: PlexMediaDetails) -> some View {
        #if os(tvOS)
        HStack(spacing: detailHeroActionSpacing) {
            playButton(details)
            downloadButton(details)
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
            Task {
                await playback.play(
                    ratingKey: details.ratingKey,
                    resumeOffsetMilliseconds: details.viewOffset,
                    placeholder: PlaybackPlaceholder(details: details)
                )
            }
        } label: {
            DetailHeroPrimaryActionButtonLabel(
                title: viewModel.formattedResume.map { "Resume from \($0)" } ?? "Play",
                systemImage: "play.fill",
                fillsWidth: fillsActionWidth
            )
        }
        .detailHeroNativePrimaryButtonStyle()
        .disabled(viewModel.isUsingCachedData && !viewModel.isPlayableOffline)
        .contextMenu {
            if !viewModel.isUsingCachedData || viewModel.isPlayableOffline {
                PlayVersionContextMenu(versions: details.media) { version in
                    Task {
                        await playback.playVersion(
                            ratingKey: details.ratingKey,
                            mediaID: version.id,
                            resumeOffsetMilliseconds: details.viewOffset,
                            placeholder: PlaybackPlaceholder(details: details)
                        )
                    }
                }
            }
        }
    }

    private func downloadButton(_ details: PlexMediaDetails) -> some View {
        DownloadActionButton(
            ratingKey: details.ratingKey,
            type: details.type,
            isClip: true,
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

    // MARK: - Description

    private func descriptionSection(_ summary: String) -> some View {
        ExpandableSummaryText(
            text: summary,
            collapsedLineLimit: descriptionCollapsedLineLimit
        )
    }

    // YouTube-style descriptions can be very long, so keep the collapsed block
    // short on iPhone and let "Show More" reveal the rest.
    private var descriptionCollapsedLineLimit: Int {
        #if os(tvOS)
        9
        #else
        4
        #endif
    }

    // MARK: - Channel

    @ViewBuilder
    private func channelSection() -> some View {
        if !viewModel.channelItems.isEmpty, let title = viewModel.channelRowTitle {
            PlexItemPosterCarouselSection(
                title: title,
                items: viewModel.channelItems,
                posterWidth: DuskPosterMetrics.videoCarouselWidth,
                imageAspectRatio: 16.0 / 9.0,
                showAllRoute: viewModel.channelShowAllRoute,
                subtitle: { $0.standardPosterSubtitle },
                posterURL: { item, width, height in
                    item.posterImageURL(plexService: plexService, width: width, height: height)
                },
                progress: { $0.posterProgress }
            )
            .padding(.top, 40)
#if os(tvOS)
            .focusSection()
#endif
        }
    }
}
