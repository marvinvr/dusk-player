import SwiftUI

struct SeasonDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: SeasonDetailViewModel
    #if os(tvOS)
    @State private var focusedTVEpisodeKey: String?
    @State private var tvEpisodeFocusTask: Task<Void, Never>?
    #endif

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
#if os(tvOS)
        .task(id: viewModel.nextEpisodeToPlay?.ratingKey) {
            await loadInitialTVEpisodeDetailsIfNeeded()
        }
        .onDisappear {
            tvEpisodeFocusTask?.cancel()
        }
#endif
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

#if os(tvOS)
                    // On tvOS the season page effectively becomes the episode
                    // browser: keep the episode row directly under the banner so
                    // both stay on screen while zapping. The season summary moves
                    // below the row (the banner already shows per-episode detail).
                    if let offlineBannerText = viewModel.offlineBannerText {
                        OfflineMetadataBanner(message: offlineBannerText)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 24)
                    }

                    episodesSection(width: geometry.size.width)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 24)
                        .padding(.bottom, episodesBottomPadding)
                        .focusSection()

                    if let summary = details.summary, !summary.isEmpty {
                        ExpandableSummaryText(text: summary)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 32)
                            .focusSection()
                    }

                    tvEpisodeCastSection()
                        .padding(.top, 8)
                        .padding(.bottom, 56)
