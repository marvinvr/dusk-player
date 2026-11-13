import AppIntents
import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
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

    /// Plain iPhone stays in portrait unless the player cover is up. iPad and
    /// the Duo layout match Info-iOS.plist. See `AppOrientationPolicy`.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationPolicy.mask(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            isDuo: DuskDuoDisplay.isActive,
            playerMask: PlayerOrientationApplicationMask.player
        )
    }
}
#endif

/// Designed-for-iPad on a Mac: draw iPad points 1:1 instead of macOS's default 77%.
///
/// macOS shrinks every iPad app to 0.77 (a 1440×900 window is laid out as ~1871×1128
/// iPad points), so Dusk's iPad type ramp and poster metrics land ~25% smaller than a
/// native media app (13pt body, ~9pt card captions, ~100pt posters) and the 2x render is
/// resampled, which softens text. At 1.0 the iPad layout matches the TV app's sizes and
/// renders pixel-exact. The value goes in the *registration* domain: nothing is
/// persisted, and a user's own `defaults write com.dusk-player.app iOSMacScaleFactor`
/// still wins. UIKit reads it at launch, so it must be set before `UIApplicationMain`.
#if os(iOS)
enum MacDisplayScale {
    static func register() {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return }
        UserDefaults.standard.register(defaults: ["iOSMacScaleFactor": 1.0])
    }
}
#endif

/// Entry point: only exists so `MacDisplayScale` runs before UIKit starts.
@main
enum DuskMain {
    static func main() {
        #if os(iOS)
        MacDisplayScale.register()
        #endif
        DuskApp.main()
    }
}

