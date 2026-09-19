import Foundation

@MainActor
@Observable
final class MovieDetailViewModel {
    private let plexService: PlexService
    private let downloadManager: DownloadManager?
    private let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    /// Server-scoped identity of the movie. Every request this model makes goes
    /// to `id.serverID`, never to whichever server happens to be primary.
    let id: PlexItemID

    var ratingKey: String { id.ratingKey }

    private(set) var details: PlexMediaDetails?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isUsingCachedData = false
    private(set) var offlineStateVersion = 0

    init(
        id: PlexItemID,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil
    ) {
        self.id = id
        self.plexService = plexService
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
    }

    func loadDetails() async {
        guard details == nil else { return }
        await refreshDetails()
    }

    func refreshDetails() async {
        isLoading = true
        error = nil

        if let cachedDetails = downloadManager?.cachedMediaDetails(for: id) {
            details = cachedDetails
            isUsingCachedData = true
        }

        do {
            details = try await plexService.getMediaDetails(ratingKey: ratingKey, serverID: serverID)
            isUsingCachedData = false
        } catch {
            if details == nil {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    func toggleWatched() async {
        guard details != nil else { return }
        let targetWatched = !isWatched

        if isUsingCachedData || isPlayableOffline {
            offlinePlaybackSyncManager?.recordWatchState(
                serverID: serverID,
                ratingKey: ratingKey,
                watched: targetWatched
            )
            offlineStateVersion += 1
            await offlinePlaybackSyncManager?.syncPendingActions(force: true)
            return
        }

        do {
            try await plexService.setWatchedAcrossServers(
                targetWatched,
                id: PlexItemID(serverID: serverID, ratingKey: ratingKey)
            )
            self.details = try await plexService.getMediaDetails(ratingKey: ratingKey, serverID: serverID)
        } catch {
            if isPlayableOffline {
                offlinePlaybackSyncManager?.recordWatchState(
                    serverID: serverID,
                    ratingKey: ratingKey,
                    watched: targetWatched
                )
                offlineStateVersion += 1
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Computed Helpers

    var isWatched: Bool {
        _ = offlineStateVersion
        let fallback = (details?.viewCount ?? 0) > 0
        return offlinePlaybackSyncManager?.effectiveWatched(
            serverID: serverID,
            ratingKey: ratingKey,
            fallback: fallback
        ) ?? fallback
    }

    var isPlayableOffline: Bool {
        downloadManager?.isPlayableOffline(id: id) == true
    }

    var offlineBannerText: String? {
        guard DownloadsFeature.isVisible, isUsingCachedData else { return nil }
        return isPlayableOffline
            ? "Showing saved movie metadata. This movie is available offline."
            : "Showing saved movie metadata. This movie is not downloaded on this device."
    }

    var resumePositionSeconds: TimeInterval? {
        _ = offlineStateVersion
        guard let offset = offlinePlaybackSyncManager?.effectiveViewOffsetMs(
            serverID: serverID,
            ratingKey: ratingKey,
            fallback: details?.viewOffset
        ) ?? details?.viewOffset, offset > 0 else { return nil }
        return TimeInterval(offset) / 1000.0
    }

    var formattedDuration: String? {
        MediaTextFormatter.playbackDuration(milliseconds: details?.duration)
    }

    var formattedResume: String? {
        guard let seconds = resumePositionSeconds else { return nil }
        return MediaTextFormatter.playbackDuration(milliseconds: Int(seconds * 1000))
    }

    var mediaInfo: String? {
        guard let media = details?.media.first else { return nil }
        var parts: [String] = []
        if let res = media.videoResolution?.uppercased() {
            parts.append(res)
        }
        if let codec = media.videoCodec?.uppercased() {
            parts.append(codec)
        }
        if let audioCodec = media.audioCodec?.uppercased() {
            parts.append(audioCodec)
        }
        if let channels = media.audioChannels {
            parts.append("\(channels)ch")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var genreText: String? {
        guard let genres = details?.genres, !genres.isEmpty else { return nil }
        return genres.prefix(3).map(\.tag).joined(separator: ", ")
    }

    var directorText: String? {
        guard let directors = details?.directors, !directors.isEmpty else { return nil }
        return directors.map(\.tag).joined(separator: ", ")
    }

    func posterURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.thumb)
            ?? plexService.imageURL(for: details?.thumb, serverID: serverID, width: width, height: height)
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.art)
            ?? plexService.imageURL(for: details?.art, serverID: serverID, width: width, height: height)
    }

    func titleLogoURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.clearLogo)
            ?? plexService.imageURL(for: details?.clearLogo, serverID: serverID, width: width, height: height)
    }

    /// The route's server wins; the download record and the primary server are
    /// only fallbacks for an id that reached us without one (an offline cache).
    var serverID: String? {
        id.serverID
            ?? downloadManager?.serverID(for: id)
            ?? plexService.pool.primary?.serverID
    }
}

// MARK: - Subtitle Search

extension MovieDetailViewModel {
    /// Gated exactly like the player's entry point: Plex only lets the server
    /// owner (and non-restricted Home users) write sidecar files, and there has
    /// to be a real part on disk to write next to.
    var canDownloadSubtitles: Bool {
        plexService.canDownloadSubtitles(serverID: serverID) && !isUsingCachedData && hasPlayablePart
    }

    private var hasPlayablePart: Bool {
        details?.media.contains { !$0.parts.isEmpty } == true
    }

    /// Builds the flow's view model so the view never reaches for `PlexService`.
    /// Re-reading the item afterwards is what surfaces the new subtitle stream in
    /// the media info; the next playback session mounts it on its own.
    func makeSubtitleSearchViewModel(preferredLanguageCode: String?) -> SubtitleSearchViewModel {
        SubtitleSearchViewModel(
            plexService: plexService,
            ratingKey: ratingKey,
            serverID: serverID,
            preferredLanguageCode: preferredLanguageCode
        ) { [weak self] _ in
            await self?.refreshDetails()
        }
    }
}