#else
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
                        .padding(.bottom, episodesBottomPadding)
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
        let heroBase: CGFloat = {
            #if os(tvOS)
            // Keep the banner compact so the episode row lands high enough that
            // focusing a card never scrolls the banner off-screen.
            min(max(containerHeight * 0.50, 500), 540)
            #else
            min(max(containerHeight * 0.72, 520), 760)
            #endif
        }()
        let heroHeight = heroBase + topInset
        let heroBackdropURL: URL? = {
            #if os(tvOS)
            viewModel.backdropURL(
                width: Int(containerWidth.rounded(.up)),
                height: Int(heroHeight.rounded(.up)),
                focusedEpisode: focusedTVEpisode,
                focusedEpisodeDetails: selectedTVEpisodeDetails
            )
            #else
            viewModel.backdropURL(width: Int(containerWidth.rounded(.up)), height: Int(heroHeight.rounded(.up)))
            #endif
        }()
        let keepsPreviousBackdropWhileLoading: Bool = {
            #if os(tvOS)
            true
            #else
            false
            #endif
        }()
        DetailHeroSection(
            backdropURL: heroBackdropURL,
            title: heroTitle(fallback: details.title),
            descriptionText: details.summary,
            topInset: topInset,
            containerWidth: containerWidth,
            backgroundLeadingInset: backgroundLeadingInset,
            heroBaseHeight: heroBase,
            keepsPreviousBackdropWhileLoading: keepsPreviousBackdropWhileLoading,
            titleLineLimit: heroTitleLineLimit,
            supertitle: {
                if let showTitle = viewModel.showTitle {
                    showTitleLink(showTitle)
                }
            },
            subtitle: {
                #if os(tvOS)
                tvEpisodeHeroMetadata(details)
                #else
                metadataTagline(details)
                #endif
            },
            actions: {
                if heroPlayEpisode != nil {
                    actionButtons()
                }
            }
        )
    }

    private var episodesBottomPadding: CGFloat {
        #if os(tvOS)
        24
        #else
        56
        #endif
    }

    private func heroTitle(fallback: String) -> String {
        #if os(tvOS)
        if let episode = focusedTVEpisode {
            return episode.title
        }
        #endif

        return fallback
    }

    // On tvOS the hero title shows the focused episode's name and updates as the
    // user zaps the episode row, so keep it to a single line to stop the banner
    // from growing/shrinking. The other detail pages keep the default two lines.
    private var heroTitleLineLimit: Int {
        #if os(tvOS)
        1
        #else
        2
        #endif
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

    #if os(tvOS)
    private var focusedTVEpisode: PlexEpisode? {
        viewModel.displayEpisodes.first { $0.ratingKey == focusedTVEpisodeKey }
            ?? viewModel.nextEpisodeToPlay
            ?? viewModel.displayEpisodes.first
    }

    private var selectedTVEpisodeDetails: PlexMediaDetails? {
        if viewModel.focusedEpisodeDetails?.ratingKey == focusedTVEpisode?.ratingKey {
            return viewModel.focusedEpisodeDetails
        }

        if viewModel.nextEpisodeDetails?.ratingKey == focusedTVEpisode?.ratingKey {
            return viewModel.nextEpisodeDetails
        }

        return nil
    }

    private var selectedTVEpisodeRoles: [PlexRole] {
        selectedTVEpisodeDetails?.roles ?? []
    }

    private var tvEpisodeHeroMetadataHeight: CGFloat { 92 }
    private var tvEpisodeCastSectionHeight: CGFloat { 292 }

    @ViewBuilder
    private func tvEpisodeHeroMetadata(_ details: PlexMediaDetails) -> some View {
        Group {
            if let episode = focusedTVEpisode {
                // The episode name is the hero title now, so this box carries the
                // supporting metadata: an "Episode N · 45 min · air date" tagline
                // (same styling as the rest of the app) and the episode summary.
                VStack(alignment: .leading, spacing: 6) {
                    if let metaLine = tvEpisodeMetaLine(episode) {
                        Text(metaLine)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .lineLimit(1)
                    }

                    if let summary = episode.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(Color.primary.opacity(0.76))
                            .lineSpacing(3)
                            .lineLimit(2)
                            .frame(maxWidth: 720, alignment: .leading)
                    }
                }
            } else {
                metadataTagline(details)
            }
        }
        .frame(height: tvEpisodeHeroMetadataHeight, alignment: .topLeading)
        .clipped()
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }

    private func tvEpisodeMetaLine(_ episode: PlexEpisode) -> String? {
        [viewModel.episodeLabel(episode), viewModel.episodeSubtitle(episode)]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    @ViewBuilder
    private func tvEpisodeCastSection() -> some View {
        ZStack(alignment: .topLeading) {
            if !selectedTVEpisodeRoles.isEmpty {
                DetailCastSection(
                    roles: selectedTVEpisodeRoles,
                    plexService: plexService,
                    title: "Episode Cast"
                )
                .transition(.opacity)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: tvEpisodeCastSectionHeight,
            maxHeight: tvEpisodeCastSectionHeight,
            alignment: .topLeading
        )
        .clipped()
        .animation(.easeInOut(duration: 0.16), value: selectedTVEpisodeDetails?.ratingKey)
    }
    #endif

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
                .foregroundStyle(Color.primary.opacity(0.78))
        }
    }

    @ViewBuilder
    private func actionButtons() -> some View {
        #if os(tvOS)
        HStack(spacing: detailHeroActionSpacing) {
            seasonPlayActions(label: viewModel.playButtonShortLabel)
            watchedButton()
        }
        #else
        VStack(alignment: detailHeroContentAlignment(for: sizeClass), spacing: detailHeroActionSpacing) {
            seasonPlayActions(label: viewModel.playButtonShortLabel)

            HStack(spacing: detailHeroActionSpacing) {
                DownloadActionButton(
                    ratingKey: viewModel.ratingKey,
                    type: .season,
                    iconOnly: true
                )
                watchedButton()
            }
        }
        .detailHeroActionStackFrame(isCompactPhone: usesFullWidthActionButtons)
        #endif
    }

    private func seasonPlayActions(label: String) -> some View {
        SeasonHeroActions(
            nextEpisode: heroPlayEpisode,
            playButtonLabel: label,
            nextEpisodePlayableVersions: heroPlayEpisodeVersions,
            nextEpisodeRoute: heroPlayEpisodeRoute,
            nextEpisodeMenuLabel: heroPlayEpisodeMenuLabel,
            showRoute: viewModel.showRatingKey.map { viewModel.detailRoute(type: .show, ratingKey: $0) },
            usesFullWidthActionButtons: fillsActionWidth,
            onPlay: { episode in
                guard !viewModel.constrainsPlaybackToOfflineAvailability || viewModel.isPlayableOffline(episode) else { return }
                Task { await playback.play(ratingKey: episode.ratingKey) }
            },
            onPlayVersion: { episode, version in
                Task { await playback.playVersion(ratingKey: episode.ratingKey, mediaID: version.id) }
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

    // The episode the hero Play button targets. iOS plays the "next up" episode;
    // tvOS doubles as an episode browser, so it plays whatever episode is focused
    // in the row — keeping the button in sync with the banner the user is reading.
    private var heroPlayEpisode: PlexEpisode? {
        #if os(tvOS)
        focusedTVEpisode
        #else
        viewModel.nextEpisodeToPlay
        #endif
    }

    private var heroPlayEpisodeVersions: [PlexMedia] {
        #if os(tvOS)
        selectedTVEpisodeDetails?.media.filter { !$0.parts.isEmpty } ?? []
        #else
        viewModel.nextEpisodePlayableVersions
        #endif
    }

    private var heroPlayEpisodeRoute: AppNavigationRoute? {
        #if os(tvOS)
        focusedTVEpisode.map { viewModel.detailRoute(type: .episode, ratingKey: $0.ratingKey) }
        #else
        viewModel.nextEpisodeRoute
        #endif
    }

    private var heroPlayEpisodeMenuLabel: String {
        #if os(tvOS)
        if let episode = focusedTVEpisode, let label = viewModel.episodeLabel(episode) {
            return "Go to \(label)"
        }
        return "Go to Episode"
        #else
        viewModel.nextEpisodeMenuLabel
        #endif
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
    private func episodesSection(width: CGFloat) -> some View {
        if !viewModel.displayEpisodes.isEmpty {
            let contentWidth = max(width - (horizontalPadding * 2), 280)
            let artworkWidth: CGFloat = {
                #if os(tvOS)
                min(max(contentWidth * 0.44, 240), 360)
                #else
                min(max(contentWidth * 0.48, 170), 320)
                #endif
            }()
            let imageWidth = Int(artworkWidth.rounded(.up))
            let imageHeight = Int((artworkWidth / (16.0 / 9.0)).rounded(.up))
            let showsInlineSummary = usesInlineEpisodeSummaryLayout && contentWidth >= 700

            #if os(tvOS)
            VStack(alignment: .leading, spacing: 16) {
                Text("Episodes")
                    .font(.headline)
                    .foregroundStyle(Color.primary)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 28) {
                        ForEach(viewModel.displayEpisodes) { episode in
                            TVSeasonEpisodeCard(
                                episode: episode,
                                imageURL: viewModel.episodeImageURL(episode, width: imageWidth, height: imageHeight),
                                progress: viewModel.progress(for: episode),
                                isUnavailableOffline: viewModel.isUnavailableOffline(episode),
                                isWatched: viewModel.isWatched(episode),
                                artworkWidth: artworkWidth,
                                onFocus: {
                                    focusTVEpisode(episode)
                                },
                                onPlay: {
                                    guard !viewModel.constrainsPlaybackToOfflineAvailability || viewModel.isPlayableOffline(episode) else { return }
                                    Task { await playback.play(ratingKey: episode.ratingKey) }
                                }
                            )
                            .id(episode.ratingKey)
                            .contextMenu {
                                episodeContextMenu(episode)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
            }
            #else
            VStack(alignment: .leading, spacing: 16) {
                Text("Episodes")
                    .font(.headline)
                    .foregroundStyle(Color.primary)

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
                            constrainsPlaybackToOfflineAvailability: viewModel.constrainsPlaybackToOfflineAvailability,
                            artworkWidth: artworkWidth,
                            showsInlineSummary: showsInlineSummary,
                            onPlay: {
                                guard !viewModel.constrainsPlaybackToOfflineAvailability || viewModel.isPlayableOffline(episode) else { return }
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
            #endif
        }
    }

    #if os(tvOS)
    @MainActor
    private func loadInitialTVEpisodeDetailsIfNeeded() async {
        guard focusedTVEpisodeKey == nil, let episode = focusedTVEpisode else { return }
        setFocusedTVEpisodeKey(episode.ratingKey)
        await viewModel.focusEpisode(episode)
    }

    @MainActor
    private func focusTVEpisode(_ episode: PlexEpisode) {
        guard focusedTVEpisodeKey != episode.ratingKey else { return }

        // Debounce the committed focus. The banner tracks the focused episode, so
        // updating it rebuilds the whole page; doing that on every card while the
        // user zaps through the row quickly makes the outer ScrollView drift
        // downward even though focus stays on the row. The per-card focus
        // highlight is driven locally by @FocusState, so it still reacts
        // instantly — only the banner waits until the user settles on a card.
        tvEpisodeFocusTask?.cancel()
        tvEpisodeFocusTask = Task {
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            setFocusedTVEpisodeKey(episode.ratingKey)
            await viewModel.focusEpisode(episode)
        }
    }

    @MainActor
    private func setFocusedTVEpisodeKey(_ ratingKey: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            focusedTVEpisodeKey = ratingKey
        }
    }
    #endif

    private var usesInlineEpisodeSummaryLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    @ViewBuilder
    private func episodeContextMenu(_ episode: PlexEpisode) -> some View {
        let downloadState = downloadManager.downloadState(for: DownloadScope(ratingKey: episode.ratingKey, type: .episode))

        if viewModel.isPartiallyWatched(episode) {
            Button {
                Task { await playback.playFromStart(ratingKey: episode.ratingKey) }
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
                    onRetry: { downloadManager.retryDownload(ratingKey: episode.ratingKey) }
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
            constrainsPlaybackToOfflineAvailability: constrainsPlaybackToOfflineAvailability,
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
            constrainsPlaybackToOfflineAvailability: constrainsPlaybackToOfflineAvailability,
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
            ? AnyLayout(VStackLayout(spacing: detailHeroActionSpacing))
            : AnyLayout(HStackLayout(spacing: detailHeroActionSpacing))

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

            #if os(tvOS)
            if let showRoute {
                NavigationLink(value: showRoute) {
                    DetailHeroSecondaryIconLabel(systemImage: "tv.fill")
                }
                .detailHeroNativeSecondaryButtonStyle()
                .accessibilityLabel("Go to Show")
            }
            #endif
        }
    }
}

#if os(tvOS)
private struct TVSeasonEpisodeCard: View {
    let episode: PlexEpisode
    let imageURL: URL?
    let progress: Double?
    let isUnavailableOffline: Bool
    let isWatched: Bool
    let artworkWidth: CGFloat
    let onFocus: () -> Void
    let onPlay: () -> Void

    @FocusState private var isFocused: Bool

    private var artworkHeight: CGFloat {
        artworkWidth / (16.0 / 9.0)
    }

    private var artworkShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var episodeNumberLabel: String? {
        MediaTextFormatter.seasonEpisodeLabel(season: episode.parentIndex, episode: episode.index)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DuskPosterMetrics.cardSpacing) {
            Button(action: onPlay) {
                SeasonEpisodePosterArtwork(
                    imageURL: imageURL,
                    progress: progress,
                    artworkWidth: artworkWidth,
                    showsPlayOverlay: false,
                    isUnavailableOffline: isUnavailableOffline
                )
                .contentShape(.contextMenuPreview, artworkShape)
            }
            .duskSuppressTVOSButtonChrome()
            .focused($isFocused)
            .duskTVOSFocusEffectShape(artworkShape, scales: false)
            .accessibilityLabel("Play \(episode.title)")
            .frame(width: artworkWidth, height: artworkHeight, alignment: .leading)

            PosterCardText(
                title: episode.title,
                subtitle: episodeNumberLabel,
                width: artworkWidth,
                isWatched: isWatched
            )
        }
        .frame(width: artworkWidth, alignment: .topLeading)
        .duskTVOSFocusedScale(isFocused)
        .zIndex(isFocused ? 1 : 0)
        .onChange(of: isFocused) { _, newValue in
            if newValue {
                onFocus()
            }
        }
    }
}

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
    let constrainsPlaybackToOfflineAvailability: Bool
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
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(artworkShape)
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
                        .foregroundStyle(Color.primary.opacity(0.78))
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
                .foregroundStyle(isUnavailableOffline ? Color.primary.opacity(0.55) : Color.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.76))
            }

            if showsInlineSummary {
                SeasonEpisodeSummaryText(episode: episode, lineLimit: inlineSummaryLineLimit)
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
