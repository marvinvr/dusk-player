import SwiftUI
import UIKit
#if os(iOS)
import AVFoundation
#endif

enum AppImageCache {
    static let memoryCapacity = 0
    static let diskCapacity = 200_000_000
    static let maxAge: TimeInterval = 3 * 24 * 60 * 60

    private static let cachedAtUserInfoKey = "DuskCachedAt"

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

    static func cachedResponse(for request: URLRequest, now: Date = .now) -> CachedURLResponse? {
        guard let response = shared.cachedResponse(for: request) else { return nil }

        guard isFresh(response, now: now) else {
            shared.removeCachedResponse(for: request)
            return nil
        }

        return response
    }

    static func storeCachedResponse(_ response: CachedURLResponse, for request: URLRequest, now: Date = .now) {
        var userInfo = response.userInfo ?? [:]
        userInfo[cachedAtUserInfoKey] = now

        let timestampedResponse = CachedURLResponse(
            response: response.response,
            data: response.data,
            userInfo: userInfo,
            storagePolicy: response.storagePolicy
        )
        shared.storeCachedResponse(timestampedResponse, for: request)
    }

    static func cachedAt(for response: CachedURLResponse) -> Date? {
        response.userInfo?[cachedAtUserInfoKey] as? Date
    }

    private static func isFresh(_ response: CachedURLResponse, now: Date) -> Bool {
        guard let cachedAt = cachedAt(for: response) else {
            return false
        }

        return now.timeIntervalSince(cachedAt) <= maxAge
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
    #if os(tvOS)
    @State private var topShelfCoordinator: TopShelfCoordinator
    #endif

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
        #if os(tvOS)
        _topShelfCoordinator = State(initialValue: TopShelfCoordinator(plexService: service))
        #endif
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
                #if os(tvOS)
                .environment(topShelfCoordinator)
                #endif
                .preferredColorScheme(userPreferences.appearanceMode.preferredColorScheme)
                .tint(Color.duskAccent)
                .task {
                    PlaybackEngineFactory.prewarmIfNeeded()
                    offlinePlaybackSyncManager.startAutomaticSync()
                    await offlinePlaybackSyncManager.syncPendingActions(force: true)
                    #if os(tvOS)
                    TopShelfCoordinator.scheduleAppRefresh()
                    await topShelfCoordinator.refresh()
                    #endif
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        offlinePlaybackSyncManager.startAutomaticSync()
                        Task {
                            await offlinePlaybackSyncManager.syncPendingActions(force: true)
                        }
                        #if os(tvOS)
                        Task { await topShelfCoordinator.refresh() }
                        #endif
                    } else {
                        offlinePlaybackSyncManager.stopAutomaticSync()
                        #if os(tvOS)
                        if newPhase == .background {
                            TopShelfCoordinator.scheduleAppRefresh()
                        }
                        #endif
                    }
                }
                .onChange(of: userPreferences.downloadsWifiOnly) {
                    downloadManager.evaluateNetworkConstraints()
                }
        }
        #if os(tvOS)
        .backgroundTask(.appRefresh(TopShelfCoordinator.backgroundRefreshIdentifier)) {
            await TopShelfCoordinator.performBackgroundRefresh()
        }
        #endif
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
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = .duskSurface
        appearance.shadowColor = UIColor.label.withAlphaComponent(0.05)

        let tabBarAppearance = UITabBar.appearance()
        tabBarAppearance.standardAppearance = appearance
        tabBarAppearance.scrollEdgeAppearance = appearance
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

    /// Label/icon color for prominent primary action buttons whose fill is
    /// `Color.primary` (a dark glass capsule in Light mode, light in Dark mode).
    /// Resolves to the inverse of `primary` so the title stays legible on the
    /// contrasting fill: white in Light mode, black in Dark mode.
    static let duskPrimaryActionLabel = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(duskHex: 0x090A0F)
                : UIColor(duskHex: 0xFFFFFF)
        }
    )

    /// Tint for the prominent primary action glass. A *translucent* `primary` so
    /// the button keeps a dark/light lean for contrast while the glass material
    /// still reads through it — more "liquid glass" than a solid black/white fill.
    /// Lower the opacity for more glass, raise it for more contrast.
    static var duskPrimaryButtonTint: Color {
        Color.primary.opacity(0.7)
    }

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
