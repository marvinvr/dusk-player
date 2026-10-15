#if DEBUG
import SwiftUI

/// DEBUG-only demo mode for the App Store screenshots (see
/// `docs/screenshots.md`).
///
/// Everything is driven by launch arguments, which land in UserDefaults'
/// argument domain (`-DuskScreenshotMode YES`, `-DuskScreenshotScreen detail`…)
/// and are never persisted. When the mode is on, the app signs in with a fake
/// account token and sends every plex.tv request to a local mock server, which
/// in turn advertises the account's demo Plex Media Servers. Nothing here exists in Release builds.
enum ScreenshotMode {
    private enum Key {
        static let mode = "DuskScreenshotMode"
        static let plexTV = "DuskScreenshotPlexTV"
        static let screen = "DuskScreenshotScreen"
        static let item = "DuskScreenshotItem"
        static let itemType = "DuskScreenshotItemType"
        static let search = "DuskScreenshotSearch"
        static let playOffset = "DuskScreenshotPlayOffset"
        static let keepHUD = "DuskScreenshotKeepHUD"
        static let downloads = "DuskScreenshotDownloads"
        static let seedDownloads = "DuskScreenshotSeedDownloads"
        static let seerr = "DuskScreenshotSeerr"
        static let upNext = "DuskScreenshotUpNext"
        static let playerSheet = "DuskScreenshotPlayerSheet"
        static let heroIndex = "DuskScreenshotHeroIndex"
    }

    private static var defaults: UserDefaults { .standard }

    static let isActive = UserDefaults.standard.bool(forKey: Key.mode)

    /// Fake account token. The mock server accepts any token.
    static let accountToken = "dusk-screenshot-demo-token"

    /// Replacement for `https://plex.tv`, e.g. `http://127.0.0.1:47400`.
    static var plexTVBase: String? {
        guard isActive else { return nil }
        return defaults.string(forKey: Key.plexTV)?.nilIfEmpty
    }

    static var searchQuery: String? {
        guard isActive, screen == .search else { return nil }
        return defaults.string(forKey: Key.search)?.nilIfEmpty
    }

    /// Keeps the player HUD on screen instead of auto-hiding it.
    static var keepsPlayerHUD: Bool {
        isActive && defaults.bool(forKey: Key.keepHUD)
    }

    /// Base URL of a demo Seerr (`-DuskScreenshotSeerr http://127.0.0.1:47404`).
    /// `SeerrService` then acts as signed in to it without touching the Keychain.
    static var seerrBaseURL: URL? {
        guard isActive else { return nil }
        return defaults.string(forKey: Key.seerr)?.nilIfEmpty.flatMap(URL.init(string:))
    }

    /// `-DuskScreenshotUpNext <seconds>`: a player shot of an episode raises the
    /// full-screen Up Next screen for the next one, and every Up Next countdown
    /// stops at that many seconds instead of starting the next episode.
    static var frozenUpNextSeconds: Int? {
        guard isActive, defaults.object(forKey: Key.upNext) != nil else { return nil }
        return max(defaults.integer(forKey: Key.upNext), 1)
    }

    /// `-DuskScreenshotHeroIndex <n>`: the iOS/iPadOS Home hero opens on that
    /// item instead of the first (rotation is off in screenshot mode).
    static var heroIndex: Int? {
        guard isActive, defaults.object(forKey: Key.heroIndex) != nil else { return nil }
        return max(defaults.integer(forKey: Key.heroIndex), 0)
    }

    enum Screen: String {
        case home, movies, shows, library, detail, search, player, downloads, settings, serverPriority, supporter, icons
    }

    static var screen: Screen? {
        guard isActive else { return nil }
        return defaults.string(forKey: Key.screen).flatMap(Screen.init(rawValue:))
    }

    struct Destination {
        var tab: MainTabItem = .home
        var routes: [AppNavigationRoute] = []
        var playID: PlexItemID?
        var playOffsetMilliseconds: Int?
        var sheet: Sheet?
    }

    enum Sheet: String, Identifiable {
        case supporter, icons
        var id: String { rawValue }
    }

    /// The sheet the screenshot run asked for, once the shell has routed.
    @MainActor static var pendingSheet: Sheet?

    @MainActor private static var hasRouted = false

