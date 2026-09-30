#if os(tvOS)
import SwiftUI

/// The tvOS show page. tvOS has no separate show, season, or episode screens:
/// every one of those routes opens this page, which browses one season at a time
/// (picked with the season pills above the episode row) under a banner that
/// follows the focused episode. Selecting an episode card plays it.
struct SeriesDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: SeriesDetailViewModel
    @State private var focusedEpisodeKey: String?
    @State private var episodeFocusTask: Task<Void, Never>?

    private let horizontalPadding: CGFloat = DuskPosterMetrics.detailHorizontalPadding
    /// The pills and the plain "Episodes" header share one fixed-height slot, so
    /// the episode row does not jump when the show (and its pills) finish loading
    /// after the season is already on screen.
    private let seasonHeaderHeight: CGFloat = 84

    // Both bands are fixed so the banner doesn't jump while zapping the episode
    // row, so they have to be re-derived whenever the type scale moves. With the
    // reduced tvOS scale the metadata band holds a 25pt meta line + 4pt gap + two
    // 23pt summary lines (~92pt), and the cast band a 33pt header + 10pt gap + a
    // 144pt avatar + 14pt gap + two 23pt text lines + 12pt vertical padding
    // (~288pt). Both used to clip their last line; they now fit it exactly.
    private let episodeHeroMetadataHeight: CGFloat = 92
    private let episodeCastSectionHeight: CGFloat = 288

    init(
        entry: SeriesDetailViewModel.Entry,
        id: PlexItemID,
        plexService: PlexService,
        seerrService: SeerrService? = nil,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        _viewModel = State(initialValue: SeriesDetailViewModel(
            entry: entry,
            id: id,
            plexService: plexService,
            seerrService: seerrService,
            downloadManager: downloadManager,
            offlinePlaybackSyncManager: offlinePlaybackSyncManager,
            prefersOfflineAvailability: prefersOfflineAvailability
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if let season = viewModel.season, let details = season.details {
                contentView(season, details: details)
            } else if let error = viewModel.error, !viewModel.isLoading {
                FeatureErrorView(message: error) {
                    Task { await viewModel.retry() }
                }
            } else {
                FeatureLoadingView()
            }
        }
        .duskNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await viewModel.load()
        }
        .task(id: "\(viewModel.season?.ratingKey ?? "")|\(viewModel.anchorEpisode?.ratingKey ?? "")") {
            await loadAnchorEpisodeDetailsIfNeeded()
        }
        .onChange(of: viewModel.season?.ratingKey) { _, _ in
            // A pending focus commit belongs to the previous season's row.
            episodeFocusTask?.cancel()
        }
        .onDisappear {
            episodeFocusTask?.cancel()
        }
        .onChange(of: playback.showPlayer) { _, isShowing in
            if !isShowing {
                Task { await viewModel.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, viewModel.season != nil else { return }
            Task { await viewModel.refresh() }
        }
    }

    @ViewBuilder
    private func contentView(_ season: SeasonDetailViewModel, details: PlexMediaDetails) -> some View {
        GeometryReader { geometry in
            let heroBackgroundWidth = geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection(
                        season,
                        details: details,
                        topInset: geometry.safeAreaInsets.top,
                        containerWidth: heroBackgroundWidth,
                        containerHeight: geometry.size.height,
                        backgroundLeadingInset: geometry.safeAreaInsets.leading
                    )
                    .focusSection()

                    // The episode row sits directly under the banner so both stay
                    // on screen while zapping; the season summary moves below it
                    // (the banner already shows per-episode detail).
                    if let offlineBannerText = season.offlineBannerText {
                        OfflineMetadataBanner(message: offlineBannerText)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 24)
                    }

                    seasonHeader()
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 16)
                        .focusSection()

                    episodesSection(season, width: geometry.size.width)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                        .focusSection()

                    if let summary = details.summary, !summary.isEmpty {
                        ExpandableSummaryText(text: summary)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 32)
                            .focusSection()
                    }

                    episodeCastSection(season)
                        .padding(.top, 8)
                        .padding(.bottom, 56)
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .duskTVOSPageBackground()
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(
        _ season: SeasonDetailViewModel,
        details: PlexMediaDetails,
        topInset: CGFloat,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        backgroundLeadingInset: CGFloat
    ) -> some View {
        // Keep the banner compact so the episode row lands high enough that
        // focusing a card never scrolls the banner off-screen.
        let heroBase = min(max(containerHeight * 0.50, 500), 540)
        let heroHeight = heroBase + topInset
        let focusedEpisode = focusedEpisode(in: season)

        DetailHeroSection(
            backdropURL: season.backdropURL(
                width: Int(containerWidth.rounded(.up)),
                height: Int(heroHeight.rounded(.up)),
                focusedEpisode: focusedEpisode,
                focusedEpisodeDetails: focusedEpisodeDetails(in: season)
            ),
            // The show's clear-logo is the hero title; the show name is only the
            // text fallback when Plex has no logo, kept to one line so the banner
            // height stays put.
            titleArtworkURL: season.showTitleLogoURL(
                width: Int((containerWidth * 0.45).rounded(.up)),
                height: 128
            ),
            title: season.showTitle ?? details.title,
            descriptionText: details.summary,
            topInset: topInset,
            containerWidth: containerWidth,
            backgroundLeadingInset: backgroundLeadingInset,
            heroBaseHeight: heroBase,
            keepsPreviousBackdropWhileLoading: true,
            titleLineLimit: 1,
            titleAccessory: AnyView(episodeTitleView(focusedEpisode)),
            supertitle: {
                EmptyView()
            },
            subtitle: {
                episodeHeroMetadata(season, episode: focusedEpisode, details: details)
            },
            actions: {
                if let focusedEpisode {
                    actionButtons(season, episode: focusedEpisode)
                }
            }
        )
    }

    // The focused episode's name, sitting under the show logo. Kept to a single
    // (truncated) line and non-animated so the banner doesn't grow/shrink or
    // cross-fade as the user zaps the episode row.
    @ViewBuilder
    private func episodeTitleView(_ episode: PlexEpisode?) -> some View {
        Text(episode?.title ?? "")
            .font(DuskFont.TV.heroSubtitle)
            .foregroundStyle(Color.duskTextPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { transaction in
                transaction.disablesAnimations = true
            }
    }

    @ViewBuilder
    private func episodeHeroMetadata(
        _ season: SeasonDetailViewModel,
        episode: PlexEpisode?,
        details: PlexMediaDetails
    ) -> some View {
        Group {
            if let episode {
                // The episode name sits above in the title accessory, so this box
                // carries the supporting metadata: an "Episode N · 45 min · air
                // date" tagline (same styling as the rest of the app) and summary.
                VStack(alignment: .leading, spacing: 4) {
                    if let metaLine = episodeMetaLine(season, episode: episode) {
                        Text(metaLine)
                            .font(DuskFont.TV.metadata)
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .lineLimit(1)
                    }

                    if let summary = episode.summary, !summary.isEmpty {
                        Text(summary)
                            .font(DuskFont.TV.caption)
                            .foregroundStyle(Color.primary.opacity(0.76))
                            .lineSpacing(3)
                            .lineLimit(2)
                            .frame(maxWidth: 720, alignment: .leading)
                    }
                }
            } else {
                seasonTagline(season, details: details)
            }
        }
        .frame(height: episodeHeroMetadataHeight, alignment: .topLeading)
        .clipped()
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }

    private func episodeMetaLine(_ season: SeasonDetailViewModel, episode: PlexEpisode) -> String? {
        [season.episodeLabel(episode), season.episodeSubtitle(episode)]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    }

    @ViewBuilder
    private func seasonTagline(_ season: SeasonDetailViewModel, details: PlexMediaDetails) -> some View {
        let parts = [
            season.episodeCountText,
            season.watchedEpisodeCountText,
            details.contentRating,
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(DuskFont.TV.metadata)
                .foregroundStyle(Color.primary.opacity(0.78))
        }
    }

    // The hero Play button plays whatever episode is focused in the row, keeping
    // it in sync with the banner the user is reading.
    @ViewBuilder
    private func actionButtons(_ season: SeasonDetailViewModel, episode: PlexEpisode) -> some View {
        HStack(spacing: detailHeroActionSpacing) {
            Button {
                play(episode, in: season)
            } label: {
                DetailHeroPrimaryActionButtonLabel(
                    title: season.isPartiallyWatched(episode) ? "Resume" : "Play",
                    systemImage: "play.fill"
                )
            }
            .detailHeroNativePrimaryButtonStyle()
            .contextMenu {
                PlayVersionContextMenu(versions: focusedEpisodeVersions(in: season)) { version in
                    Task {
                        await playback.playVersion(
                            id: episode.id,
                            mediaID: version.id,
                            resumeOffsetMilliseconds: episode.viewOffset,
                            placeholder: PlaybackPlaceholder(episode: episode)
                        )
                    }
                }
            }

            Button {
                Task { await viewModel.toggleSeasonWatched() }
            } label: {
                DetailHeroSecondaryIconLabel(systemImage: season.isSeasonWatched ? "eye.slash" : "eye")
            }
            .detailHeroNativeSecondaryButtonStyle()
            .accessibilityLabel(season.isSeasonWatched ? "Mark Season Unwatched" : "Mark Season Watched")
        }
    }

    // MARK: - Season Pills

    @ViewBuilder
    private func seasonHeader() -> some View {
        Group {
            if viewModel.seasonItems.isEmpty {
                Text("Episodes")
                    .font(DuskFont.TV.sectionHeader)
                    .foregroundStyle(Color.primary)
            } else {
                SeriesSeasonPills(
                    items: viewModel.seasonItems,
                    selectedSeasonKey: viewModel.selectedSeasonKey,
                    seerrBadge: { viewModel.show?.seasonRequestState($0).badgeTitle },
                    onSelect: { season in
                        Task { await viewModel.selectSeason(season) }
                    },
                    seasonMenu: { season in
                        seasonContextMenu(season)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: seasonHeaderHeight, maxHeight: seasonHeaderHeight, alignment: .leading)
    }

    @ViewBuilder
    private func seasonContextMenu(_ season: PlexSeason) -> some View {
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
    }

    // MARK: - Episodes

    @ViewBuilder
    private func episodesSection(_ season: SeasonDetailViewModel, width: CGFloat) -> some View {
        let contentWidth = max(width - (horizontalPadding * 2), 280)
        let artworkWidth = min(max(contentWidth * 0.44, 240), 360)
        let imageWidth = Int(artworkWidth.rounded(.up))
        let imageHeight = Int((artworkWidth / (16.0 / 9.0)).rounded(.up))

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    ForEach(season.displayEpisodes) { episode in
                        SeriesEpisodeCard(
                            episode: episode,
                            imageURL: season.episodeImageURL(episode, width: imageWidth, height: imageHeight),
                            progress: season.progress(for: episode),
                            isUnavailableOffline: season.isUnavailableOffline(episode),
                            isWatched: season.isWatched(episode),
                            artworkWidth: artworkWidth,
                            onFocus: {
                                focusEpisode(episode, in: season)
                            },
                            onPlay: {
                                play(episode, in: season)
                            }
                        )
                        .id(episode.ratingKey)
                        .contextMenu {
                            episodeContextMenu(episode, in: season)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            // Start each season's row on the episode the page opened on. Keyed on
            // the season only: re-scrolling when next-up moves (after playback)
            // would pull the row out from under the card that has focus.
            .task(id: season.ratingKey) {
                guard let anchor = viewModel.anchorEpisode else { return }
                proxy.scrollTo(anchor.ratingKey, anchor: .leading)
            }
        }
        .opacity(viewModel.isSwitchingSeason ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.16), value: viewModel.isSwitchingSeason)
    }

    @ViewBuilder
    private func episodeContextMenu(_ episode: PlexEpisode, in season: SeasonDetailViewModel) -> some View {
        let downloadState = downloadManager.downloadState(for: DownloadScope(id: episode.id, type: .episode))

        if season.isPartiallyWatched(episode) {
            Button {
                Task { await playback.playFromStart(id: episode.id, placeholder: PlaybackPlaceholder(episode: episode)) }
            } label: {
                Label("Play from Start", systemImage: "arrow.counterclockwise")
            }

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
                    season.isWatched(episode) ? "Mark Unwatched" : "Mark Watched",
                    systemImage: season.isWatched(episode) ? "eye.slash" : "eye"
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

    @ViewBuilder
    private func episodeCastSection(_ season: SeasonDetailViewModel) -> some View {
        let details = focusedEpisodeDetails(in: season)
        let roles = details?.roles ?? []

        ZStack(alignment: .topLeading) {
            if !roles.isEmpty {
                DetailCastSection(
                    roles: roles,
                    serverID: season.serverID,
                    plexService: plexService,
                    title: "Episode Cast"
                )
                .transition(.opacity)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: episodeCastSectionHeight,
            maxHeight: episodeCastSectionHeight,
            alignment: .topLeading
        )
        .clipped()
        .animation(.easeInOut(duration: 0.16), value: details?.ratingKey)
    }

    // MARK: - Focus

    private func focusedEpisode(in season: SeasonDetailViewModel) -> PlexEpisode? {
        season.displayEpisodes.first { $0.ratingKey == focusedEpisodeKey }
            ?? viewModel.anchorEpisode
            ?? season.displayEpisodes.first
    }

    private func focusedEpisodeDetails(in season: SeasonDetailViewModel) -> PlexMediaDetails? {
        let ratingKey = focusedEpisode(in: season)?.ratingKey
        if season.focusedEpisodeDetails?.ratingKey == ratingKey {
            return season.focusedEpisodeDetails
        }
        if season.nextEpisodeDetails?.ratingKey == ratingKey {
            return season.nextEpisodeDetails
        }
        return nil
    }

    private func focusedEpisodeVersions(in season: SeasonDetailViewModel) -> [PlexMedia] {
        focusedEpisodeDetails(in: season)?.media.filter { !$0.parts.isEmpty } ?? []
    }

    @MainActor
    private func loadAnchorEpisodeDetailsIfNeeded() async {
        guard let season = viewModel.season else { return }
        // A card the user already focused in this season keeps the banner.
        if let focusedEpisodeKey,
           season.displayEpisodes.contains(where: { $0.ratingKey == focusedEpisodeKey }) {
            return
        }
        guard let episode = viewModel.anchorEpisode ?? season.displayEpisodes.first else { return }
        setFocusedEpisodeKey(episode.ratingKey)
        await season.focusEpisode(episode)
    }

    @MainActor
    private func focusEpisode(_ episode: PlexEpisode, in season: SeasonDetailViewModel) {
        guard focusedEpisodeKey != episode.ratingKey else { return }

        // Debounce the committed focus. The banner tracks the focused episode, so
        // updating it rebuilds the whole page; doing that on every card while the
        // user zaps through the row quickly makes the outer ScrollView drift
        // downward even though focus stays on the row. The per-card focus
        // highlight is driven locally by @FocusState, so it still reacts
        // instantly — only the banner waits until the user settles on a card.
        episodeFocusTask?.cancel()
        episodeFocusTask = Task {
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            setFocusedEpisodeKey(episode.ratingKey)
            await season.focusEpisode(episode)
        }
    }

    @MainActor
    private func setFocusedEpisodeKey(_ ratingKey: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            focusedEpisodeKey = ratingKey
        }
    }

    private func play(_ episode: PlexEpisode, in season: SeasonDetailViewModel) {
        guard !season.constrainsPlaybackToOfflineAvailability || season.isPlayableOffline(episode) else { return }
        Task {
            await playback.play(
                id: episode.id,
                resumeOffsetMilliseconds: episode.viewOffset,
                resumeOffsetDurationMilliseconds: episode.duration,
                placeholder: PlaybackPlaceholder(episode: episode)
            )
        }
    }
}

// MARK: - Season Pills

/// One pill per season above the episode row. Selecting a Plex season swaps the
/// row in place; a season only Seerr knows about opens its request page.
private struct SeriesSeasonPills<SeasonMenu: View>: View {
    let items: [ShowDetailViewModel.SeasonItem]
    let selectedSeasonKey: String?
    let seerrBadge: (SeerrSeasonSummary) -> String?
    let onSelect: (PlexSeason) -> Void
    @ViewBuilder let seasonMenu: (PlexSeason) -> SeasonMenu

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(items) { item in
                        pill(for: item)
                            .id(item.id)
                    }
                }
                .padding(.vertical, 14)
            }
            .scrollClipDisabled()
            .onAppear {
                guard let selectedSeasonKey else { return }
                proxy.scrollTo("plex:\(selectedSeasonKey)", anchor: .leading)
            }
        }
    }

    @ViewBuilder
    private func pill(for item: ShowDetailViewModel.SeasonItem) -> some View {
        switch item {
        case .plex(let season):
            let isSelected = season.ratingKey == selectedSeasonKey
            Button {
                onSelect(season)
            } label: {
                SeriesSeasonPillLabel(
                    title: season.title,
                    badge: nil,
                    isSelected: isSelected,
                    isWatched: season.isFullyWatched
                )
            }
            .buttonStyle(SeriesSeasonPillButtonStyle(isSelected: isSelected))
            .contextMenu {
                seasonMenu(season)
            }
        case .seerr(let tvID, let season):
            NavigationLink(value: AppNavigationRoute.seerrSeason(tvID: tvID, seasonNumber: season.seasonNumber)) {
                SeriesSeasonPillLabel(
                    title: season.name,
                    badge: seerrBadge(season),
                    isSelected: false,
                    isWatched: false
                )
            }
            .buttonStyle(SeriesSeasonPillButtonStyle(isSelected: false))
        }
    }
}

private struct SeriesSeasonPillLabel: View {
    let title: String
    let badge: String?
    let isSelected: Bool
    let isWatched: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(DuskFont.TV.cardTitle)
                .lineLimit(1)

            if isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(DuskFont.TV.glyphSmall)
                    .foregroundStyle(isSelected ? Color.duskPrimaryActionLabel : Color.duskAccent)
            }

            if let badge {
                Text(badge)
                    .font(DuskFont.TV.badge)
                    .foregroundStyle(Color.duskTextSecondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isSelected ? Color.duskPrimaryActionLabel : Color.primary)
    }
}

/// The selected pill borrows the detail primary's contrasting glass; the rest
/// are neutral glass. Focus adds the app's standard scale + glow either way.
private struct SeriesSeasonPillButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, isSelected: isSelected)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .glassEffect(
                    isSelected ? Glass.regular.tint(Color.duskPrimaryButtonTint) : Glass.regular,
                    in: Capsule()
                )
                .scaleEffect(isFocused ? 1.05 : 1.0)
                .shadow(
                    color: isFocused ? Color.white.opacity(0.34) : .clear,
                    radius: isFocused ? 16 : 0,
                    y: isFocused ? 6 : 0
                )
                .opacity(configuration.isPressed ? 0.86 : 1.0)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

// MARK: - Episode Card

private struct SeriesEpisodeCard: View {
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
                PosterArtwork(
                    imageURL: imageURL,
                    progress: progress,
                    width: artworkWidth,
                    imageAspectRatio: 16.0 / 9.0,
                    showsPlayOverlay: false
                )
                .opacity(isUnavailableOffline ? 0.46 : 1)
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
#endif
