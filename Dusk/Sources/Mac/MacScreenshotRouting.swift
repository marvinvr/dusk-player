#if os(macOS) && DEBUG
import SwiftUI

/// Screenshot mode (`ScreenshotMode`, DEBUG only) for the Mac shell: the
/// counterpart of `MainTabView.applyScreenshotDestination`. Opens the
/// requested sidebar destination, its routes and the player once the demo
/// servers and libraries are in. Settings screens are not routed: Settings is
/// its own scene on the Mac. See docs/screenshots.md and docs/macos.md.
extension MacRootView {
    func applyMacScreenshotDestination(libraries: () -> [PlexLibrary]) async {
        guard ScreenshotMode.isActive else { return }
        for _ in 0..<80 {
            if let destination = await ScreenshotMode.consumeDestination(
                plexService: plexService,
                libraries: libraries(),
                downloadManager: downloadManager
            ) {
                var tab = destination.tab
                var routes = destination.routes
                if case .search? = routes.first {
                    tab = .search
                    routes.removeFirst()
                }
                if tab == .playlists {
                    await plexService.loadPlaylists()
                }
                if tab == .settings || tab == .more {
                    tab = .home
                    routes = []
                }
                router.activate(tab)
                router.setPath(NavigationPath(routes), for: tab)
                if let target = destination.addToPlaylist {
                    try? await Task.sleep(for: .seconds(1.5))
                    addToPlaylist.present(target)
                }
                if let playlistID = destination.playlistID,
                   let playlist = try? await plexService.getPlaylist(ratingKey: playlistID.ratingKey, serverID: playlistID.serverID),
                   let entries = try? await plexService.getPlaylistEntries(ratingKey: playlist.ratingKey, serverID: playlist.serverID),
                   let queue = PlaylistActions(plexService: plexService).queue(
                       for: playlist,
                       entries: entries,
                       startIndex: destination.playlistStart
                   ) {
                    try? await Task.sleep(for: .seconds(1))
                    await playback.playQueue(queue)
                }
                if let playID = destination.playID {
                    await playback.playForScreenshot(
                        id: playID,
                        startPosition: destination.playOffsetMilliseconds.map { TimeInterval($0) / 1000 }
                    )
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
    }
}
#endif
