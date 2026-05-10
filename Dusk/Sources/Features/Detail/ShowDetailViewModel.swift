import Foundation

@MainActor
@Observable
final class ShowDetailViewModel {
    private let plexService: PlexService
    private let downloadManager: DownloadManager?
    private let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    private let prefersOfflineAvailability: Bool
    let ratingKey: String

    private(set) var details: PlexMediaDetails?
    private(set) var seasons: [PlexSeason] = []
    private(set) var nextEpisode: PlexEpisode?
    private(set) var nextEpisodeDetails: PlexMediaDetails?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isUsingCachedData = false
    private(set) var offlineStateVersion = 0

    init(
        ratingKey: String,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        self.ratingKey = ratingKey
        self.plexService = plexService
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
        self.prefersOfflineAvailability = prefersOfflineAvailability
    }

    func load() async {
        guard details == nil else { return }
        isLoading = true
        error = nil

        do {
            try await reload()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func markSeason(_ season: PlexSeason, watched: Bool) async {
        do {
            try await plexService.setWatched(watched, ratingKey: season.ratingKey)
            try await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    var genreText: String? {
        guard let genres = details?.genres, !genres.isEmpty else { return nil }
        return genres.prefix(3).map(\.tag).joined(separator: ", ")
    }

    var seasonCountText: String? {
        if let count = details?.childCount, count > 0 {
            return MediaTextFormatter.seasonCount(count)
        }

        return MediaTextFormatter.seasonCount(visibleSeasons.count)
    }

    var episodeCountText: String? {
        if isUsingCachedData {
            return MediaTextFormatter.episodeCount(downloadManager?.downloadedEpisodeCount(showKey: ratingKey))
        }
        return MediaTextFormatter.episodeCount(details?.leafCount)
    }

    var visibleSeasons: [PlexSeason] {
        guard isUsingCachedData, let downloadManager else { return seasons }
        return seasons.filter { downloadManager.hasDownloadedEpisodes(seasonKey: $0.ratingKey) }
    }

    var showsOfflineAvailability: Bool {
        isUsingCachedData || prefersOfflineAvailability
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.art)
            ?? plexService.imageURL(for: details?.art, width: width, height: height)
    }

    func posterURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.thumb)
            ?? plexService.imageURL(for: details?.thumb, width: width, height: height)
    }

    func titleLogoURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.clearLogo)
            ?? plexService.imageURL(for: details?.clearLogo, width: width, height: height)
    }

    func seasonPosterURL(_ season: PlexSeason, width: Int, height: Int) -> URL? {
        let path = season.thumb ?? season.parentThumb ?? season.art
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, width: width, height: height)
    }

    func seasonSubtitle(_ season: PlexSeason) -> String? {
        if let downloadManager {
            let downloadedCount = downloadManager.downloadedEpisodeCount(seasonKey: season.ratingKey)
            if showsOfflineAvailability {
                let episodeCount = MediaTextFormatter.episodeCount(season.leafCount)
                guard downloadedCount > 0 else {
                    return ["Not downloaded", episodeCount].compactMap { $0 }.joined(separator: " · ")
                }

                let total = season.leafCount ?? downloadedCount
                if downloadedCount >= total {
                    return ["Downloaded", episodeCount].compactMap { $0 }.joined(separator: " · ")
                }
                return "\(downloadedCount) of \(total) downloaded"
            } else if downloadedCount > 0 {
                let total = season.leafCount ?? downloadedCount
                return "\(downloadedCount) of \(total) downloaded"
            }
        }
        return MediaTextFormatter.episodeCount(season.leafCount)
    }

    func seasonProgress(_ season: PlexSeason) -> Double? {
        if let downloadManager {
            let downloadedCount = downloadManager.downloadedEpisodeCount(seasonKey: season.ratingKey)
            if let total = season.leafCount, total > 0, downloadedCount > 0 {
                return Double(downloadedCount) / Double(total)
            }
        }

        guard let total = season.leafCount,
              let viewed = season.viewedLeafCount,
              total > 0,
              viewed > 0 else { return nil }
        return Double(viewed) / Double(total)
    }

    func seasonAvailabilityBadge(_ season: PlexSeason) -> String? {
        guard showsOfflineAvailability, let downloadManager else { return nil }
        let downloadedCount = downloadManager.downloadedEpisodeCount(seasonKey: season.ratingKey)
        guard downloadedCount > 0 else { return "Not Downloaded" }
        guard let total = season.leafCount, total > 0, downloadedCount < total else { return "Available Offline" }
        return "Partial"
    }

    func isSeasonUnavailableOffline(_ season: PlexSeason) -> Bool {
        guard showsOfflineAvailability, let downloadManager else { return false }
        return !downloadManager.hasDownloadedEpisodes(seasonKey: season.ratingKey)
    }

    func detailRoute(type: PlexMediaType, ratingKey: String) -> AppNavigationRoute {
        prefersOfflineAvailability
            ? .downloadedMedia(type: type, ratingKey: ratingKey)
            : .media(type: type, ratingKey: ratingKey)
    }

    // MARK: - Play Next

    var playButtonLabel: String {
        _ = offlineStateVersion
        guard let ep = nextEpisode else { return "Play" }
        let label = MediaTextFormatter.seasonEpisodeLabel(
            season: ep.parentIndex,
            episode: ep.index
        ) ?? "Episode \(ep.index ?? 1)"
        if isPartiallyWatched(ep) {
            return "Resume · \(label)"
        }
        return "Play · \(label)"
    }

    var nextEpisodeRoute: AppNavigationRoute? {
        guard let nextEpisode else { return nil }
        return detailRoute(type: .episode, ratingKey: nextEpisode.ratingKey)
    }

    var nextSeasonRoute: AppNavigationRoute? {
        guard let seasonRatingKey = nextEpisode?.parentRatingKey else { return nil }
        return detailRoute(type: .season, ratingKey: seasonRatingKey)
    }

    var nextEpisodeMenuLabel: String {
        guard let nextEpisode else { return "Go to Episode" }
        let label = MediaTextFormatter.seasonEpisodeLabel(
            season: nextEpisode.parentIndex,
            episode: nextEpisode.index,
            separator: " "
        ) ?? nextEpisode.title
        return "Go to \(label)"
    }

    var nextSeasonMenuLabel: String {
        guard let nextEpisode else { return "Go to Season" }
        let label = MediaTextFormatter.seasonEpisodeLabel(
            season: nextEpisode.parentIndex,
            episode: nil,
            separator: " "
        ) ?? nextEpisode.parentTitle ?? "Season"
        return "Go to \(label)"
    }

    var nextEpisodePlayableVersions: [PlexMedia] {
        nextEpisodeDetails?.media.filter { !$0.parts.isEmpty } ?? []
    }

    var offlineBannerText: String? {
        guard showsOfflineAvailability else { return nil }
        let downloadedCount = downloadManager?.downloadedEpisodeCount(showKey: ratingKey) ?? 0
        guard let total = details?.leafCount, total > 0, downloadedCount > 0 else {
            return nil
        }

        let baseText = "\(downloadedCount) of \(total) episodes are saved on this device."
        guard downloadedCount < total else { return baseText }
        return "\(baseText) Items marked Not Downloaded require an Internet connection."
    }

    private func reload() async throws {
        if let cachedDetails = downloadManager?.cachedMediaDetails(ratingKey: ratingKey) {
            details = cachedDetails
            isUsingCachedData = true
        }
        if let cachedSeasons = downloadManager?.cachedSeasons(showKey: ratingKey) {
            seasons = cachedSeasons.sorted { $0.index < $1.index }
            isUsingCachedData = true
        }

        // Context-menu navigation can create transient view/task lifetimes here.
        // Keeping these requests sequential avoids the async-let runtime abort seen in TestFlight.
        do {
            let loadedDetails = try await plexService.getMediaDetails(ratingKey: ratingKey)
            let loadedSeasons = try await plexService.getSeasons(showKey: ratingKey)
            details = loadedDetails
            seasons = loadedSeasons.sorted { $0.index < $1.index }
            isUsingCachedData = false
        } catch {
            if details == nil && seasons.isEmpty {
                throw error
            }
        }
        await resolveNextEpisode()
    }

    private func resolveNextEpisode() async {
        // Find first season that isn't fully watched
        let candidateSeasons = visibleSeasons
        let targetSeason = candidateSeasons.first(where: { !$0.isFullyWatched })
            ?? candidateSeasons.first

        guard let season = targetSeason else {
            nextEpisode = nil
            nextEpisodeDetails = nil
            return
        }

        do {
            let episodes = try await plexService.getEpisodes(seasonKey: season.ratingKey)
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            nextEpisode = episodes.first(where: { isPartiallyWatched($0) })
                ?? episodes.first(where: { !isWatched($0) })
                ?? episodes.first
            await loadNextEpisodeDetails()
        } catch {
            let episodes = downloadManager?.cachedEpisodes(seasonKey: season.ratingKey)?
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) } ?? []
            let playableEpisodes = isUsingCachedData
                ? episodes.filter { downloadManager?.isPlayableOffline(ratingKey: $0.ratingKey) == true }
                : episodes
            nextEpisode = playableEpisodes.first(where: { isPartiallyWatched($0) })
                ?? playableEpisodes.first(where: { !isWatched($0) })
                ?? playableEpisodes.first
            await loadNextEpisodeDetails()
        }
    }

    private func loadNextEpisodeDetails() async {
        guard let nextEpisode else {
            nextEpisodeDetails = nil
            return
        }

        do {
            nextEpisodeDetails = try await plexService.getMediaDetails(ratingKey: nextEpisode.ratingKey)
        } catch {
            nextEpisodeDetails = downloadManager?.cachedMediaDetails(ratingKey: nextEpisode.ratingKey)
        }
    }

    private func isWatched(_ episode: PlexEpisode) -> Bool {
        _ = offlineStateVersion
        return offlinePlaybackSyncManager?.effectiveWatched(
            serverID: serverID(for: episode),
            ratingKey: episode.ratingKey,
            fallback: episode.isWatched
        ) ?? episode.isWatched
    }

    private func isPartiallyWatched(_ episode: PlexEpisode) -> Bool {
        guard let offset = effectiveViewOffsetMs(for: episode), offset > 0 else { return false }
        return !isWatched(episode)
    }

    private func effectiveViewOffsetMs(for episode: PlexEpisode) -> Int? {
        offlinePlaybackSyncManager?.effectiveViewOffsetMs(
            serverID: serverID(for: episode),
            ratingKey: episode.ratingKey,
            fallback: episode.viewOffset
        ) ?? episode.viewOffset
    }

    private func serverID(for episode: PlexEpisode) -> String? {
        downloadManager?.serverID(for: episode.ratingKey)
            ?? downloadManager?.serverID(for: episode.parentRatingKey ?? "")
            ?? downloadManager?.serverID(for: ratingKey)
            ?? plexService.currentServerIdentifier
    }
}
