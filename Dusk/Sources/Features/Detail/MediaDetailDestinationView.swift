import SwiftUI

struct MediaDetailDestinationView: View {
    let type: PlexMediaType
    let id: PlexItemID
    let plexService: PlexService
    let seerrService: SeerrService?
    let downloadManager: DownloadManager?
    let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    let prefersOfflineAvailability: Bool

    init(
        type: PlexMediaType,
        id: PlexItemID,
        plexService: PlexService,
        seerrService: SeerrService? = nil,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        self.type = type
        self.id = id
        self.plexService = plexService
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
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case .show:
            ShowDetailView(
                id: id,
                plexService: plexService,
                seerrService: seerrService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                prefersOfflineAvailability: prefersOfflineAvailability
            )
        case .person:
            ActorDetailView(
                person: PlexPersonReference(personID: id.ratingKey, name: "Actor", thumb: nil),
                serverID: id.serverID,
                plexService: plexService
            )
        case .season:
            SeasonDetailView(
                id: id,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                prefersOfflineAvailability: prefersOfflineAvailability
            )
        case .episode:
            EpisodeDetailView(
                id: id,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case .clip:
            // Clips normally route through `.video`; this catches legacy
            // `.media(type: .clip, ...)` paths so they never open MovieDetailView.
            VideoDetailView(
                id: id,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        default:
            MovieDetailView(
                id: id,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        }
    }
}
