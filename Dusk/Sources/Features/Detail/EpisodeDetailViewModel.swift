import Foundation

@MainActor
@Observable
final class EpisodeDetailViewModel {
    private let plexService: PlexService
    private let downloadManager: DownloadManager?
    private let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    let ratingKey: String

    private(set) var details: PlexMediaDetails?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isUsingCachedData = false
    private(set) var offlineStateVersion = 0

    init(
        ratingKey: String,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil
    ) {
        self.ratingKey = ratingKey
        self.plexService = plexService
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
    }

    func load() async {
        guard details == nil else { return }
        await reload()
    }

    func toggleWatched() async {
        guard let details else { return }
        let targetWatched = !isWatched

        if isUsingCachedData || isPlayableOffline {
            offlinePlaybackSyncManager?.recordWatchState(
                serverID: serverID,
                ratingKey: details.ratingKey,
                watched: targetWatched
            )
            offlineStateVersion += 1
            await offlinePlaybackSyncManager?.syncPendingActions()
            return
        }

        do {
            try await plexService.setWatched(targetWatched, ratingKey: details.ratingKey)
            await reload()
        } catch {
            if isPlayableOffline {
                offlinePlaybackSyncManager?.recordWatchState(
                    serverID: serverID,
                    ratingKey: details.ratingKey,
                    watched: targetWatched
                )
                offlineStateVersion += 1
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    var seasonLabel: String? {
        MediaTextFormatter.seasonEpisodeLabel(season: details?.parentIndex, episode: nil)
    }

    var seasonRatingKey: String? {
        details?.parentRatingKey
    }

    var episodeLabel: String? {
        MediaTextFormatter.seasonEpisodeLabel(season: nil, episode: details?.index)
    }

    var showTitle: String? {
        details?.grandparentTitle
    }

    var showRatingKey: String? {
        details?.grandparentRatingKey
    }

    var formattedDuration: String? {
        MediaTextFormatter.shortDuration(milliseconds: details?.duration)
    }

    var isWatched: Bool {
        guard let details else { return false }
        _ = offlineStateVersion
        let fallback = isWatched(details)
        return offlinePlaybackSyncManager?.effectiveWatched(
            serverID: serverID,
            ratingKey: details.ratingKey,
            fallback: fallback
        ) ?? fallback
    }

    var isPlayableOffline: Bool {
        downloadManager?.isPlayableOffline(ratingKey: ratingKey) == true
    }

    var offlineBannerText: String? {
        guard isUsingCachedData else { return nil }
        return isPlayableOffline
            ? "Showing saved episode metadata. This episode is available offline."
            : "Showing saved episode metadata. This episode is not downloaded on this device."
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        let path = details?.thumb ?? details?.art
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, width: width, height: height)
    }

    func posterURL(width: Int, height: Int) -> URL? {
        let path = details?.parentThumb ?? details?.grandparentThumb ?? details?.thumb
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, width: width, height: height)
    }

    private func reload() async {
        isLoading = true
        error = nil

        if let cachedDetails = downloadManager?.cachedMediaDetails(ratingKey: ratingKey) {
            details = cachedDetails
            isUsingCachedData = true
        }

        do {
            details = try await plexService.getMediaDetails(ratingKey: ratingKey)
            isUsingCachedData = false
        } catch {
            if details == nil {
                self.error = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func isWatched(_ details: PlexMediaDetails) -> Bool {
        guard let viewCount = details.viewCount else { return false }
        return viewCount > 0
    }

    private var serverID: String? {
        downloadManager?.serverID(for: ratingKey) ?? plexService.currentServerIdentifier
    }
}
