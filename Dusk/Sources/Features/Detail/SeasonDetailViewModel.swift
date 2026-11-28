import Foundation

@MainActor
@Observable
final class SeasonDetailViewModel {
    private let plexService: PlexService
    private let downloadManager: DownloadManager?
    private let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    private let prefersOfflineAvailability: Bool
    /// Server-scoped identity of the season; its episodes come from the same
    /// server and inherit it automatically when they are decoded.
    let id: MediaItemID

    var itemID: String { id.itemID }

    /// The route's server wins; the download record and the primary server are
    /// only fallbacks for an id that reached us without one (an offline cache).
    var serverID: String? {
        id.serverID
            ?? downloadManager?.serverID(for: id)
            ?? plexService.pool.primary?.serverID
    }

    private(set) var details: MediaDetails?
    private var showDetails: MediaDetails?
    private(set) var episodes: [Episode] = []
    private(set) var nextEpisodeDetails: MediaDetails?
    private(set) var focusedEpisodeDetails: MediaDetails?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isUsingCachedData = false
    private(set) var isUsingOfflineFallback = false
    private(set) var offlineStateVersion = 0
    private var focusedEpisodeRatingKey: String?
    private var episodeDetailsCache: [String: MediaDetails] = [:]

    init(
        id: MediaItemID,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        self.id = id
        self.plexService = plexService
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
        self.prefersOfflineAvailability = prefersOfflineAvailability
    }

    func load() async {
        guard details == nil else { return }
        await refresh()
    }

    func refresh() async {
        await reload()
    }

    func setWatched(_ watched: Bool, for episode: Episode) async {
        if constrainsPlaybackToOfflineAvailability || isPlayableOffline(episode) {
            offlinePlaybackSyncManager?.recordWatchState(
                serverID: serverID(for: episode),
                itemID: episode.itemID,
                watched: watched
            )
            offlineStateVersion += 1
            await offlinePlaybackSyncManager?.syncPendingActions(force: true)
            await loadNextEpisodeDetails()
            return
        }

        do {
            try await plexService.setWatchedAcrossServers(
                watched,
                id: MediaItemID(serverID: serverID(for: episode), itemID: episode.itemID)
            )
            await reload()
        } catch {
            if isPlayableOffline(episode) {
                offlinePlaybackSyncManager?.recordWatchState(
                    serverID: serverID(for: episode),
                    itemID: episode.itemID,
                    watched: watched
                )
                offlineStateVersion += 1
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    func toggleWatched(for episode: Episode) async {
        await setWatched(!isWatched(episode), for: episode)
    }

    /// The whole season is "watched" once every episode has been viewed.
    var isSeasonWatched: Bool {
        _ = offlineStateVersion
        if !episodes.isEmpty {
            return episodes.allSatisfy { isWatched($0) }
        }
        guard let viewed = details?.watchedEpisodeCount, let total = details?.episodeCount, total > 0 else {
            return false
        }
        return viewed >= total
    }

    func toggleSeasonWatched() async {
        let target = !isSeasonWatched
        do {
            try await plexService.setWatchedAcrossServers(
                target,
                id: MediaItemID(serverID: serverID, itemID: itemID)
            )
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func focusEpisode(_ episode: Episode) async {
        let itemID = episode.itemID
        if focusedEpisodeRatingKey == itemID,
           focusedEpisodeDetails?.itemID == itemID {
            return
        }

        focusedEpisodeRatingKey = itemID

        if let cached = episodeDetailsCache[itemID] {
            focusedEpisodeDetails = cached
            return
        }

        // The episode's own id, never the season's: caching the season's
        // details under an episode key poisons the cache for that episode.
        if let cached = downloadManager?.cachedMediaDetails(
            for: MediaItemID(serverID: serverID(for: episode), itemID: itemID)
        ) {
            episodeDetailsCache[itemID] = cached
            focusedEpisodeDetails = cached
        }

        do {
            let details = try await plexService.getMediaDetails(
                itemID: itemID,
                serverID: serverID(for: episode)
            )
            episodeDetailsCache[itemID] = details
            if focusedEpisodeRatingKey == itemID {
                focusedEpisodeDetails = details
            }
        } catch {
            if focusedEpisodeRatingKey == itemID {
                focusedEpisodeDetails = episodeDetailsCache[itemID]
            }
        }
    }

    var showTitle: String? {
        details?.grandparentTitle ?? episodes.first?.grandparentTitle
    }

    var showID: MediaItemID? {
        let showKey = details?.parentID ?? episodes.first?.grandparentID
        return showKey.map { MediaItemID(serverID: serverID, itemID: $0) }
    }

    var episodeCountText: String? {
        let count = isUsingCachedData
            ? displayEpisodes.count
            : (details?.episodeCount ?? details?.childCount ?? episodes.count)
        return MediaTextFormatter.episodeCount(count)
    }

    var watchedEpisodeCountText: String? {
        _ = offlineStateVersion
        let viewedCount = isUsingCachedData || offlinePlaybackSyncManager != nil
            ? episodes.filter { isWatched($0) }.count
            : (details?.watchedEpisodeCount ?? episodes.filter(\.isWatched).count)
        #if os(macOS)
        // Same rule as the show page's season cards: the unwatched count,
        // only while the season is partly watched.
        let total = isUsingCachedData
            ? displayEpisodes.count
            : (details?.episodeCount ?? details?.childCount ?? episodes.count)
        let unwatched = total - viewedCount
        guard viewedCount > 0, unwatched > 0 else { return nil }
        return "\(unwatched) unwatched"
        #else
        return MediaTextFormatter.watchedCount(viewedCount)
        #endif
    }

    /// Episode focus only changes the banner's text; its artwork belongs to
    /// the season, falling back to the show's background and then its poster.
    func backdropURL(width: Int, height: Int, show: MediaDetails? = nil) -> URL? {
        let path = SeriesBackdropArtwork.path(season: details, show: show ?? showDetails)
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: ArtworkRef(serverID: serverID, path: path), size: ImageSize(width: width, height: height))
    }

    func posterURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.thumb)
            ?? plexService.imageURL(for: ArtworkRef(serverID: serverID, path: details?.thumb), size: ImageSize(width: width, height: height))
    }

    /// The show's title logo (clear-logo art) inherited onto the season metadata.
    /// Used in place of the show-name text in the iOS season hero; nil when Plex
    /// didn't attach a clear logo, in which case the hero falls back to text.
    func showTitleLogoURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.clearLogo)
            ?? plexService.imageURL(for: ArtworkRef(serverID: serverID, path: details?.clearLogo), size: ImageSize(width: width, height: height))
    }

