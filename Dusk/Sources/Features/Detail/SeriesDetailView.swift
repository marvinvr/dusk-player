#if os(tvOS)
import SwiftUI

/// The tvOS show page. tvOS has no separate show, season, or episode screens:
/// every one of those routes opens this page, which browses one season at a time
/// (picked with the season pills above the episode row) under a banner that
/// keeps the season's artwork while its text follows the focused episode.
/// Selecting an episode card plays it.
struct SeriesDetailView: View {
    @Environment(MediaService.self) private var media
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.blursUnwatchedEpisodes) private var hidesSpoilers
    @State private var viewModel: SeriesDetailViewModel
    @State private var focusedEpisodeKey: String?
    /// The show's extras, shared by its Extras row and the hero's Trailer button.
    @State private var showExtras = DetailExtrasModel()
    @State private var showRating = DetailUserRatingModel()
    @State private var episodeFocusTask: Task<Void, Never>?
    /// Set when the player closes on a later episode than it opened with (Up
    /// Next / Next Episode): the row scrolls to that card and, if the run was
    /// started from the row, focus moves onto it. Cleared once the card took it.
    @State private var episodeFollowRequest: EpisodeFollowRequest?
    @State private var playbackStartedFromEpisodeRow = false
    /// Pins the page's first focus, and Down from the banner synopsis, to Play.
    /// The synopsis sits above the actions and is focusable when truncated, so
    /// geometry alone would open the page on it and drop Down onto whichever
    /// action is nearest its centre.
    @FocusState private var focusesPlay: Bool

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
        id: MediaItemID,
        media: MediaService,
        seerrService: SeerrService? = nil,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        _viewModel = State(initialValue: SeriesDetailViewModel(
            entry: entry,
            id: id,
            media: media,
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
        #if !os(macOS)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .task {
            await viewModel.load()
        }
        .task(id: "\(viewModel.season?.itemID ?? "")|\(viewModel.anchorEpisode?.itemID ?? "")") {
            await loadAnchorEpisodeDetailsIfNeeded()
        }
        .onChange(of: viewModel.season?.itemID) { _, _ in
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
        // Only once the cover is gone, and a beat after: tvOS hands focus back
        // to the card that started playback even after the cover's onDismiss
        // (sim: the restore landed after onDismiss, 600 ms later it stuck), and
        // that restore overrides any earlier focus move.
        .onChange(of: playback.playerCoverDismissals) { _, _ in
            let movesFocus = playbackStartedFromEpisodeRow
            playbackStartedFromEpisodeRow = false
            guard let advancedEpisode = playback.advancedEpisodeOnClose else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                await followPlayedEpisode(advancedEpisode, movesFocus: movesFocus)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, viewModel.season != nil else { return }
            Task { await viewModel.refresh() }
        }
    }

    @ViewBuilder
    private func contentView(_ season: SeasonDetailViewModel, details: MediaDetails) -> some View {
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
                        // Titled and spaced like the movie page's Synopsis: a
                        // bare paragraph between the episodes and Episode Cast
                        // didn't say whose summary it was.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About \(details.title)")
                                .font(DuskFont.sectionHeader(ios: .headline))
                                .foregroundStyle(Color.primary)
                            ExpandableSummaryText(text: summary, title: details.title)
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 32)
                        .padding(.bottom, 24)
                        .focusSection()
                    }

                    DetailExtrasShelf(
                        itemID: details.id,
                        title: "\(details.title) Extras",
                        ownerTitle: season.showTitle ?? details.title
                    )

                    DetailExtrasShelf(
                        itemID: viewModel.show?.details?.id,
                        ownerTitle: viewModel.show?.details?.title,
                        model: showExtras
                    )

                    // The show's collections, not the season's: Plex tags the show.
                    if let show = viewModel.show?.details {
                        DetailCollectionShelves(
                            itemID: show.id,
                            sectionID: show.libraryID,
                            tags: show.collections,
                            media: media
                        )
                    }

                    // Follows the focused episode like the cast below it; the
                    // delay keeps zapping the row from fetching every card.
                    DetailExtrasShelf(
                        itemID: focusedEpisode(in: season)?.id,
                        title: "Episode Extras",
                        ownerTitle: viewModel.show?.details?.title,
                        loadDelay: .milliseconds(400)
                    )

                    episodeCastSection(season)
                        .padding(.top, 8)
                        .padding(.bottom, 56)
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
                .defaultFocus($focusesPlay, true)
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
        details: MediaDetails,
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
                show: viewModel.show?.details
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
    private func episodeTitleView(_ episode: Episode?) -> some View {
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
        episode: Episode?,
        details: MediaDetails
    ) -> some View {
        Group {
            if let episode {
                // The episode name sits above in the title accessory, so this box
                // carries the supporting metadata: an "Episode N · 45 min · air
                // date" tagline (same styling as the rest of the app) and summary.
                VStack(alignment: .leading, spacing: 4) {
                    // The focused episode's own sources (IMDb, TMDB, …) share
                    // the meta line so the band keeps its fixed height. No
                    // user stars here: the hero's Rate button rates the show.
                    let ratings = focusedEpisodeDetails(in: season).map(Rating.sources(for:)) ?? []
                    let metaLine = episodeMetaLine(season, episode: episode)
                    if metaLine != nil || !ratings.isEmpty {
                        HStack(spacing: 28) {
                            if let metaLine {
                                Text(metaLine)
                                    .font(DuskFont.TV.metadata)
                                    .foregroundStyle(Color.primary.opacity(0.78))
                                    .lineLimit(1)
                            }
                            DetailRatingsLine(ratings: ratings, userRating: nil)
                                .layoutPriority(1)
                        }
                    }

                    // Focusable above the Play button when cut off (Select
                    // shows the whole synopsis) or spoiler-blurred (Select
                    // reveals it).
                    if let summary = episode.summary, !summary.isEmpty {
                        ExpandableSummaryText(
                            text: summary,
                            title: episode.title,
                            collapsedLineLimit: 2,
                            font: DuskFont.TV.caption,
                            lineSpacing: 3,
                            hidesSpoiler: UserPreferences.blursSummary(
                                isUnwatchedEpisode: !season.isWatched(episode),
                                hidesSpoilers: hidesSpoilers
                            )
                        )
                        .frame(maxWidth: 720, alignment: .leading)
                        .onMoveCommand { direction in
                            if direction == .down {
                                focusesPlay = true
                            }
                        }
                    }
                }
            } else {
                seasonTagline(season, details: details)
            }
        }
        // Not clipped: the summary's focus platter overhangs the band. The
        // line limits keep the text itself inside it.
        .frame(height: episodeHeroMetadataHeight, alignment: .topLeading)
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }

    private func episodeMetaLine(_ season: SeasonDetailViewModel, episode: Episode) -> String? {
        [season.episodeLabel(episode), season.episodeSubtitle(episode)]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    }

    @ViewBuilder
    private func seasonTagline(_ season: SeasonDetailViewModel, details: MediaDetails) -> some View {
        // Editions belong to the show, not the season.
        let parts = [
            viewModel.show?.details?.editionTitle,
            season.episodeCountText,
            season.watchedEpisodeCountText,
            ContentRatingLabel.display(details.contentRating),
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
    private func actionButtons(_ season: SeasonDetailViewModel, episode: Episode) -> some View {
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
            .focused($focusesPlay)
            .contextMenu {
                PlayVersionContextMenu(versions: focusedEpisodeVersions(in: season)) { version in
                    Task {
                        await playback.playVersion(
                            id: episode.id,
                            mediaID: version.id,
                            resumeOffsetMilliseconds: episode.resumeOffsetMs,
                            placeholder: PlaybackPlaceholder(episode: episode)
                        )
                    }
                }
            }

            DetailTrailerHeroButton(
                model: showExtras,
                primaryExtraKey: viewModel.show?.details?.primaryExtraKey,
                ownerTitle: viewModel.show?.details?.title,
                remoteTrailerURL: viewModel.show?.details?.remoteTrailerURL
            )

            Button {
                Task { await viewModel.toggleSeasonWatched() }
            } label: {
                DetailHeroSecondaryIconLabel(systemImage: season.isSeasonWatched ? "eye.slash" : "eye", title: season.isSeasonWatched ? "Mark Season Unwatched" : "Mark Season Watched")
            }
            .detailHeroNativeSecondaryButtonStyle()
            .accessibilityLabel(season.isSeasonWatched ? "Mark Season Unwatched" : "Mark Season Watched")

            if let show = viewModel.show?.details {
                DetailRateHeroButton(model: showRating, id: show.id)
                    .onChange(of: show.userRating, initial: true) { _, rating in
                        showRating.sync(rating)
                    }
            }

            AddToPlaylistHeroButton(
                target: viewModel.show?.details.flatMap(AddToPlaylistTarget.init(details:))
            )

            WatchlistHeroButton(entry: viewModel.show?.details.flatMap(WatchlistEntry.init(details:)))
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
    private func seasonContextMenu(_ season: Season) -> some View {
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

        AddToPlaylistMenuButton(target: AddToPlaylistTarget(season: season))
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
                            focusRequestID: episodeFollowRequest?.itemID == episode.itemID && episodeFollowRequest?.movesFocus == true
                                ? episodeFollowRequest?.id
                                : nil,
                            onFocusRequestHandled: {
                                episodeFollowRequest = nil
                            },
                            onFocus: {
                                focusEpisode(episode, in: season)
                            },
                            onPlay: {
                                play(episode, in: season)
                            }
                        )
                        .id(episode.itemID)
                        .contextMenu {
                            episodeContextMenu(episode, in: season)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            // The row is its own section so Up from a later episode leaves
            // the row. Geometry alone only finds a target above the first one.
            .focusSection()
            // Start each season's row on the episode the page opened on. Keyed on
            // the season only: re-scrolling when next-up moves (after playback)
            // would pull the row out from under the card that has focus.
            .task(id: season.itemID) {
                guard let anchor = viewModel.anchorEpisode else { return }
                proxy.scrollTo(anchor.itemID, anchor: .leading)
            }
            // Playback moved on to another episode of this season: bring its
            // card into view (a season switch is covered by the task above).
            .onChange(of: episodeFollowRequest?.id) { _, id in
                guard id != nil, let itemID = episodeFollowRequest?.itemID else { return }
                proxy.scrollTo(itemID, anchor: .leading)
                if episodeFollowRequest?.movesFocus == false {
                    episodeFollowRequest = nil
                }
            }
        }
        .opacity(viewModel.isSwitchingSeason ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.16), value: viewModel.isSwitchingSeason)
    }

    @ViewBuilder
    private func episodeContextMenu(_ episode: Episode, in season: SeasonDetailViewModel) -> some View {
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
            } else if downloadManager.canStartDownload(for: episode.id) {
                Button {
                    Task {
                        await downloadManager.queueDownload(episode: episode)
                    }
                } label: {
                    Label("Download Episode", systemImage: "arrow.down.circle")
                }
            }
        }

        AddToPlaylistMenuButton(target: AddToPlaylistTarget(episode: episode))
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
                    media: media,
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
        .animation(.easeInOut(duration: 0.16), value: details?.itemID)
    }

    // MARK: - Focus

    private func focusedEpisode(in season: SeasonDetailViewModel) -> Episode? {
        season.displayEpisodes.first { $0.itemID == focusedEpisodeKey }
            ?? viewModel.anchorEpisode
            ?? season.displayEpisodes.first
    }

    private func focusedEpisodeDetails(in season: SeasonDetailViewModel) -> MediaDetails? {
        let itemID = focusedEpisode(in: season)?.itemID
        if season.focusedEpisodeDetails?.itemID == itemID {
            return season.focusedEpisodeDetails
        }
        if season.nextEpisodeDetails?.itemID == itemID {
            return season.nextEpisodeDetails
        }
        return nil
    }

    private func focusedEpisodeVersions(in season: SeasonDetailViewModel) -> [MediaVersion] {
        focusedEpisodeDetails(in: season)?.media.filter { !$0.parts.isEmpty } ?? []
    }

    @MainActor
    private func loadAnchorEpisodeDetailsIfNeeded() async {
        guard let season = viewModel.season else { return }
        // A card the user already focused in this season keeps the banner.
        if let focusedEpisodeKey,
           season.displayEpisodes.contains(where: { $0.itemID == focusedEpisodeKey }) {
            return
        }
        guard let episode = viewModel.anchorEpisode ?? season.displayEpisodes.first else { return }
        setFocusedEpisodeKey(episode.itemID)
        await season.focusEpisode(episode)
    }

    @MainActor
    private func focusEpisode(_ episode: Episode, in season: SeasonDetailViewModel) {
        guard focusedEpisodeKey != episode.itemID else { return }

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
            setFocusedEpisodeKey(episode.itemID)
            await season.focusEpisode(episode)
        }
    }

    @MainActor
    private func setFocusedEpisodeKey(_ itemID: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            focusedEpisodeKey = itemID
        }
    }

    /// Moves the page onto the episode the player closed on: its season, the
    /// banner, the row's scroll position and (when the run began on a card)
    /// focus. Without this the page stayed on the episode the run started
    /// from, three episodes later costing three swipes to catch up.
    @MainActor
    private func followPlayedEpisode(_ details: MediaDetails, movesFocus: Bool) async {
        guard await viewModel.follow(playedEpisode: details),
              let season = viewModel.season,
              let episode = season.displayEpisodes.first(where: { $0.itemID == details.itemID }) else { return }
        episodeFocusTask?.cancel()
        setFocusedEpisodeKey(episode.itemID)
        episodeFollowRequest = EpisodeFollowRequest(itemID: episode.itemID, movesFocus: movesFocus)
        await season.focusEpisode(episode)
    }

    private func play(_ episode: Episode, in season: SeasonDetailViewModel) {
        guard !season.constrainsPlaybackToOfflineAvailability || season.isPlayableOffline(episode) else { return }
        playbackStartedFromEpisodeRow = true
        Task {
            await playback.play(
                id: episode.id,
                resumeOffsetMilliseconds: episode.resumeOffsetMs,
                resumeOffsetDurationMilliseconds: episode.duration,
                placeholder: PlaybackPlaceholder(episode: episode)
            )
        }
    }
}

