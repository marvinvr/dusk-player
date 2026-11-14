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
        static let library = "DuskScreenshotLibrary"
        static let search = "DuskScreenshotSearch"
        static let playOffset = "DuskScreenshotPlayOffset"
        static let keepHUD = "DuskScreenshotKeepHUD"
        static let downloads = "DuskScreenshotDownloads"
        static let seedDownloads = "DuskScreenshotSeedDownloads"
        static let seerr = "DuskScreenshotSeerr"
        static let seerrSeason = "DuskScreenshotSeerrSeason"
        static let upNext = "DuskScreenshotUpNext"
        static let playerSheet = "DuskScreenshotPlayerSheet"
        static let heroIndex = "DuskScreenshotHeroIndex"
        static let photoAlbum = "DuskScreenshotPhotoAlbum"
        static let photoViewer = "DuskScreenshotPhotoViewer"
        static let photoSlideshow = "DuskScreenshotPhotoSlideshow"
        static let trakt = "DuskScreenshotTrakt"
        static let traktSignIn = "DuskScreenshotTraktSignIn"
        static let mute = "DuskScreenshotMute"
        static let iptvPlaylist = "DuskScreenshotIPTVPlaylist"
        static let iptvGuide = "DuskScreenshotIPTVGuide"
        static let iptvName = "DuskScreenshotIPTVName"
        static let iptvHeaderValue = "DuskScreenshotIPTVHeaderValue"
        static let iptvChannel = "DuskScreenshotIPTVChannel"
        static let iptvCatchUpHoursAgo = "DuskScreenshotIPTVCatchUpHoursAgo"
        static let guideMoves = "DuskScreenshotGuideMoves"
        static let guideOffset = "DuskScreenshotGuideOffsetMinutes"
    }

    private static var defaults: UserDefaults { .standard }

    static let isActive = UserDefaults.standard.bool(forKey: Key.mode)

    /// `-DuskScreenshotSignedOut YES` (without screenshot mode): start on the
    /// sign-in screen without reading a stored sign-in, for UI captures.
    static let startsSignedOut = UserDefaults.standard.bool(forKey: "DuskScreenshotSignedOut")

    /// Fake account token. The mock server accepts any token.
    static let accountToken = "dusk-screenshot-demo-token"

    /// Replacement for `https://plex.tv`, e.g. `http://127.0.0.1:47400`.
    static var plexTVBase: String? {
        guard isActive else { return nil }
        return defaults.string(forKey: Key.plexTV)?.nilIfEmpty
    }

    /// Replacement for `https://discover.provider.plex.tv` (the Watchlist):
    /// the mock's `/discover` prefix.
    static var discoverBase: String? {
        plexTVBase.map { "\($0)/discover" }
    }

    static var searchQuery: String? {
        guard isActive, screen == .search else { return nil }
        return defaults.string(forKey: Key.search)?.nilIfEmpty
    }

    /// `-DuskScreenshotMute 1`: AVPlayer plays muted, so simulator playback
    /// runs never make a sound on the host Mac (string check: launch-arg
    /// bools are unreliable).
    static var mutesPlayback: Bool {
        guard isActive, let value = defaults.string(forKey: Key.mute) else { return false }
        return ["1", "yes", "true"].contains(value.lowercased())
    }

    /// `-DuskScreenshotIPTVPlaylist <m3u url>` (plus optional `…IPTVGuide`,
    /// `…IPTVName`, `…IPTVHeaderValue`) seeds one IPTV source when the
    /// profile has none, so a run starts with channels in Live TV.
    static var seededIPTVSource: (source: IPTVSource, headerValue: String?)? {
        guard isActive,
              let playlist = defaults.string(forKey: Key.iptvPlaylist).flatMap(M3UParser.httpURL) else { return nil }
        let headerValue = defaults.string(forKey: Key.iptvHeaderValue)?.nilIfEmpty
        let source = IPTVSource(
            name: defaults.string(forKey: Key.iptvName)?.nilIfEmpty ?? "IPTV",
            playlistURL: playlist,
            guideURL: defaults.string(forKey: Key.iptvGuide).flatMap(M3UParser.httpURL),
            headerName: headerValue == nil ? nil : IPTVSource.defaultHeaderName
        )
        return (source, headerValue)
    }

    /// `-DuskScreenshotIPTVChannel <n>`: with `-DuskScreenshotScreen
    /// iptvPlayer`, plays the n-th channel of the first IPTV source.
    static var iptvChannelIndex: Int {
        defaults.integer(forKey: Key.iptvChannel)
    }

    /// `-DuskScreenshotIPTVCatchUpHoursAgo <h>`: with `iptvPlayer`, plays
    /// back (catch-up) the programme that was on `h` hours ago instead of
    /// the channel live.
    static var iptvCatchUpHoursAgo: Int? {
        guard isActive, defaults.object(forKey: Key.iptvCatchUpHoursAgo) != nil else { return nil }
        return defaults.integer(forKey: Key.iptvCatchUpHoursAgo)
    }

    /// `-DuskScreenshotGuideMoves "down,down,right"`: remote presses the tvOS
    /// grid guide replays once it has loaded (focus starts on the first row).
    static var guideMoves: [String]? {
        guard isActive, let value = defaults.string(forKey: Key.guideMoves)?.nilIfEmpty else { return nil }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// `-DuskScreenshotGuideOffsetMinutes 120`: the iOS grid guide opens
    /// scrolled that far forward in time.
    static var guideOffsetMinutes: Int? {
        guard isActive, defaults.object(forKey: Key.guideOffset) != nil else { return nil }
        return defaults.integer(forKey: Key.guideOffset)
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

    /// Replacement for `https://api.trakt.tv` (`-DuskScreenshotTrakt
    /// http://127.0.0.1:47420`), a mock answering the device flow.
    static var traktAPIBase: URL? {
        guard isActive else { return nil }
        return defaults.string(forKey: Key.trakt)?.nilIfEmpty.flatMap(URL.init(string:))
    }

    /// `-DuskScreenshotTraktSignIn 1`: Settings › Trakt starts the device-code
    /// sign-in as soon as it opens (string check: launch-arg bools are unreliable).
    static var startsTraktSignIn: Bool {
        guard isActive, let value = defaults.string(forKey: Key.traktSignIn) else { return false }
        return ["1", "yes", "true"].contains(value.lowercased())
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
        case home, movies, shows, photos, library, collections, detail, search, player, downloads, settings, serverPriority, hiddenLibraries, supporter, icons
        /// Settings › Server Priority › Connection Diagnostics.
        case connectionDiagnostics
        /// Settings › Trakt.
        case trakt
        /// Settings › Live TV › IPTV Sources; the Live TV tab; an IPTV
        /// channel playing (`-DuskScreenshotIPTVChannel`).
        case iptvSources, liveTV, iptvPlayer
        /// The n-th channel (`-DuskScreenshotIPTVChannel`) of the server's
        /// Plex Live TV lineup, tuned and playing.
        case plexLivePlayer
        /// The Playlists tab; `playlist` opens `-DuskScreenshotItem <playlist
        /// ratingKey>`; `playlistPlay` plays it from item
        /// `-DuskScreenshotPlaylistStart <n>`; `addToPlaylist` opens the
        /// item's detail page with the Add to Playlist sheet over it.
        case playlists, playlist, playlistPlay, addToPlaylist
        /// `-DuskScreenshotSeerrSeason <tmdbID>:<season>`: that Seerr season
        /// page, pushed over the Plex show `-DuskScreenshotItem` when given.
        case seerrSeason
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
        var addToPlaylist: AddToPlaylistTarget?
        /// Play this playlist from `playlistStart`.
        var playlistID: PlexItemID?
        var playlistStart = 0
        /// Play this channel of the first IPTV source.
        var iptvChannelIndex: Int?
        /// Tune this channel of the Plex Live TV lineup.
        var plexLiveChannelIndex: Int?
    }

    enum Sheet: String, Identifiable {
        case supporter, icons
        var id: String { rawValue }
    }

    /// The sheet the screenshot run asked for, once the shell has routed.
    @MainActor static var pendingSheet: Sheet?

    @MainActor private static var hasRouted = false
    @MainActor private static var hasOpenedPhotoViewer = false

    /// `-DuskScreenshotPhotoViewer <n>`: the photo grid opens the viewer on
    /// its n-th photo or clip. Handed out once.
    /// `-DuskScreenshotPhotoSlideshow YES`: that viewer starts as a slideshow.
    static var startsPhotoSlideshow: Bool {
        isActive && defaults.bool(forKey: Key.photoSlideshow)
    }

    @MainActor
    /// With `-DuskScreenshotPhotoAlbum` only that album's grid opens it, not
    /// the library root underneath.
    static func consumePhotoViewerIndex(inAlbum: Bool) -> Int? {
        guard isActive, !hasOpenedPhotoViewer, defaults.object(forKey: Key.photoViewer) != nil,
              inAlbum == (defaults.string(forKey: Key.photoAlbum)?.nilIfEmpty != nil) else { return nil }
        hasOpenedPhotoViewer = true
        return max(defaults.integer(forKey: Key.photoViewer), 0)
    }

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

        // Photo sections only join the list once counted non-empty.
        if screen == .photos, !libraries.contains(where: { $0.libraryType == .photo }) { return nil }

        // The demo servers hand out globally unique rating keys, so an item is
        // found by asking each connected server for it.
        var item: PlexItemID?
        if [.playlist, .playlistPlay].contains(screen),
           let ratingKey = defaults.string(forKey: Key.item)?.nilIfEmpty,
           let primary = plexService.pool.primary?.serverID {
            // A playlist is not library metadata; the demo has one server.
            item = PlexItemID(serverID: primary, ratingKey: ratingKey)
        } else if let ratingKey = defaults.string(forKey: Key.item)?.nilIfEmpty {
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
        case .photos:
            // `-DuskScreenshotPhotoAlbum <ratingKey>:<title>` opens that album
            // of the first photo library.
            destination.tab = .library(.photo)
            if let value = defaults.string(forKey: Key.photoAlbum)?.nilIfEmpty,
               let library = libraries.first(where: { $0.libraryType == .photo }) {
                let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
                destination.routes = [.photoAlbum(PhotoAlbumRoute(
                    library: library,
                    ratingKey: parts[0],
                    title: parts.count > 1 ? parts[1] : "Album"
                ))]
            }
        case .library:
            let type = itemType == .show ? PlexLibraryType.show : .movie
            destination.tab = .library(type)
            // `-DuskScreenshotLibrary <title>` picks one by name.
            let title = defaults.string(forKey: Key.library)?.nilIfEmpty
            if let library = libraries.first(where: { $0.libraryType == type && (title.map($0.title.localizedCaseInsensitiveContains) ?? true) }) {
                destination.routes = [.library(library)]
            }
        case .collections:
            // `-DuskScreenshotItemType show` for the TV library's.
            let type = itemType == .show ? PlexLibraryType.show : .movie
            destination.tab = .library(type)
            if let library = libraries.first(where: { $0.libraryType == type }) {
                destination.routes = [.libraryCollections(library)]
            }
        case .seerrSeason:
            if let item {
                destination.routes = [.media(type: .show, id: item)]
            }
            let parts = (defaults.string(forKey: Key.seerrSeason) ?? "").split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 {
                destination.routes.append(.seerrSeason(tvID: parts[0], seasonNumber: parts[1]))
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
        case .connectionDiagnostics:
            destination.tab = .settings
            destination.routes = [.screenshotServerPriority, .screenshotConnectionDiagnostics]
        case .hiddenLibraries:
            destination.tab = .settings
            destination.routes = [.screenshotHiddenLibraries]
        case .trakt:
            destination.tab = .settings
            destination.routes = [.screenshotTrakt]
        case .iptvSources:
            destination.tab = .settings
            destination.routes = [.screenshotIPTVSources]
        case .liveTV:
            destination.tab = .liveTV
        case .iptvPlayer:
            destination.tab = .liveTV
            destination.iptvChannelIndex = iptvChannelIndex
        case .plexLivePlayer:
            destination.tab = .liveTV
            destination.plexLiveChannelIndex = iptvChannelIndex
        case .supporter:
            destination.tab = .settings
            destination.sheet = .supporter
        case .icons:
            destination.tab = .settings
            destination.sheet = .icons
        case .playlists:
            destination.tab = .playlists
        case .playlist:
            destination.tab = .playlists
            if let item {
                destination.routes = [.playlist(id: item)]
            }
        case .playlistPlay:
            destination.tab = .playlists
            if let item {
                destination.routes = [.playlist(id: item)]
                destination.playlistID = item
                destination.playlistStart = defaults.integer(forKey: "DuskScreenshotPlaylistStart")
            }
        case .addToPlaylist:
            if let item {
                destination.routes = [.media(type: itemType, id: item)]
                let details = try? await plexService.getMediaDetails(ratingKey: item.ratingKey, serverID: item.serverID)
                destination.addToPlaylist = details.flatMap(AddToPlaylistTarget.init(details:))
                    ?? AddToPlaylistTarget(id: item, type: itemType, title: "Item")
            }
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
    /// slow swipe of that many points, which leaves the HUD scrubbing, or
    /// moves the selection when it is on the action row).
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
            .duskPopUp(item: $sheet) { sheet in
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
