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
    /// A movie or TV library's Plex collections. A collection itself opens
    /// as `.media(type: .collection, id:)`.
    case libraryCollections(PlexLibrary)
    case libraryRecommendations(PlexLibrary)
    case photoAlbum(PhotoAlbumRoute)
    case hub(PlexHub)
    /// A Plex playlist, on its own server.
    case playlist(id: PlexItemID)
    case media(type: PlexMediaType, id: PlexItemID)
    case downloadedMedia(type: PlexMediaType, id: PlexItemID)
    case video(id: PlexItemID)
    /// A video or movie opened from a list it plays through
    /// (`PlaybackListContext`): its Play continues with the following items.
    case videoInList(id: PlexItemID, list: PlaybackListContext)
    case movieInList(id: PlexItemID, list: PlaybackListContext)
    case downloadedVideo(id: PlexItemID)
    /// Person tag ids are per-server too, so the route carries the server the
    /// credit was read from; nil falls back to the primary server.
    case person(PlexPersonReference, serverID: String?)
    case seerrMedia(type: SeerrMediaType, id: Int)
    case seerrSeason(tvID: Int, seasonNumber: Int)
    /// A Plex Watchlist title on none of the connected servers (one that is
    /// opens as `.media`). See `WatchlistItemDetailView`.
    case watchlistItem(PlexWatchlistEntry)
    /// Library Order, reached from the library tabs.
    case libraryOrder
    #if DEBUG
    /// Screenshot mode only (`ScreenshotMode`): Settings › Server Priority is
    /// otherwise reached through a plain NavigationLink.
    case screenshotServerPriority
    /// Screenshot mode only: Settings › Libraries › Hidden Libraries.
    case screenshotHiddenLibraries
    /// Screenshot mode only: Settings › Trakt.
    case screenshotTrakt
    /// Screenshot mode only: Settings › Live TV › IPTV Sources.
    case screenshotIPTVSources
    #endif

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

    /// Pages headed by `DetailHeroSection`.
    var isDetailPage: Bool {
        switch self {
        case .playlist, .media, .downloadedMedia, .video, .videoInList, .movieInList, .downloadedVideo,
             .seerrMedia, .seerrSeason, .watchlistItem:
            true
        default:
            false
        }
    }
}

#if os(iOS)
/// iPhone Duo's inner display is regular width, which gave detail pages the
/// iPad two-column hero. At 669pt that column sat high on the darkened
/// backdrop, so its metadata read dark-on-dark, and its synopsis column was
/// too narrow. There the detail pages take the iPhone layout instead (centred
/// hero over the bottom fade, synopsis below it), as on the cover display.
/// Every other device keeps its own size class.
private struct DuoInnerDisplayDetailLayout: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let isDetailPage: Bool

    func body(content: Content) -> some View {
        let usesPhoneLayout = isDetailPage && sizeClass == .regular && DuskDuoDisplay.isInner
        content
            .environment(\.horizontalSizeClass, usesPhoneLayout ? .compact : sizeClass)
    }
}
#endif

struct AppNavigationDestinationView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager
    @Environment(SeerrService.self) private var seerrService

    let route: AppNavigationRoute

    var body: some View {
        #if os(iOS)
        destination
            .modifier(DuoInnerDisplayDetailLayout(isDetailPage: route.isDetailPage))
        #else
        destination
        #endif
    }

    @ViewBuilder
    private var destination: some View {
        switch route {
        case .search:
            SearchRootContent()
        case .library(let library):
            if library.libraryType == .photo {
                PhotoBrowserView(library: library, plexService: plexService)
            } else {
                LibraryItemsView(library: library, plexService: plexService)
            }
        case .photoAlbum(let album):
            PhotoBrowserView(library: album.library, album: album, plexService: plexService)
        case .libraryGenre(let library, let genre):
            LibraryItemsView(
                library: library,
                plexService: plexService,
                initialGenre: genre
            )
        case .libraryCollection(let library, let collection):
            LibraryCollectionItemsView(library: library, collection: collection)
        case .libraryCollections(let library):
            LibraryCollectionsView(library: library, plexService: plexService)
        case .libraryRecommendations(let library):
            LibraryRecommendationsView(
                library: library,
                plexService: plexService,
                navigationTitle: library.title
            )
        case .hub(let hub):
            HomeHubItemsView(hub: hub, plexService: plexService)
        case .playlist(let id):
            PlaylistDetailView(id: id, plexService: plexService)
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
        case let .videoInList(id, list):
            VideoDetailView(
                id: id,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                playThrough: list
            )
        case let .movieInList(id, list):
            MovieDetailView(
                id: id,
                plexService: plexService,
                downloadManager: downloadManager,
                offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                playThrough: list
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
        case let .watchlistItem(entry):
            WatchlistItemDetailView(entry: entry, plexService: plexService)
        case .libraryOrder:
            LibraryOrderSettingsView()
        #if DEBUG
        case .screenshotServerPriority:
            ServerPrioritySettingsView()
        case .screenshotHiddenLibraries:
            HiddenLibrariesSettingsView()
        case .screenshotTrakt:
            TraktSettingsView()
        case .screenshotIPTVSources:
            IPTVSourcesSettingsView()
        #endif
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