private struct EpisodeFollowRequest {
    let id = UUID()
    let itemID: String
    let movesFocus: Bool
}

// MARK: - Season Pills

/// One pill per season above the episode row. Selecting a Plex season swaps the
/// row in place; a season only Seerr knows about opens its request page.
private struct SeriesSeasonPills<SeasonMenu: View>: View {
    let items: [ShowDetailViewModel.SeasonItem]
    let selectedSeasonKey: String?
    let seerrBadge: (SeerrSeasonSummary) -> String?
    let onSelect: (Season) -> Void
    @ViewBuilder let seasonMenu: (Season) -> SeasonMenu

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
            let isSelected = season.itemID == selectedSeasonKey
            Button {
                onSelect(season)
            } label: {
                SeriesSeasonPillLabel(
                    title: season.title,
                    badge: nil,
                    isSelected: isSelected,
                    isWatched: season.isFullyWatched,
                    unwatchedCount: season.unwatchedEpisodeCount
                )
            }
            .seriesSeasonPillButtonStyle()
            .contextMenu {
                seasonMenu(season)
            }
        case .seerr(let tvID, let season):
            NavigationLink(value: AppNavigationRoute.seerrSeason(tvID: tvID, seasonNumber: season.seasonNumber)) {
                SeriesSeasonPillLabel(
                    title: season.name,
                    badge: seerrBadge(season),
                    isSelected: false,
                    isWatched: false,
                    unwatchedCount: nil
                )
            }
            .seriesSeasonPillButtonStyle()
        }
    }
}

