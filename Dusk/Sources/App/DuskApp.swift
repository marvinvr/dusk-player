import AVFoundation
import SwiftUI
import UIKit

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
    @State private var seerrService: SeerrService
    @State private var playbackCoordinator: PlaybackCoordinator
    @State private var downloadManager: DownloadManager
    @State private var offlinePlaybackSyncManager: OfflinePlaybackSyncManager
    @State private var userPreferences: UserPreferences
    @State private var analytics: AnalyticsClient
    @State private var supporterStore: SupporterStore

    init() {
        AppImageCache.configureSharedCache()
        let service = PlexService()
        let seerr = SeerrService(plexService: service)
        let prefs = UserPreferences()
        let analyticsClient = AnalyticsClient(preferences: prefs)
        let downloads = DownloadManager(plexService: service, preferences: prefs)
        let playbackSync = OfflinePlaybackSyncManager(plexService: service)
        _plexService = State(initialValue: service)
        _seerrService = State(initialValue: seerr)
        _downloadManager = State(initialValue: downloads)
        _offlinePlaybackSyncManager = State(initialValue: playbackSync)
        _analytics = State(initialValue: analyticsClient)
        _supporterStore = State(initialValue: SupporterStore(analytics: analyticsClient))
        _playbackCoordinator = State(initialValue: PlaybackCoordinator(
            plexService: service,
            preferences: prefs,
            downloadManager: downloads,
            offlinePlaybackSyncManager: playbackSync
        ))
        _userPreferences = State(initialValue: prefs)
        Self.configurePlaybackAudioSession()
        #if os(iOS)
        Self.configureTabBarAppearance()
        #elseif os(tvOS)
        Self.configureTabBarTint()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(plexService)
                .environment(seerrService)
                .environment(playbackCoordinator)
                .environment(downloadManager)
                .environment(offlinePlaybackSyncManager)
                .environment(userPreferences)
                .environment(supporterStore)
                .environment(analytics)
                .preferredColorScheme(userPreferences.appearanceMode.preferredColorScheme)
                .tint(Color.duskAccent)
                .task {
                    analytics.recordAppOpenedIfNeeded()
                }
                .task {
                    await supporterStore.start()
                }
                .task {
                    PlaybackEngineFactory.prewarmIfNeeded()
                }
                .task(
                    id: seerrContextID
                ) {
                    await seerrService.contextDidChange()
                }
                .task(
                    id: offlineContextID
                ) {
                    guard plexService.homeBootstrapCompleted else {
                        offlinePlaybackSyncManager.stopAutomaticSync()
                        return
                    }

                    downloadManager.activateProfile()
                    offlinePlaybackSyncManager.activateProfile()

                    guard plexService.isSessionReady else {
                        offlinePlaybackSyncManager.stopAutomaticSync()
                        return
                    }

                    offlinePlaybackSyncManager.startAutomaticSync()
                    await offlinePlaybackSyncManager.syncPendingActions(force: true)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        analytics.recordAppOpenedIfNeeded()
                    }

                    if newPhase == .active,
                       plexService.isSessionReady {
                        offlinePlaybackSyncManager.startAutomaticSync()
                        Task {
                            await offlinePlaybackSyncManager.syncPendingActions(force: true)
                        }
                    } else {
                        offlinePlaybackSyncManager.stopAutomaticSync()
                    }
                }
                .onChange(of: userPreferences.downloadsWifiOnly) {
                    downloadManager.evaluateNetworkConstraints()
                }
                .onChange(of: userPreferences.analyticsEnabled) {
                    analytics.reportingPreferenceDidChange()
                }
        }
    }
}

private extension DuskApp {
    /// Seerr is bound to the account's first enabled server (see
    /// `SeerrService`), not to whichever server happens to be connected, so its
    /// context only changes when that binding or the profile does.
    var seerrContextID: String {
        [
            plexService.activeProfileID ?? "none",
            plexService.seerrBindingServerID ?? "none",
            String(plexService.isAuthenticated),
        ].joined(separator: ":")
    }

    /// Offline sync spans the whole pool: a second server coming up has to
    /// re-arm it, so the connected count is part of the identity.
    var offlineContextID: String {
        [
            String(plexService.homeBootstrapCompleted),
            plexService.activeProfileID ?? "none",
            plexService.pool.primary?.serverID ?? "none",
            String(plexService.pool.connections.count),
        ].joined(separator: ":")
    }

    static func configurePlaybackAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            // `.longFormVideo` routing policy is iOS-only; tvOS keeps the plain
            // playback category (HDMI route, no AirPlay long-form handoff).
            #if os(tvOS)
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            #else
            try audioSession.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            #endif
            try audioSession.setSupportsMultichannelContent(true)
        } catch {
            assertionFailure("Failed to configure playback audio session: \(error.localizedDescription)")
        }
    }
}

#if os(iOS)
private extension DuskApp {
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

#if os(tvOS)
private extension DuskApp {
    /// Gives every tvOS tab bar an explicit tint at creation.
    ///
    /// Without it the bar inherits the window tint, which is the global accent
    /// color (Sunset Coral), and the selected tab item is drawn coral. The tab
    /// shell pins the same color on the live bar; this covers the bar before the
    /// shell's first update. See `MainTabTVShell`.
    static func configureTabBarTint() {
        UITabBar.appearance().tintColor = .duskTVTabBarTint
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

    /// Content tint for the tvOS tab shell.
    ///
    /// tvOS draws the selected, unfocused tab item's icon and title in the bar's
    /// tint, so the tint has to be the label color: `TextPrimary` in Dark mode,
    /// black in Light mode. This is also tvOS's own default tint, and the focused
    /// item keeps its system contrast against the focus plate regardless of the
    /// tint. Backed by a dynamic `UIColor` so the same color can be pinned on the
    /// real `UITabBar` and resolves against the bar's own traits.
    static let duskTVTabBarTint = Color(uiColor: .duskTVTabBarTint)

    /// Tint for the prominent primary action glass. A *translucent* `primary` so
    /// the button keeps a dark/light lean for contrast while the glass material
    /// still reads through it — more "liquid glass" than a solid black/white fill.
    /// Lower the opacity for more glass, raise it for more contrast.
    static var duskPrimaryButtonTint: Color {
        Color.primary.opacity(0.7)
    }

}

extension UIColor {
    /// UIKit twin of `Color.duskTVTabBarTint`, pinned on the tvOS tab bar.
    static let duskTVTabBarTint = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(duskHex: 0xF2F2F7)
            : UIColor(duskHex: 0x000000)
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
