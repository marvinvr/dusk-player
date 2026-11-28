import Foundation

@MainActor
@Observable
final class MovieDetailViewModel {
    private let media: MediaService
    private let downloadManager: DownloadManager?
    private let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    /// Server-scoped identity of the movie. Every request this model makes goes
    /// to `id.serverID`, never to whichever server happens to be primary.
    let id: MediaItemID

    var itemID: String { id.itemID }

    private(set) var details: MediaDetails?
    private(set) var copies: [MediaDetails] = []

    var versions: [MoviePlaybackVersion] {
        MoviePlaybackVersion.versions(in: copies.isEmpty ? [details].compactMap { $0 } : copies)
    }

    var resumeDetails: MediaDetails? {
        MoviePlaybackVersion.mostAdvancedCopy(in: copies) ?? details
    }

    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isUsingCachedData = false
    private(set) var offlineStateVersion = 0

    init(
        id: MediaItemID,
        media: MediaService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil
    ) {
        self.id = id
        self.media = media
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
            let fetched = try await media.getMediaDetails(itemID: itemID, serverID: serverID)
            details = fetched
            copies = await media.movieCopies(for: fetched)
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
                itemID: itemID,
                watched: targetWatched
            )
            offlineStateVersion += 1
            await offlinePlaybackSyncManager?.syncPendingActions(force: true)
            return
        }

        do {
            try await media.setWatchedAcrossServers(
                targetWatched,
                id: MediaItemID(serverID: serverID, itemID: itemID)
            )
            await refreshDetails()
        } catch {
            if isPlayableOffline {
                offlinePlaybackSyncManager?.recordWatchState(
                    serverID: serverID,
                    itemID: itemID,
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
        let fallback = (resumeDetails?.playCount ?? 0) > 0
        return offlinePlaybackSyncManager?.effectiveWatched(
            serverID: serverID,
            itemID: itemID,
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
            itemID: itemID,
            fallback: resumeDetails?.resumeOffsetMs
        ) ?? resumeDetails?.resumeOffsetMs, offset > 0 else { return nil }
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
        MediaTextFormatter.mediaInfoLine(details?.media.first)
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
            ?? media.imageURL(for: ArtworkRef(serverID: serverID, path: details?.thumb), size: ImageSize(width: width, height: height))
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.art)
            ?? media.imageURL(for: ArtworkRef(serverID: serverID, path: details?.art), size: ImageSize(width: width, height: height))
    }

    func titleLogoURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.clearLogo)
            ?? media.imageURL(for: ArtworkRef(serverID: serverID, path: details?.clearLogo), size: ImageSize(width: width, height: height))
    }

    /// The route's server wins; the download record and the primary server are
    /// only fallbacks for an id that reached us without one (an offline cache).
    var serverID: String? {
        id.serverID
            ?? downloadManager?.serverID(for: id)
            ?? media.pool.primary?.serverID
    }
}

// MARK: - Subtitle Search

extension MovieDetailViewModel {
    /// Gated exactly like the player's entry point: Plex only lets the server
    /// owner (and non-restricted Home users) write sidecar files, and there has
    /// to be a real part on disk to write next to.
    var canDownloadSubtitles: Bool {
        media.canDownloadSubtitles(serverID: serverID) && !isUsingCachedData && hasPlayablePart
    }

    private var hasPlayablePart: Bool {
        details?.media.contains { !$0.parts.isEmpty } == true
    }

    /// Builds the flow's view model so the view never reaches for `MediaService`.
    /// Re-reading the item afterwards is what surfaces the new subtitle stream in
    /// the media info; the next playback session mounts it on its own.
    func makeSubtitleSearchViewModel(preferredLanguageCode: String?) -> SubtitleSearchViewModel {
        SubtitleSearchViewModel(
            media: media,
            itemID: itemID,
            serverID: serverID,
            preferredLanguageCode: preferredLanguageCode
        ) { [weak self] _ in
            await self?.refreshDetails()
        }
    }
}