/// The selected season reads brighter and bolder than the rest; a filled pill
/// would look exactly like the focused one. Label colours come from the system
/// glass (light unfocused, dark on the focused white platter), so emphasis is
/// carried by opacity and weight only, and focus always gets full contrast.
private struct SeriesSeasonPillLabel: View {
    let title: String
    let badge: String?
    let isSelected: Bool
    let isWatched: Bool
    /// Episodes left in a partially watched season; shown in the checkmark's
    /// slot at its size (see `UnwatchedCountBadge`).
    let unwatchedCount: Int?
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(DuskFont.TV.cardTitle)
                .fontWeight(isSelected ? .bold : .medium)
                .lineLimit(1)

            if isWatched {
                Image(systemName: "checkmark")
                    .font(DuskFont.TV.glyphSmall)
                    .imageScale(.small)
                    .fontWeight(.semibold)
                    .opacity(0.7)
                    .accessibilityLabel("Watched")
            } else if let unwatchedCount {
                UnwatchedCountBadge(count: unwatchedCount)
                    .font(DuskFont.TV.glyphSmall)
                    .fontWeight(.semibold)
                    .opacity(0.7)
            }

            if let badge {
                Text(badge)
                    .font(DuskFont.TV.badge)
                    .opacity(0.7)
                    .lineLimit(1)
            }
        }
        .opacity(isSelected || isFocused ? 1 : 0.6)
    }
}

