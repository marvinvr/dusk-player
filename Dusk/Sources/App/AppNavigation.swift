import SwiftUI

/// Every media route carries a `PlexItemID`, not a bare rating key: rating keys
/// are per-server counters that collide across servers, so a route without the
/// server would open whatever item happens to share that key on the primary
/// one. Navigating from an item therefore always opens it on *its* server.
enum AppNavigationRoute: Hashable {
    case search
    case library(PlexLibrary)
    case libraryGenre(library: PlexLibrary, genre: LibraryGenreOption)
    case libraryCollection(library: PlexLibrary, collection: PlexLibraryCollection)
    case libraryRecommendations(PlexLibrary)
    case hub(PlexHub)
    case media(type: PlexMediaType, id: PlexItemID)
    case downloadedMedia(type: PlexMediaType, id: PlexItemID)
    case video(id: PlexItemID)
    case downloadedVideo(id: PlexItemID)
    /// Person tag ids are per-server too, so the route carries the server the
    /// credit was read from; nil falls back to the primary server.
    case person(PlexPersonReference, serverID: String?)
    case seerrMedia(type: SeerrMediaType, id: Int)
    case seerrSeason(tvID: Int, seasonNumber: Int)

    static func destination(for item: PlexItem) -> Self {
        if let person = PlexPersonReference(item: item) {
            return .person(person, serverID: item.serverID)
        }

        // Clips report `type == "movie"` with `subtype == "clip"`, so they must
        // never fall through to the movie detail flow.
        if item.isClip {
            return .video(id: item.id)
        }

        return .media(type: item.type, id: item.id)
    }
}

struct AppNavigationDestinationView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager
    @Environment(SeerrService.self) private var seerrService

    let route: AppNavigationRoute

    @ViewBuilder
    var body: some View {
        switch route {
        case .search:
            SearchRootContent()
        case .library(let library):
            LibraryItemsView(library: library, plexService: plexService)
        case .libraryGenre(let library, let genre):
            LibraryItemsView(
                library: library,
                plexService: plexService,
                initialGenre: genre,
                preferLocalGenreFiltering: true
            )
        case .libraryCollection(let library, let collection):
            LibraryCollectionItemsView(library: library, collection: collection)
        case .libraryRecommendations(let library):
            LibraryRecommendationsView(
                library: library,
                plexService: plexService,
                navigationTitle: library.title
            )
        case .hub(let hub):
            HomeHubItemsView(hub: hub, plexService: plexService)
        case let .media(type, id):
            MediaDetailDestinationView(
                type: type,
                id: id,
                plexService: plexService,
                seerrService: seerrService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case let .downloadedMedia(type, id):
            MediaDetailDestinationView(
                type: type,
                id: id,
                plexService: plexService,
                seerrService: seerrService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                prefersOfflineAvailability: DownloadsFeature.isVisible
            )
        case let .video(id):
            VideoDetailView(
                id: id,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case let .downloadedVideo(id):
            VideoDetailView(
                id: id,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case let .person(person, serverID):
            ActorDetailView(person: person, serverID: serverID, plexService: plexService)
        case let .seerrMedia(type, id):
            SeerrMediaDetailView(mediaType: type, mediaID: id, service: seerrService)
        case let .seerrSeason(tvID, seasonNumber):
            SeerrSeasonDetailView(
                tvID: tvID,
                seasonNumber: seasonNumber,
                service: seerrService
            )
        }
    }
}

extension View {
    func duskAppNavigationDestinations() -> some View {
        navigationDestination(for: AppNavigationRoute.self) { route in
            AppNavigationDestinationView(route: route)
        }
    }
}
