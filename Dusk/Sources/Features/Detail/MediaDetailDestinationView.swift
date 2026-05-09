import SwiftUI

struct MediaDetailDestinationView: View {
    let type: PlexMediaType
    let ratingKey: String
    let plexService: PlexService
    let downloadManager: DownloadManager?
    let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    let prefersOfflineAvailability: Bool

    init(
        type: PlexMediaType,
        ratingKey: String,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        self.type = type
        self.ratingKey = ratingKey
        self.plexService = plexService
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
        self.prefersOfflineAvailability = prefersOfflineAvailability
    }

    @ViewBuilder
    var body: some View {
        switch type {
        case .movie:
            MovieDetailView(
                ratingKey: ratingKey,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case .show:
            ShowDetailView(
                ratingKey: ratingKey,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                prefersOfflineAvailability: prefersOfflineAvailability
            )
        case .person:
            ActorDetailView(
                person: PlexPersonReference(personID: ratingKey, name: "Actor", thumb: nil),
                plexService: plexService
            )
        case .season:
            SeasonDetailView(
                ratingKey: ratingKey,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                prefersOfflineAvailability: prefersOfflineAvailability
            )
        case .episode:
            EpisodeDetailView(
                ratingKey: ratingKey,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        default:
            MovieDetailView(
                ratingKey: ratingKey,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        }
    }
}
