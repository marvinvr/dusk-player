import SwiftUI

enum AppNavigationRoute: Hashable {
    case library(PlexLibrary)
    case libraryGenre(library: PlexLibrary, genre: LibraryGenreOption)
    case libraryCollection(library: PlexLibrary, collection: PlexLibraryCollection)
    case libraryRecommendations(PlexLibrary)
    case hub(PlexHub)
    case media(type: PlexMediaType, ratingKey: String)
    case downloadedMedia(type: PlexMediaType, ratingKey: String)
    case video(ratingKey: String)
    case downloadedVideo(ratingKey: String)
    case person(PlexPersonReference)

    static func destination(for item: PlexItem) -> Self {
        if let person = PlexPersonReference(item: item) {
            return .person(person)
        }

        // Clips report `type == "movie"` with `subtype == "clip"`, so they must
        // never fall through to the movie detail flow.
        if item.isClip {
            return .video(ratingKey: item.ratingKey)
        }

        return .media(type: item.type, ratingKey: item.ratingKey)
    }
}

struct AppNavigationDestinationView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager

    let route: AppNavigationRoute

    @ViewBuilder
    var body: some View {
        switch route {
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
        case let .media(type, ratingKey):
            MediaDetailDestinationView(
                type: type,
                ratingKey: ratingKey,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case let .downloadedMedia(type, ratingKey):
            MediaDetailDestinationView(
                type: type,
                ratingKey: ratingKey,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                prefersOfflineAvailability: DownloadsFeature.isVisible
            )
        case let .video(ratingKey):
            VideoDetailView(
                ratingKey: ratingKey,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case let .downloadedVideo(ratingKey):
            VideoDetailView(
                ratingKey: ratingKey,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager
            )
        case .person(let person):
            ActorDetailView(person: person, plexService: plexService)
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