private extension View {
    func seriesSeasonPillButtonStyle() -> some View {
        self
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
    }
}

// MARK: - Episode Card

private struct SeriesEpisodeCard: View {
    let episode: Episode
    let imageURL: URL?
    let progress: Double?
    let isUnavailableOffline: Bool
    let isWatched: Bool
    let artworkWidth: CGFloat
    /// Non-nil asks this card to take focus (see `episodeFollowRequest`).
    let focusRequestID: UUID?
    let onFocusRequestHandled: () -> Void
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
                    showsPlayOverlay: false,
                    // `episodeImageURL` only falls back to the show poster
                    // when the episode has no still of its own.
                    isUnwatchedEpisodeImage: !isWatched && episode.thumb != nil,
                    showsWatchedBadge: isWatched
                )
                .opacity(isUnavailableOffline ? 0.46 : 1)
                .contentShape(.contextMenuPreview, artworkShape)
            }
            .duskSuppressTVOSButtonChrome()
            .focused($isFocused)
            .duskTVOSFocusEffectShape(artworkShape, scales: false)
            .tvQuickPlay(action: onPlay)
            .accessibilityLabel("Play \(episode.title)")
            .frame(width: artworkWidth, height: artworkHeight, alignment: .leading)

            PosterCardText(
                title: episode.title,
                subtitle: episodeNumberLabel,
                width: artworkWidth
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
        // Also runs when the card first appears, which is when a request for a
        // card that was off screen (or in a season still loading) lands.
        .task(id: focusRequestID) {
            guard focusRequestID != nil else { return }
            isFocused = true
            onFocusRequestHandled()
        }
    }
}
#endif