    func episodeImageURL(_ episode: Episode, width: Int, height: Int) -> URL? {
        let path = episode.thumb ?? episode.grandparentThumb
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(
                for: ArtworkRef(serverID: serverID(for: episode), path: path),
                size: ImageSize(width: width, height: height)
            )
    }

    func episodeSubtitle(_ episode: Episode) -> String? {
        [
            MediaTextFormatter.shortDuration(milliseconds: episode.duration),
            MediaTextFormatter.localizedAirDate(episode.originallyAvailableAt),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    }

    func episodeLabel(_ episode: Episode) -> String? {
        MediaTextFormatter.seasonEpisodeLabel(season: nil, episode: episode.index, separator: " ")
    }

    func progress(for episode: Episode) -> Double? {
        _ = offlineStateVersion
        return MediaTextFormatter.progress(
            durationMs: episode.duration,
            offsetMs: effectiveViewOffsetMs(for: episode)
        )
    }

    var displayEpisodes: [Episode] {
        guard showsOfflineAvailability, let downloadManager else { return episodes }
        return episodes.sorted { lhs, rhs in
            let leftDownloaded = downloadManager.isPlayableOffline(id: lhs.id)
            let rightDownloaded = downloadManager.isPlayableOffline(id: rhs.id)
            if leftDownloaded != rightDownloaded {
                return leftDownloaded && !rightDownloaded
            }
            return (lhs.index ?? 0) < (rhs.index ?? 0)
        }
    }

    var showsOfflineAvailability: Bool {
        DownloadsFeature.isVisible && (isUsingOfflineFallback || prefersOfflineAvailability)
    }

    var constrainsPlaybackToOfflineAvailability: Bool {
        showsOfflineAvailability
    }

    var offlineBannerText: String? {
        guard showsOfflineAvailability else { return nil }
        let downloadedCount = downloadManager?.downloadedEpisodeCount(season: id) ?? 0
        let total = max(details?.episodeCount ?? episodes.count, downloadedCount)
        let episodeLabel = total == 1 ? "episode" : "episodes"
        return "\(downloadedCount) of \(total) \(episodeLabel) downloaded and available offline."
    }

    func isPlayableOffline(_ episode: Episode) -> Bool {
        downloadManager?.isPlayableOffline(id: episode.id) == true
    }

    func downloadStatus(for episode: Episode) -> DownloadStatus? {
        guard DownloadsFeature.isVisible else { return nil }
        return downloadManager?.status(for: episode.id)
    }

    func isUnavailableOffline(_ episode: Episode) -> Bool {
        showsOfflineAvailability && !isPlayableOffline(episode)
    }

    func detailRoute(type: MediaKind, id: MediaItemID) -> AppNavigationRoute {
        prefersOfflineAvailability && DownloadsFeature.isVisible
            ? .downloadedMedia(type: type, id: id)
            : .media(type: type, id: id)
    }


    func isWatched(_ episode: Episode) -> Bool {
        _ = offlineStateVersion
        return offlinePlaybackSyncManager?.effectiveWatched(
            serverID: serverID(for: episode),
            itemID: episode.itemID,
            fallback: episode.isWatched
        ) ?? episode.isWatched
    }

    func isPartiallyWatched(_ episode: Episode) -> Bool {
        guard let offset = effectiveViewOffsetMs(for: episode), offset > 0 else { return false }
        return !isWatched(episode)
    }

    // MARK: - Play Next

    /// The episode the user would most likely want to play:
    /// first partially watched, then first unwatched, then first overall.
    var nextEpisodeToPlay: Episode? {
        _ = offlineStateVersion
        let candidates = constrainsPlaybackToOfflineAvailability
            ? displayEpisodes.filter { isPlayableOffline($0) }
            : episodes
        return candidates.first(where: { isPartiallyWatched($0) })
            ?? candidates.first(where: { !isWatched($0) })
            ?? candidates.first
    }

    var playButtonLabel: String {
        guard let ep = nextEpisodeToPlay else { return "Play" }
        let label = ep.index.map { "Episode \($0)" } ?? ep.title
        if isPartiallyWatched(ep) {
            return "Resume · \(label)"
        }
        return "Play · \(label)"
    }

    /// Short play-button label for the season hero: "Play", or "Resume
    /// Episode 3" so it says which episode picks up.
    var playButtonShortLabel: String {
        _ = offlineStateVersion
        guard let ep = nextEpisodeToPlay else { return "Play" }
        guard isPartiallyWatched(ep) else { return "Play" }
        return ep.index.map { "Resume Episode \($0)" } ?? "Resume"
    }

    var nextEpisodeRoute: AppNavigationRoute? {
        guard let nextEpisodeToPlay else { return nil }
        return detailRoute(type: .episode, id: nextEpisodeToPlay.id)
    }

    var nextEpisodeMenuLabel: String {
        guard let episode = nextEpisodeToPlay else { return "Go to Episode" }
        return MediaTextFormatter.seasonEpisodeLabel(
            season: nil,
            episode: episode.index,
            separator: " "
        ).map { "Go to \($0)" } ?? "Go to Episode"
    }

    var nextEpisodePlayableVersions: [MediaVersion] {
        nextEpisodeDetails?.media.filter { !$0.parts.isEmpty } ?? []
    }

    private func reload() async {
        isLoading = true
        error = nil
        isUsingOfflineFallback = false

        do {
            if let cachedDetails = downloadManager?.cachedMediaDetails(for: id) {
                details = cachedDetails
                isUsingCachedData = true
            }
            if let cachedEpisodes = downloadManager?.cachedEpisodes(season: id) {
                episodes = cachedEpisodes.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
                isUsingCachedData = true
            }

            // Context-menu navigation can create transient view/task lifetimes here.
            // Keeping these requests sequential avoids the async-let runtime abort seen in TestFlight.
            do {
                let loadedDetails = try await plexService.getMediaDetails(
                    itemID: itemID,
                    serverID: serverID
                )
                let loadedEpisodes = try await plexService.getEpisodes(
                    seasonKey: itemID,
                    serverID: serverID
                )
                details = loadedDetails
                episodes = loadedEpisodes.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
                isUsingCachedData = false
            } catch {
                if details == nil && episodes.isEmpty {
                    throw error
                }
                isUsingOfflineFallback = isUsingCachedData
            }
            await loadNextEpisodeDetails()
            #if !os(tvOS)
            await loadShowArtwork()
            #endif
        } catch {
            self.error = error.localizedDescription
            nextEpisodeDetails = nil
        }

        isLoading = false
    }

    #if !os(tvOS)
    private func loadShowArtwork() async {
        // tvOS supplies its already-loaded show to backdropURL. Separate
        // season pages only need this request when the season has no art.
        guard details?.art?.nilIfEmpty == nil, let showID else { return }
        showDetails = downloadManager?.cachedMediaDetails(for: showID) ?? showDetails
        guard !isUsingCachedData else { return }
        if let show = try? await plexService.getMediaDetails(
            itemID: showID.itemID, serverID: serverID
        ) {
            showDetails = show
        }
    }
    #endif

    private func loadNextEpisodeDetails() async {
        guard let nextEpisodeToPlay else {
            nextEpisodeDetails = nil
            return
        }

        do {
            nextEpisodeDetails = try await plexService.getMediaDetails(
                itemID: nextEpisodeToPlay.itemID,
                serverID: serverID(for: nextEpisodeToPlay)
            )
            if let nextEpisodeDetails {
                episodeDetailsCache[nextEpisodeToPlay.itemID] = nextEpisodeDetails
            }
        } catch {
            nextEpisodeDetails = downloadManager?.cachedMediaDetails(for: nextEpisodeToPlay.id)
            if let nextEpisodeDetails {
                episodeDetailsCache[nextEpisodeToPlay.itemID] = nextEpisodeDetails
            }
        }
    }

    private func effectiveViewOffsetMs(for episode: Episode) -> Int? {
        offlinePlaybackSyncManager?.effectiveViewOffsetMs(
            serverID: serverID(for: episode),
            itemID: episode.itemID,
            fallback: episode.resumeOffsetMs
        ) ?? episode.resumeOffsetMs
    }

    /// An episode decoded from this season's server is already stamped with it;
    /// the download records only answer for an episode restored from a cache.
    private func serverID(for episode: Episode) -> String? {
        episode.serverID
            ?? downloadManager?.serverID(for: episode.id)
            ?? serverID
    }
}
