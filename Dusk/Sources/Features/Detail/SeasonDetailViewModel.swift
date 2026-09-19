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
    let id: PlexItemID

    var ratingKey: String { id.ratingKey }

    /// The route's server wins; the download record and the primary server are
    /// only fallbacks for an id that reached us without one (an offline cache).
    var serverID: String? {
        id.serverID
            ?? downloadManager?.serverID(for: id)
            ?? plexService.pool.primary?.serverID
    }

    private(set) var details: PlexMediaDetails?
    private(set) var episodes: [PlexEpisode] = []
    private(set) var nextEpisodeDetails: PlexMediaDetails?
    private(set) var focusedEpisodeDetails: PlexMediaDetails?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isUsingCachedData = false
    private(set) var isUsingOfflineFallback = false
    private(set) var offlineStateVersion = 0
    private var focusedEpisodeRatingKey: String?
    private var episodeDetailsCache: [String: PlexMediaDetails] = [:]

    init(
        id: PlexItemID,
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

    func setWatched(_ watched: Bool, for episode: PlexEpisode) async {
        if constrainsPlaybackToOfflineAvailability || isPlayableOffline(episode) {
            offlinePlaybackSyncManager?.recordWatchState(
                serverID: serverID(for: episode),
                ratingKey: episode.ratingKey,
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
                id: PlexItemID(serverID: serverID(for: episode), ratingKey: episode.ratingKey)
            )
            await reload()
        } catch {
            if isPlayableOffline(episode) {
                offlinePlaybackSyncManager?.recordWatchState(
                    serverID: serverID(for: episode),
                    ratingKey: episode.ratingKey,
                    watched: watched
                )
                offlineStateVersion += 1
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    func toggleWatched(for episode: PlexEpisode) async {
        await setWatched(!isWatched(episode), for: episode)
    }

    /// The whole season is "watched" once every episode has been viewed.
    var isSeasonWatched: Bool {
        _ = offlineStateVersion
        if !episodes.isEmpty {
            return episodes.allSatisfy { isWatched($0) }
        }
        guard let viewed = details?.viewedLeafCount, let total = details?.leafCount, total > 0 else {
            return false
        }
        return viewed >= total
    }

    func toggleSeasonWatched() async {
        let target = !isSeasonWatched
        do {
            try await plexService.setWatchedAcrossServers(
                target,
                id: PlexItemID(serverID: serverID, ratingKey: ratingKey)
            )
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func focusEpisode(_ episode: PlexEpisode) async {
        let ratingKey = episode.ratingKey
        if focusedEpisodeRatingKey == ratingKey,
           focusedEpisodeDetails?.ratingKey == ratingKey {
            return
        }

        focusedEpisodeRatingKey = ratingKey

        if let cached = episodeDetailsCache[ratingKey] {
            focusedEpisodeDetails = cached
            return
        }

        // The episode's own id, never the season's: caching the season's
        // details under an episode key poisons the cache for that episode.
        if let cached = downloadManager?.cachedMediaDetails(
            for: PlexItemID(serverID: serverID(for: episode), ratingKey: ratingKey)
        ) {
            episodeDetailsCache[ratingKey] = cached
            focusedEpisodeDetails = cached
        }

        do {
            let details = try await plexService.getMediaDetails(
                ratingKey: ratingKey,
                serverID: serverID(for: episode)
            )
            episodeDetailsCache[ratingKey] = details
            if focusedEpisodeRatingKey == ratingKey {
                focusedEpisodeDetails = details
            }
        } catch {
            if focusedEpisodeRatingKey == ratingKey {
                focusedEpisodeDetails = episodeDetailsCache[ratingKey]
            }
        }
    }

    var showTitle: String? {
        details?.grandparentTitle ?? episodes.first?.grandparentTitle
    }

    var showID: PlexItemID? {
        let showKey = details?.parentRatingKey ?? episodes.first?.grandparentRatingKey
        return showKey.map { PlexItemID(serverID: serverID, ratingKey: $0) }
    }

    var episodeCountText: String? {
        let count = isUsingCachedData
            ? displayEpisodes.count
            : (details?.leafCount ?? details?.childCount ?? episodes.count)
        return MediaTextFormatter.episodeCount(count)
    }

    var watchedEpisodeCountText: String? {
        _ = offlineStateVersion
        let viewedCount = isUsingCachedData || offlinePlaybackSyncManager != nil
            ? episodes.filter { isWatched($0) }.count
            : (details?.viewedLeafCount ?? episodes.filter(\.isWatched).count)
        return MediaTextFormatter.watchedCount(viewedCount)
    }

    func backdropURL(
        width: Int,
        height: Int,
        focusedEpisode: PlexEpisode? = nil,
        focusedEpisodeDetails: PlexMediaDetails? = nil
    ) -> URL? {
        let path = focusedEpisodeDetails?.thumb
            ?? focusedEpisodeDetails?.art
            ?? focusedEpisode?.thumb
            ?? focusedEpisode?.art
            ?? details?.art

        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, serverID: serverID, width: width, height: height)
    }

    func posterURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.thumb)
            ?? plexService.imageURL(for: details?.thumb, serverID: serverID, width: width, height: height)
    }

    /// The show's title logo (clear-logo art) inherited onto the season metadata.
    /// Used in place of the show-name text in the iOS season hero; nil when Plex
    /// didn't attach a clear logo, in which case the hero falls back to text.
    func showTitleLogoURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.clearLogo)
            ?? plexService.imageURL(for: details?.clearLogo, serverID: serverID, width: width, height: height)
    }

    func episodeImageURL(_ episode: PlexEpisode, width: Int, height: Int) -> URL? {
        let path = episode.thumb ?? episode.grandparentThumb
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(
                for: path,
                serverID: serverID(for: episode),
                width: width,
                height: height
            )
    }

    func episodeSubtitle(_ episode: PlexEpisode) -> String? {
        [
            MediaTextFormatter.shortDuration(milliseconds: episode.duration),
            MediaTextFormatter.localizedAirDate(episode.originallyAvailableAt),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    }

    func episodeLabel(_ episode: PlexEpisode) -> String? {
        MediaTextFormatter.seasonEpisodeLabel(season: nil, episode: episode.index, separator: " ")
    }

    func progress(for episode: PlexEpisode) -> Double? {
        _ = offlineStateVersion
        return MediaTextFormatter.progress(
            durationMs: episode.duration,
            offsetMs: effectiveViewOffsetMs(for: episode)
        )
    }

    var displayEpisodes: [PlexEpisode] {
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
        let total = max(details?.leafCount ?? episodes.count, downloadedCount)
        let episodeLabel = total == 1 ? "episode" : "episodes"
        return "\(downloadedCount) of \(total) \(episodeLabel) downloaded and available offline."
    }

    func isPlayableOffline(_ episode: PlexEpisode) -> Bool {
        downloadManager?.isPlayableOffline(id: episode.id) == true
    }

    func downloadStatus(for episode: PlexEpisode) -> DownloadStatus? {
        guard DownloadsFeature.isVisible else { return nil }
        return downloadManager?.status(for: episode.id)
    }

    func isUnavailableOffline(_ episode: PlexEpisode) -> Bool {
        showsOfflineAvailability && !isPlayableOffline(episode)
    }

    func detailRoute(type: PlexMediaType, id: PlexItemID) -> AppNavigationRoute {
        prefersOfflineAvailability && DownloadsFeature.isVisible
            ? .downloadedMedia(type: type, id: id)
            : .media(type: type, id: id)
    }


    func isWatched(_ episode: PlexEpisode) -> Bool {
        _ = offlineStateVersion
        return offlinePlaybackSyncManager?.effectiveWatched(
            serverID: serverID(for: episode),
            ratingKey: episode.ratingKey,
            fallback: episode.isWatched
        ) ?? episode.isWatched
    }

    func isPartiallyWatched(_ episode: PlexEpisode) -> Bool {
        guard let offset = effectiveViewOffsetMs(for: episode), offset > 0 else { return false }
        return !isWatched(episode)
    }

    // MARK: - Play Next

    /// The episode the user would most likely want to play:
    /// first partially watched, then first unwatched, then first overall.
    var nextEpisodeToPlay: PlexEpisode? {
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

    /// Short play-button label for the season hero: intentionally omits which
    /// episode will resume/play so the primary button stays simple.
    var playButtonShortLabel: String {
        _ = offlineStateVersion
        guard let ep = nextEpisodeToPlay else { return "Play" }
        return isPartiallyWatched(ep) ? "Resume" : "Play"
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

    var nextEpisodePlayableVersions: [PlexMedia] {
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
                    ratingKey: ratingKey,
                    serverID: serverID
                )
                let loadedEpisodes = try await plexService.getEpisodes(
                    seasonKey: ratingKey,
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
        } catch {
            self.error = error.localizedDescription
            nextEpisodeDetails = nil
        }

        isLoading = false
    }

    private func loadNextEpisodeDetails() async {
        guard let nextEpisodeToPlay else {
            nextEpisodeDetails = nil
            return
        }

        do {
            nextEpisodeDetails = try await plexService.getMediaDetails(
                ratingKey: nextEpisodeToPlay.ratingKey,
                serverID: serverID(for: nextEpisodeToPlay)
            )
            if let nextEpisodeDetails {
                episodeDetailsCache[nextEpisodeToPlay.ratingKey] = nextEpisodeDetails
            }
        } catch {
            nextEpisodeDetails = downloadManager?.cachedMediaDetails(for: nextEpisodeToPlay.id)
            if let nextEpisodeDetails {
                episodeDetailsCache[nextEpisodeToPlay.ratingKey] = nextEpisodeDetails
            }
        }
    }

    private func effectiveViewOffsetMs(for episode: PlexEpisode) -> Int? {
        offlinePlaybackSyncManager?.effectiveViewOffsetMs(
            serverID: serverID(for: episode),
            ratingKey: episode.ratingKey,
            fallback: episode.viewOffset
        ) ?? episode.viewOffset
    }

    /// An episode decoded from this season's server is already stamped with it;
    /// the download records only answer for an episode restored from a cache.
    private func serverID(for episode: PlexEpisode) -> String? {
        episode.serverID
            ?? downloadManager?.serverID(for: episode.id)
            ?? serverID
    }
}