struct DuskApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(DuskAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    @State private var plexService: PlexService
    @State private var seerrService: SeerrService
    @State private var traktService: TraktService
    @State private var iptvService: IPTVService
    @State private var playbackCoordinator: PlaybackCoordinator
    @State private var downloadManager: DownloadManager
    @State private var offlinePlaybackSyncManager: OfflinePlaybackSyncManager
    @State private var userPreferences: UserPreferences
    @State private var analytics: AnalyticsClient
    @State private var supporterStore: SupporterStore
    #if os(tvOS)
    @State private var topShelfLinks = TopShelfLinkRouter()
    #endif
    #if os(macOS)
    /// Owned by the app on the Mac (by `ContentView` on iOS/tvOS) so the
    /// Settings window and the menu bar's Refresh reach the same pass.
    @State private var macConnections = ServerConnectionCoordinator()
    @State private var macRouter = MacShellRouter()
    #endif

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
        let coordinator = PlaybackCoordinator(
            plexService: service,
            preferences: prefs,
            downloadManager: downloads,
            offlinePlaybackSyncManager: playbackSync
        )
        ErrorReporter.client = analyticsClient
        ErrorReporter.playbackProfile = { [weak coordinator] in coordinator?.errorReportingProfile }
        let trakt = TraktService(plexService: service)
        coordinator.traktService = trakt
        _traktService = State(initialValue: trakt)
        _iptvService = State(initialValue: IPTVService(plexService: service))
        _playbackCoordinator = State(initialValue: coordinator)
        // Siri's intents run in this process and reach the app through it.
        let siri = SiriPlaybackService(plexService: service, playback: coordinator)
        AppDependencyManager.shared.add(dependency: siri)
        _userPreferences = State(initialValue: prefs)
        #if !os(macOS)
        Self.configurePlaybackAudioSession()
        #endif
        #if os(iOS)
        Self.configureTabBarAppearance()
        #elseif os(tvOS)
        Self.configureTabBarTint()
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        // One main window: the player, the connection pass and the sidebar
        // router are app-wide, so a second window would only fight over them.
        Window("Dusk", id: MacWindow.mainID) {
            appContent
                .frame(minWidth: MacWindow.minimumSize.width, minHeight: MacWindow.minimumSize.height)
        }
        .defaultSize(MacWindow.defaultSize)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            MacCommands(
                router: macRouter,
                connections: macConnections,
                plexService: plexService,
                playback: playbackCoordinator
            )
            MacPlayerCommands()
        }

        Settings {
            sharedEnvironment(MacSettingsWindow())
        }
        #else
        WindowGroup {
            appContent
        }
        #endif
    }

    /// The services every window's content reads from the environment. The
    /// Mac's Settings scene gets the same set as the main window.
    private func sharedEnvironment<Content: View>(_ content: Content) -> some View {
        content
            .environment(plexService)
            .environment(seerrService)
            .environment(traktService)
            .environment(iptvService)
            .environment(playbackCoordinator)
            .environment(downloadManager)
            .environment(offlinePlaybackSyncManager)
            .environment(userPreferences)
            .environment(\.blursUnwatchedEpisodes, userPreferences.blursUnwatchedEpisodes)
            .environment(supporterStore)
            .environment(analytics)
            #if os(macOS)
            .environment(macConnections)
            .environment(macRouter)
            #endif
            .preferredColorScheme(userPreferences.appearanceMode.preferredColorScheme)
    }

    private var appContent: some View {
        sharedEnvironment(ContentView())
            #if os(tvOS)
            .environment(topShelfLinks)
            .onOpenURL { url in
                topShelfLinks.open(url)
            }
            #else
            .onOpenURL { _ in
                // Trakt callbacks belong exclusively to the live
                // ASWebAuthenticationSession completion. Ignore unclaimed
                // links (including a cold launch); never exchange a code
                // without that session's in-memory state and PKCE verifier.
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { _ in
                // Universal Links can also arrive as a browsing activity.
                // Apply the same rule as onOpenURL, without logging the URL.
            }
            #endif
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
                    downloadManager.resumePendingWork()
                    analytics.recordAppOpenedIfNeeded()
                    Task { await traktService.flushPending() }
                    Task { await supporterStore.sceneDidBecomeActive() }
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

    #if !os(macOS)
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
    #endif
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
    /// Without it the bar inherits the window tint (the global accent color).
    /// The tab shell pins the same color on the live bar; this covers the bar
    /// before the shell's first update. See `MainTabTVShell`.
    static func configureTabBarTint() {
        UITabBar.appearance().tintColor = .duskTVTabBarTint
    }
}
#endif

#if os(macOS)
// The same tokens as the UIKit block below, resolved per drawing appearance.
// See STYLE.md for the palette.
extension Color {
    static let duskBackground = Color(
        nsColor: .duskDynamic(light: NSColor(duskHex: 0xF5F7FA), dark: NSColor(duskHex: 0x090A0F))
    )

    static let duskSurface = Color(
        nsColor: .duskDynamic(light: NSColor(duskHex: 0xFFFFFF), dark: NSColor(duskHex: 0x161824))
    )

    /// Sunset Coral, the brand color. Reserved for brand moments (the Supporter
    /// page and the app icon picker); never a UI tint, state or progress color.
    /// See STYLE.md.
    static let duskAccent = Color(nsColor: NSColor(duskHex: 0xFF6B4A))

    static let duskTextPrimary = Color(
        nsColor: .duskDynamic(light: NSColor(duskHex: 0x1C1C1E), dark: NSColor(duskHex: 0xF2F2F7))
    )

    static let duskTextSecondary = Color(
        nsColor: .duskDynamic(light: NSColor(duskHex: 0x636366), dark: NSColor(duskHex: 0x8E95A8))
    )

    /// See the UIKit twin below: the inverse of `primary`.
    static let duskPrimaryActionLabel = Color(
        nsColor: .duskDynamic(light: NSColor(duskHex: 0xFFFFFF), dark: NSColor(duskHex: 0x090A0F))
    )

    /// Only the tvOS tab shell uses it; kept so shared code resolves the name.
    static let duskTVTabBarTint = Color(
        nsColor: .duskDynamic(light: NSColor(duskHex: 0x000000), dark: NSColor(duskHex: 0xF2F2F7))
    )

    /// See the UIKit twin below.
    static var duskPrimaryButtonTint: Color {
        Color.primary.opacity(0.7)
    }
}

private extension NSColor {
    convenience init(duskHex: UInt32) {
        let red = CGFloat((duskHex >> 16) & 0xFF) / 255
        let green = CGFloat((duskHex >> 8) & 0xFF) / 255
        let blue = CGFloat(duskHex & 0xFF) / 255

        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
#else
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

    /// Sunset Coral, the brand color. Reserved for brand moments (the Supporter
    /// page and the app icon picker); never a UI tint, state or progress color.
    /// See STYLE.md.
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
#endif
