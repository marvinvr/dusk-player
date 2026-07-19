import Foundation

/// Detail model for video clips ("Other Videos" / YouTube-style libraries).
/// Mirrors `MovieDetailViewModel` for metadata, playback resume, watched state,
/// and offline fallback, plus the online-only "More from this channel" row
/// resolved from the clip's first Collection tag (one collection per channel).
@MainActor
@Observable
final class VideoDetailViewModel {
    private static let channelRowFetchSize = 13
    private static let channelRowItemLimit = 12

    private let plexService: PlexService
    private let downloadManager: DownloadManager?
    private let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    let ratingKey: String

    private(set) var details: PlexMediaDetails?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isUsingCachedData = false
    private(set) var offlineStateVersion = 0

    /// Other videos from the same channel (collection), newest first, excluding
    /// this video. Empty when the row cannot be resolved (no collection tag, no
    /// section id, offline, or fetch failure) — the view hides the row then.
    private(set) var channelItems: [PlexItem] = []
    private(set) var channelShowAllRoute: AppNavigationRoute?
    @ObservationIgnored private var channelTask: Task<Void, Never>?
    @ObservationIgnored private var loadedChannelContext: String?

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

    func loadDetails() async {
        guard details == nil else { return }
        await refreshDetails()
    }

    func refreshDetails() async {
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

        loadChannelItemsIfNeeded()
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
            try await plexService.setWatched(targetWatched, ratingKey: ratingKey)
            self.details = try await plexService.getMediaDetails(ratingKey: ratingKey)
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
        downloadManager?.isPlayableOffline(ratingKey: ratingKey) == true
    }

    var offlineBannerText: String? {
        guard DownloadsFeature.isVisible, isUsingCachedData else { return nil }
        return isPlayableOffline
            ? "Showing saved video metadata. This video is available offline."
            : "Showing saved video metadata. This video is not downloaded on this device."
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

    var formattedResume: String? {
        guard let seconds = resumePositionSeconds else { return nil }
        return MediaTextFormatter.playbackDuration(milliseconds: Int(seconds * 1000))
    }

    /// The channel the video belongs to: video libraries carry one Collection
    /// tag per channel.
    var channelName: String? {
        details?.collections?.first?.tag.nilIfEmpty
    }

    var channelRowTitle: String? {
        channelName.map { "More from \($0)" }
    }

    /// "channel · upload date · duration", omitting missing parts.
    var metadataLine: String? {
        let parts = [
            channelName,
            MediaTextFormatter.localizedVideoDate(details?.originallyAvailableAt),
            MediaTextFormatter.compactDuration(milliseconds: details?.duration),
        ].compactMap { $0 }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        // A clip's `art` is rare; its `thumb` (16:9 frame grab) works as backdrop.
        let path = details?.art ?? details?.thumb
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, width: width, height: height)
    }

    private var serverID: String? {
        downloadManager?.serverID(for: ratingKey) ?? plexService.currentServerIdentifier
    }

    // MARK: - Channel Row

    private func loadChannelItemsIfNeeded() {
        // The row is online-only: hide it while showing cached (offline) metadata
        // or when the details carry no section/channel to resolve it from.
        guard !isUsingCachedData,
              let details,
              let sectionID = details.librarySectionID,
              let channelTag = details.collections?.first?.tag.nilIfEmpty else {
            channelTask?.cancel()
            channelTask = nil
            loadedChannelContext = nil
            channelItems = []
            channelShowAllRoute = nil
            return
        }

        let context = "\(sectionID)|\(channelTag.lowercased())"
        guard context != loadedChannelContext else { return }

        channelTask?.cancel()
        channelTask = Task { [weak self] in
            await self?.loadChannelItems(sectionID: sectionID, channelTag: channelTag, context: context)
        }
    }

    private func loadChannelItems(sectionID: String, channelTag: String, context: String) async {
        do {
            let collections = try await plexService.getLibraryCollections(sectionId: sectionID)
            guard let collection = collections.first(where: {
                $0.title.caseInsensitiveCompare(channelTag) == .orderedSame
            }) else {
                guard !Task.isCancelled else { return }
                loadedChannelContext = context
                channelItems = []
                channelShowAllRoute = nil
                return
            }

            let items = try await plexService.getLibraryItems(
                sectionId: sectionID,
                size: Self.channelRowFetchSize,
                sort: "originallyAvailableAt:desc",
                filters: ["collection": collection.key]
            )

            // The library is only needed for the "Show all" route; failing to
            // resolve it must not hide the row itself.
            let library = (try? await plexService.getLibraries())?.first { $0.key == sectionID }

            guard !Task.isCancelled else { return }
            loadedChannelContext = context
            channelItems = Array(
                items
                    .filter { $0.ratingKey != ratingKey }
                    .prefix(Self.channelRowItemLimit)
            )
            channelShowAllRoute = library.map { .libraryCollection(library: $0, collection: collection) }
        } catch {
            // The row is a bonus; failures just hide it without surfacing errors.
            guard !Task.isCancelled else { return }
            channelItems = []
            channelShowAllRoute = nil
        }
    }
}
