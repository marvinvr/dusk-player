import SwiftUI

struct MediaDetailDestinationView: View {
    let type: MediaKind
    let id: MediaItemID
    let media: MediaService
    let seerrService: SeerrService?
    let downloadManager: DownloadManager?
    let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    let prefersOfflineAvailability: Bool

    init(
        type: MediaKind,
        id: MediaItemID,
        media: MediaService,
        seerrService: SeerrService? = nil,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        self.type = type
        self.id = id
        self.media = media
        self.seerrService = seerrService
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
        self.prefersOfflineAvailability = prefersOfflineAvailability
    }

    @ViewBuilder
    var body: some View {
        switch type {
        case .movie:
            MovieDetailView(
                id: id,
                media: media,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        #if os(tvOS)
        // tvOS has one page per show: a show, season, or episode route all open
        // it, on the season (and episode) the route points at.
        case .show:
            seriesDetail(entry: .show)
        case .season:
            seriesDetail(entry: .season)
        case .episode:
            seriesDetail(entry: .episode)
        #else
        case .show:
            ShowDetailView(
                id: id,
                media: media,
                seerrService: seerrService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                prefersOfflineAvailability: prefersOfflineAvailability
            )
        case .season:
            SeasonDetailView(
                id: id,
                media: media,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                prefersOfflineAvailability: prefersOfflineAvailability
            )
        case .episode:
            EpisodeDetailView(
                id: id,
                media: media,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        #endif
        case .person:
            ActorDetailView(
                person: PersonReference(personID: id.itemID, name: "Actor", thumb: nil),
                serverID: id.serverID,
                media: media
            )
        case .collection:
            CollectionDetailView(id: id, media: media)
        case .clip:
            // Clips normally route through `.video`; this catches legacy
            // `.media(type: .clip, ...)` paths so they never open MovieDetailView.
            VideoDetailView(
                id: id,
                media: media,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        default:
            MovieDetailView(
                id: id,
                media: media,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        }
    }

    #if os(tvOS)
    private func seriesDetail(entry: SeriesDetailViewModel.Entry) -> some View {
        SeriesDetailView(
            entry: entry,
            id: id,
            media: media,
            seerrService: seerrService,
            downloadManager: downloadManager,
            offlinePlaybackSyncManager: offlinePlaybackSyncManager,
            prefersOfflineAvailability: prefersOfflineAvailability
        )
    }
    #endif
}
