import SwiftUI
import UIKit
#if os(iOS)
import AVFoundation
#endif

enum AppImageCache {
    static let memoryCapacity = 0
    static let diskCapacity = 200_000_000

    static let shared = URLCache(
        memoryCapacity: memoryCapacity,
        diskCapacity: diskCapacity
    )

    static func configureSharedCache() {
        if URLCache.shared !== shared {
            URLCache.shared = shared
        }
    }

    static func clear() {
        shared.removeAllCachedResponses()
    }
}

#if os(iOS)
final class DuskAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadBackgroundSessionRegistry.setCompletionHandler(completionHandler, for: identifier)
    }
}
#endif

@main
struct DuskApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(DuskAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    @State private var plexService: PlexService
    @State private var playbackCoordinator: PlaybackCoordinator
    @State private var downloadManager: DownloadManager
    @State private var offlinePlaybackSyncManager: OfflinePlaybackSyncManager
    @State private var userPreferences = UserPreferences()

    init() {
        AppImageCache.configureSharedCache()
        let service = PlexService()
        let prefs = UserPreferences()
        let downloads = DownloadManager(plexService: service, preferences: prefs)
        let playbackSync = OfflinePlaybackSyncManager(plexService: service)
        _plexService = State(initialValue: service)
        _downloadManager = State(initialValue: downloads)
        _offlinePlaybackSyncManager = State(initialValue: playbackSync)
        _playbackCoordinator = State(initialValue: PlaybackCoordinator(
            plexService: service,
            preferences: prefs,
            downloadManager: downloads,
            offlinePlaybackSyncManager: playbackSync
        ))
        _userPreferences = State(initialValue: prefs)
        #if os(iOS)
        Self.configurePlaybackAudioSession()
        Self.configureTabBarAppearance()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(plexService)
                .environment(playbackCoordinator)
                .environment(downloadManager)
                .environment(offlinePlaybackSyncManager)
                .environment(userPreferences)
                .preferredColorScheme(userPreferences.appearanceMode.preferredColorScheme)
                .tint(Color.duskAccent)
                .task {
                    PlaybackEngineFactory.prewarmIfNeeded()
                    await offlinePlaybackSyncManager.syncPendingActions()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    Task {
                        await offlinePlaybackSyncManager.syncPendingActions()
                    }
                }
        }
    }
}

#if os(iOS)
private extension DuskApp {
    static func configurePlaybackAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            if #available(iOS 15.0, *) {
                try audioSession.setSupportsMultichannelContent(true)
            }
        } catch {
            assertionFailure("Failed to configure playback audio session: \(error.localizedDescription)")
        }
    }

    static func configureTabBarAppearance() {
        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.normal.iconColor = .duskTextSecondary
        itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.duskTextSecondary]
        itemAppearance.selected.iconColor = .duskAccent
        itemAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.duskAccent]

        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = .duskSurface
        appearance.shadowColor = UIColor.label.withAlphaComponent(0.05)
        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance

        let tabBarAppearance = UITabBar.appearance()
        tabBarAppearance.standardAppearance = appearance
        tabBarAppearance.scrollEdgeAppearance = appearance
        tabBarAppearance.unselectedItemTintColor = .duskTextSecondary
        tabBarAppearance.tintColor = .duskAccent
    }
}
#endif

extension Color {
    static let duskBackground = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(duskHex: 0x090A0F)
                : UIColor(duskHex: 0xF5F7FA)
        }
    )

    static let duskSurface = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(duskHex: 0x161824)
                : UIColor(duskHex: 0xFFFFFF)
        }
    )

    static let duskAccent = Color(uiColor: .duskAccent)

    static let duskTextPrimary = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(duskHex: 0xF2F2F7)
                : UIColor(duskHex: 0x1C1C1E)
        }
    )

    static let duskTextSecondary = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(duskHex: 0x8E95A8)
                : UIColor(duskHex: 0x636366)
        }
    )

}

private extension UIColor {
    static let duskSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(duskHex: 0x161824)
            : UIColor(duskHex: 0xFFFFFF)
    }

    static let duskAccent = UIColor(duskHex: 0xFF6B4A)

    static let duskTextSecondary = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(duskHex: 0x8E95A8)
            : UIColor(duskHex: 0x636366)
    }

    convenience init(duskHex: UInt32) {
        let red = CGFloat((duskHex >> 16) & 0xFF) / 255
        let green = CGFloat((duskHex >> 8) & 0xFF) / 255
        let blue = CGFloat(duskHex & 0xFF) / 255

        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
