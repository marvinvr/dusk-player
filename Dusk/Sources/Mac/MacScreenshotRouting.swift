#if os(macOS) && DEBUG
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Screenshot mode (`ScreenshotMode`, DEBUG only) for the Mac shell: the
/// counterpart of `MainTabView.applyScreenshotDestination`. Opens the
/// requested sidebar destination, its routes and the player once the demo
/// servers and libraries are in. Settings screens are not routed: Settings is
/// its own scene on the Mac. See docs/screenshots.md and docs/macos.md.
extension MacRootView {
    func applyMacScreenshotDestination(libraries: () -> [Library]) async {
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

#if os(macOS) && DEBUG
/// `-DuskScreenshotUserPicker YES` (screenshot mode): presents the Switch
/// User sheet over the shell with sample Plex Home profiles, since the demo
/// account has no Plex Home. Self-check captures only.
enum MacScreenshotUserPicker {
    static var isRequested: Bool {
        ScreenshotMode.isActive && UserDefaults.standard.bool(forKey: "DuskScreenshotUserPicker")
    }

    static let sampleUsers: [PlexHomeUser] = {
        let json = """
        [{"id": 1, "title": "Marvin", "protected": true, "admin": true},
         {"id": 2, "title": "Anna Rezanova"},
         {"id": 3, "title": "Kids", "restricted": true}]
        """
        return (try? JSONDecoder().decode([PlexHomeUser].self, from: Data(json.utf8))) ?? []
    }()
}
#endif

#if os(macOS) && DEBUG
/// Screenshot mode (DEBUG only): the Mac app captures its own main window,
/// for the App Store screenshot tool.
///
/// `-DuskScreenshotCaptureFile <path.png> -DuskScreenshotCaptureAfter <s>`:
/// after `s` seconds the main window, with any menu it has popped up, is
/// written to `path.png` at full Retina resolution, without shadow (the tool
/// draws its own; the corners stay transparent), and the app quits.
/// `SCShareableContent.currentProcess` only lists this process's windows, so
/// no Screen Recording permission is involved. Needs an unlocked screen.
enum MacScreenshotCapture {
    @MainActor private static var started = false

    @MainActor static func startIfRequested() {
        guard ScreenshotMode.isActive, !started,
              let path = UserDefaults.standard.string(forKey: "DuskScreenshotCaptureFile")?.nilIfEmpty else { return }
        started = true
        let delay = max(UserDefaults.standard.double(forKey: "DuskScreenshotCaptureAfter"), 1)
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .seconds(delay))
            do {
                try await capture(to: URL(fileURLWithPath: path))
            } catch {
                try? "capture failed: \(error)".write(
                    to: URL(fileURLWithPath: path + ".error"), atomically: true, encoding: .utf8)
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    private static func capture(to url: URL) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let main = content.windows
            .filter({ $0.isOnScreen && $0.windowLayer == 0 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { throw CaptureError.noWindow }
        // The window's own capture already holds the menus it pops up.
        let filter = SCContentFilter(desktopIndependentWindow: main)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        try write(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), to: url)
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CaptureError.write }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.write }
    }

    private enum CaptureError: Error { case noWindow, write }
}

/// `-DuskScreenshotPlayerMenu media|more` (screenshot mode): the player's
/// play-bar menu of that name opens on its own once it has rows and stays
/// open (its tracking loop holds the HUD up), for the capture above.
enum MacScreenshotPlayerMenu {
    static var requested: String? {
        guard ScreenshotMode.isActive else { return nil }
        return UserDefaults.standard.string(forKey: "DuskScreenshotPlayerMenu")?.nilIfEmpty
    }
}
#endif
