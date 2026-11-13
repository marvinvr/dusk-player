#if os(macOS)
import SwiftUI

/// The one right-click menu for a movie, show, season, episode or video on the
/// Mac: every poster, shelf card and the Home hero use it, so the same item
/// always offers the same commands in the same order.
///
///     Play / Resume
///     Go to Episode/Movie…, Go to Season, Go to Show
///     ─
///     Mark as Watched  or  Mark as Unwatched (by state)
///     Remove from Continue Watching (Continue Watching only)
///     Add to Playlist…, Add to/Remove from Watchlist, Download
///
/// A screen appends its own section after it (Home's "Hide Row").
/// iOS/tvOS keep `PlexItemContextMenuContent` / `HomeItemContextMenu` as they are.
struct MacItemContextMenu: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager

    let item: PlexItem
    var onMarkWatched: (() -> Void)?
    var onMarkUnwatched: (() -> Void)?
    /// The item's own page, when the click target doesn't already open it.
    var detailsRoute: AppNavigationRoute? = nil
    var detailsLabel: String = "View Details"
    var showsAddToPlaylist = true
    /// A Continue Watching card: an in-progress copy can always be marked
    /// watched (the scrobble that takes it off the row), and can be removed.
    var isContinueWatching = false
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    /// Pushes a route; without it the "Go to" items are navigation links.
    var onSelectRoute: ((AppNavigationRoute) -> Void)? = nil

    var body: some View {
        if let playTitle {
            Button(playTitle, systemImage: "play.fill", action: play)
        }

        if let detailsRoute {
            routeButton(detailsLabel, systemImage: "info.circle", route: detailsRoute)
        }

        if let seasonRoute = item.contextMenuSeasonRoute {
            routeButton("Go to Season", systemImage: "rectangle.stack", route: seasonRoute)
        }

        if let showRoute = item.contextMenuShowRoute {
            routeButton("Go to Show", systemImage: "tv", route: showRoute)
        }

        Divider()

        switch watchedAction {
        case .markWatched:
            if let onMarkWatched {
                Button("Mark as Watched", systemImage: "checkmark.circle", action: onMarkWatched)
            }
        case .markUnwatched:
            if let onMarkUnwatched {
                Button("Mark as Unwatched", systemImage: "circle", action: onMarkUnwatched)
            }
        case nil:
            EmptyView()
        }

        if let onRemoveFromContinueWatching {
            Button(
                "Remove from Continue Watching",
                systemImage: "minus.circle",
                action: onRemoveFromContinueWatching
            )
        }

        if showsAddToPlaylist {
            AddToPlaylistMenuButton(target: AddToPlaylistTarget(item: item))
        }

        WatchlistMenuButton(item: item)

        downloadItem
    }

    // MARK: - Play

    private var playTitle: String? {
        switch item.type {
        case .movie, .episode, .clip:
            return (item.viewOffset ?? 0) > 0 && !item.isWatched ? "Resume" : "Play"
        default:
            return nil
        }
    }

    private func play() {
        let item = item
        let playback = playback
        Task {
            await playback.play(
                id: item.id,
                resumeOffsetMilliseconds: item.isWatched ? nil : item.viewOffset,
                resumeOffsetDurationMilliseconds: item.duration,
                placeholder: PlaybackPlaceholder(item: item)
            )
        }
    }

    // MARK: - Navigation

    @ViewBuilder
    private func routeButton(_ title: String, systemImage: String, route: AppNavigationRoute) -> some View {
        if let onSelectRoute {
            Button(title, systemImage: systemImage) { onSelectRoute(route) }
        } else {
            NavigationLink(value: route) {
                Label(title, systemImage: systemImage)
            }
        }
    }

    // MARK: - Watched

    private enum WatchedAction {
        case markWatched
        case markUnwatched
    }

    /// One entry, by state: a finished item can be marked unwatched, anything
    /// else (unwatched, in progress, a partly watched show) watched.
    private var watchedAction: WatchedAction? {
        let canMarkWatched = isContinueWatching
            ? item.canMarkWatchedFromContinueWatchingMenu
            : item.canMarkWatchedFromContextMenu
        if canMarkWatched { return .markWatched }
        if item.canMarkUnwatchedFromContextMenu { return .markUnwatched }
        return nil
    }

    // MARK: - Download

    @ViewBuilder
    private var downloadItem: some View {
        if DownloadsFeature.isVisible, let scope = downloadScope {
            let state = downloadManager.downloadState(for: scope)
            switch state.status {
            case nil, .cancelled?:
                if item.isClip {
                    Button("Download", systemImage: "arrow.down.circle") {
                        queueDownload(scope, quality: .original)
                    }
                } else {
                    Menu {
                        ForEach(DownloadQuality.allCases) { quality in
                            Button(quality.displayName) {
                                queueDownload(scope, quality: quality)
                            }
                        }
                    } label: {
                        Label(downloadTitle, systemImage: "arrow.down.circle")
                    }
                }
            case .failed?:
                Button("Retry Download", systemImage: "arrow.clockwise") {
                    if scope.type == .season || scope.type == .show {
                        queueDownload(scope, quality: nil)
                    } else {
                        downloadManager.retryDownload(id: scope.id)
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    private var downloadScope: DownloadScope? {
        switch item.type {
        case .movie, .episode, .season, .show, .clip:
            return DownloadScope(id: item.id, type: item.type)
        default:
            return nil
        }
    }

    private var downloadTitle: String {
        switch item.type {
        case .season: "Download Season"
        case .show: "Download Show"
        default: "Download"
        }
    }

    private func queueDownload(_ scope: DownloadScope, quality: DownloadQuality?) {
        let downloadManager = downloadManager
        let isClip = item.isClip
        Task {
            await downloadManager.queueDownload(id: scope.id, type: scope.type, isClip: isClip, quality: quality)
        }
    }
}
extension PlexItem {
    /// An episode card's title on the Mac's episode rows: "S2 E3 · Title".
    var macEpisodeCardTitle: String {
        let number = [parentIndex.map { "S\($0)" }, index.map { "E\($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")
        return [number.nilIfEmpty, title.nilIfEmpty]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
#endif