    /// Resolves the requested screen once the demo server is connected and its
    /// libraries are known. Returns nil until then, and after it has routed once.
    @MainActor
    static func consumeDestination(
        plexService: PlexService,
        libraries: [PlexLibrary],
        downloadManager: DownloadManager
    ) async -> Destination? {
        guard isActive, !hasRouted, let screen,
              plexService.pool.primary != nil,
              !libraries.isEmpty else { return nil }

        // The demo servers hand out globally unique rating keys, so an item is
        // found by asking each connected server for it.
        var item: PlexItemID?
        if let ratingKey = defaults.string(forKey: Key.item)?.nilIfEmpty {
            guard let serverID = await server(holding: ratingKey, plexService: plexService) else { return nil }
            item = PlexItemID(serverID: serverID, ratingKey: ratingKey)
        }
        hasRouted = true

        await queueRequestedDownloads(plexService: plexService, downloadManager: downloadManager)
        await seedRequestedDownloads(plexService: plexService, downloadManager: downloadManager)

        let itemType = defaults.string(forKey: Key.itemType)
            .flatMap { PlexMediaType(rawValue: $0) } ?? .movie

        var destination = Destination()
        switch screen {
        case .home:
            break
        case .movies:
            destination.tab = .library(.movie)
        case .shows:
            destination.tab = .library(.show)
        case .library:
            let type = itemType == .show ? PlexLibraryType.show : .movie
            destination.tab = .library(type)
            if let library = libraries.first(where: { $0.libraryType == type }) {
                destination.routes = [.library(library)]
            }
        case .detail:
            if let item {
                destination.routes = [.media(type: itemType, id: item)]
            }
        case .search:
            #if os(tvOS)
            destination.tab = .search
            #else
            destination.routes = [.search]
            #endif
        case .player:
            destination.playID = item
            destination.playOffsetMilliseconds = defaults.object(forKey: Key.playOffset) == nil
                ? nil
                : Int(defaults.double(forKey: Key.playOffset) * 1000)
        case .downloads:
            destination.tab = .downloads
        case .settings:
            destination.tab = .settings
        case .serverPriority:
            destination.tab = .settings
            destination.routes = [.screenshotServerPriority]
        case .supporter:
            destination.tab = .settings
            destination.sheet = .supporter
        case .icons:
            destination.tab = .settings
            destination.sheet = .icons
        }
        return destination
    }

    @MainActor
    private static func server(holding ratingKey: String, plexService: PlexService) async -> String? {
        for connection in plexService.pool.connections {
            if (try? await plexService.getMediaDetails(ratingKey: ratingKey, serverID: connection.serverID)) != nil {
                return connection.serverID
            }
        }
        return nil
    }

    /// `-DuskScreenshotDownloads movie:1001,episode:2011` queues real
    /// downloads from the demo server.
    @MainActor
    private static func queueRequestedDownloads(plexService: PlexService, downloadManager: DownloadManager) async {
        for (type, id) in await downloadEntries(Key.downloads, plexService: plexService) {
            guard downloadManager.record(for: id) == nil else { continue }
            await downloadManager.queueDownload(id: id, type: type)
        }
    }

    /// `-DuskScreenshotSeedDownloads movie:1001,season:2010` records finished
    /// downloads (metadata and artwork from the demo server, a placeholder
    /// file), so the Downloads tab is full without waiting on URLSession.
    @MainActor
    private static func seedRequestedDownloads(plexService: PlexService, downloadManager: DownloadManager) async {
        for (type, id) in await downloadEntries(Key.seedDownloads, plexService: plexService) {
            await downloadManager.seedCompletedDownloadForScreenshot(id: id, type: type)
        }
    }

    @MainActor
    private static func downloadEntries(_ key: String, plexService: PlexService) async -> [(PlexMediaType, PlexItemID)] {
        guard let spec = defaults.string(forKey: key)?.nilIfEmpty else { return [] }
        var entries: [(PlexMediaType, PlexItemID)] = []
        for entry in spec.split(separator: ",") {
            let parts = entry.split(separator: ":").map(String.init)
            guard parts.count == 2, let type = PlexMediaType(rawValue: parts[0]),
                  let serverID = await server(holding: parts[1], plexService: plexService) else { continue }
            entries.append((type, PlexItemID(serverID: serverID, ratingKey: parts[1])))
        }
        return entries
    }
}

#if os(tvOS)
extension ScreenshotMode {
    @MainActor private static var hasReplayedTVInputs = false

