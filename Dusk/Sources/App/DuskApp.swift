import SwiftUI
import UIKit

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

@main
struct DuskApp: App {
    @State private var plexService: PlexService
    @State private var playbackCoordinator: PlaybackCoordinator
    @State private var userPreferences = UserPreferences()

    init() {
        AppImageCache.configureSharedCache()
        let service = PlexService()
        let prefs = UserPreferences()
        _plexService = State(initialValue: service)
        _playbackCoordinator = State(initialValue: PlaybackCoordinator(plexService: service, preferences: prefs))
        _userPreferences = State(initialValue: prefs)
        #if os(iOS)
        Self.configureTabBarAppearance()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(plexService)
                .environment(playbackCoordinator)
                .environment(userPreferences)
                .preferredColorScheme(userPreferences.appearanceMode.preferredColorScheme)
                .tint(Color.duskAccent)
                .task {
                    await PlaybackEngineFactory.prewarmIfNeeded()
                }
        }
    }
}

#if os(iOS)
private extension DuskApp {
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
