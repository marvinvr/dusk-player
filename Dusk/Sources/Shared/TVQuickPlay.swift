import SwiftUI

extension View {
    /// tvOS: the remote's Play/Pause on this focused card starts playback
    /// instead of opening the card's page, as the other Apple TV apps do
    /// (issue #86). Select keeps opening the page.
    ///
    /// A movie, video or episode plays from its saved position. A show or
    /// season plays the episode its page's Play button would
    /// (`SeriesDetailViewModel.playTarget`). Other routes keep the system
    /// behaviour. `item` is the card's hub item when known: its offset is the
    /// fallback when the item's own metadata has none (see
    /// `PlaybackCoordinator.play`). No-op on iOS and macOS.
    @ViewBuilder
    func tvQuickPlay(route: AppNavigationRoute, item: MediaItem? = nil) -> some View {
        #if os(tvOS)
        if let target = TVQuickPlayTarget(route: route) {
            modifier(TVQuickPlayModifier(target: target, item: item))
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// tvOS: Play/Pause on this focused card runs `action`, for cards whose
    /// Select already plays (Continue Watching, episode rows, extras).
    @ViewBuilder
    func tvQuickPlay(action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onPlayPauseCommand(perform: action)
        #else
        self
        #endif
    }
}

#if os(tvOS)
/// What Play/Pause on a card route starts.
enum TVQuickPlayTarget {
    /// A movie, video or episode, played straight away.
    case item(id: MediaItemID, list: PlaybackListContext?)
    /// A show or season: resolve its next-up episode first.
    case series(entry: SeriesDetailViewModel.Entry, id: MediaItemID, prefersOfflineAvailability: Bool)

    init?(route: AppNavigationRoute) {
        switch route {
        case let .media(type, id):
            self.init(type: type, id: id, prefersOfflineAvailability: false)
        case let .downloadedMedia(type, id):
            self.init(type: type, id: id, prefersOfflineAvailability: DownloadsFeature.isVisible)
        case let .video(id), let .downloadedVideo(id):
            self = .item(id: id, list: nil)
        case let .videoInList(id, list), let .movieInList(id, list):
            self = .item(id: id, list: list)
        default:
            return nil
        }
    }

    private init?(type: MediaKind, id: MediaItemID, prefersOfflineAvailability: Bool) {
        switch type {
        case .movie, .episode, .clip:
            self = .item(id: id, list: nil)
        case .show:
            self = .series(entry: .show, id: id, prefersOfflineAvailability: prefersOfflineAvailability)
        case .season:
            self = .series(entry: .season, id: id, prefersOfflineAvailability: prefersOfflineAvailability)
        default:
            return nil
        }
    }
}

private struct TVQuickPlayModifier: ViewModifier {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager

    let target: TVQuickPlayTarget
    let item: MediaItem?

    func body(content: Content) -> some View {
        content.onPlayPauseCommand(perform: start)
    }

    private func start() {
        // A show resolves its episode over the network first; a second press
        // meanwhile must not queue a second start.
        guard !playback.showPlayer, !TVQuickPlayGate.isResolving else { return }
        switch target {
        case let .item(id, list):
            let matchingItem = item?.id == id ? item : nil
            Task {
                await playback.play(
                    id: id,
                    resumeOffsetMilliseconds: matchingItem?.resumeOffsetMs,
                    resumeOffsetDurationMilliseconds: matchingItem?.duration,
                    placeholder: matchingItem.map(PlaybackPlaceholder.init(item:)),
                    queue: list?.queue(startingAt: id)
                )
            }
        case let .series(entry, id, prefersOfflineAvailability):
            TVQuickPlayGate.isResolving = true
            Task {
                defer { TVQuickPlayGate.isResolving = false }
                guard let episode = await SeriesDetailViewModel.playTarget(
                    entry: entry,
                    id: id,
                    plexService: plexService,
                    downloadManager: downloadManager,
                    offlinePlaybackSyncManager: offlinePlaybackSyncManager,
                    prefersOfflineAvailability: prefersOfflineAvailability
                ), !playback.showPlayer else { return }
                // As the series page's episode Play button does.
                await playback.play(
                    id: episode.id,
                    resumeOffsetMilliseconds: episode.resumeOffsetMs,
                    resumeOffsetDurationMilliseconds: episode.duration,
                    placeholder: PlaybackPlaceholder(episode: episode)
                )
            }
        }
    }
}

@MainActor
private enum TVQuickPlayGate {
    static var isResolving = false
}
#endif