    /// `-DuskScreenshotTVInputs "wait:4000,select,down,right"` feeds the tvOS
    /// player HUD synthetic Siri Remote input once, as if pressed. Tokens:
    /// up/down/left/right, select, menu, tap, playpause, wait:<ms>,
    /// panel:<info|audio|subtitles|quality|speed|chapters>, pan:<points> (a
    /// slow swipe of that many points, which leaves the HUD scrubbing).
    @MainActor
    static func replayTVRemoteInputs(into controller: PlayerTVHUDController) {
        guard isActive, !hasReplayedTVInputs,
              let script = defaults.string(forKey: "DuskScreenshotTVInputs")?.nilIfEmpty else { return }
        hasReplayedTVInputs = true
        Task { @MainActor in
            for token in script.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
                switch parts[0] {
                case "wait":
                    try? await Task.sleep(for: .milliseconds(Int(parts.count > 1 ? parts[1] : "500") ?? 500))
                    continue
                case "up", "down", "left", "right":
                    let arrow: PlayerTVArrow = switch parts[0] {
                    case "up": .up
                    case "down": .down
                    case "left": .left
                    default: .right
                    }
                    controller.handle(.arrowDown(arrow))
                    try? await Task.sleep(for: .milliseconds(60))
                    controller.handle(.arrowUp(arrow))
                case "select": controller.handle(.select)
                case "menu": controller.handle(.menu)
                case "tap": controller.handle(.touchTap)
                case "playpause": controller.handle(.playPause)
                case "panel":
                    controller.openPanel(parts.count > 1 ? PlayerTVPanelTab(rawValue: parts[1]) : nil)
                case "pan":
                    let distance = CGFloat(Double(parts.count > 1 ? parts[1] : "200") ?? 200)
                    controller.handle(.panBegan)
                    for step in 1...10 {
                        try? await Task.sleep(for: .milliseconds(30))
                        controller.handle(.panChanged(translationX: distance * CGFloat(step) / 10, velocityX: 0))
                    }
                    controller.handle(.panEnded)
                default:
                    continue
                }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }
}
#endif

#if os(iOS)
extension ScreenshotMode {
    /// Search shots show the field as a user leaves it after typing: active,
    /// query in place, keyboard dismissed (results visible).
    @MainActor
    static func presentSearchField(_ isPresented: Binding<Bool>) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            isPresented.wrappedValue = true
            try? await Task.sleep(for: .milliseconds(1200))
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
        }
    }
}
#else
extension ScreenshotMode {
    @MainActor
    static func presentSearchField(_ isPresented: Binding<Bool>) {}
}
#endif

#if os(iOS)
extension ScreenshotMode {
    @MainActor private static var hasOpenedPlayerSheet = false

    /// `-DuskScreenshotPlayerSheet audio|subtitles` opens that player picker
    /// once the tracks are in, and leaves it open (nothing is selected).
    @MainActor
    static func openRequestedPlayerSheet(in viewModel: PlayerViewModel) {
        guard isActive, !hasOpenedPlayerSheet,
              let sheet = defaults.string(forKey: Key.playerSheet)?.nilIfEmpty else { return }
        let isSubtitles = sheet == "subtitles"
        guard isSubtitles ? !viewModel.subtitleTracks.isEmpty : viewModel.audioTracks.count > 1 else { return }
        hasOpenedPlayerSheet = true
        Task { @MainActor in
            // Lets the Plex metadata merge and automatic selection settle.
            try? await Task.sleep(for: .seconds(2))
            if isSubtitles {
                viewModel.showSubtitlePicker = true
            } else {
                viewModel.showAudioPicker = true
            }
        }
    }
}
#endif

/// Presents the Supporter page or the App Icon picker for a screenshot run.
struct ScreenshotSheetPresenter: ViewModifier {
    @State private var sheet: ScreenshotMode.Sheet?

    func body(content: Content) -> some View {
        content
            .task {
                guard ScreenshotMode.isActive else { return }
                for _ in 0..<240 {
                    if let pending = ScreenshotMode.pendingSheet {
                        // Let the tab switch settle before the sheet slides up.
                        try? await Task.sleep(for: .milliseconds(600))
                        sheet = pending
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .supporter:
                    #if os(tvOS)
                    // tvOS would scroll down to the first focusable purchase
                    // row; the capture wants the top of the page.
                    SupporterView(context: .settings)
                        .scrollDisabled(true)
                    #else
                    SupporterView(context: .settings)
                    #endif
                case .icons:
                    #if os(iOS)
                    AppIconPickerView()
                    #else
                    SupporterView(context: .settings)
                    #endif
                }
            }
    }
}
#endif
