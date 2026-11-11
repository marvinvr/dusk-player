import SwiftUI

/// The main tab shell shown after authentication and server connection.
struct MainTabView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(UserPreferences.self) private var preferences
    @Environment(IPTVService.self) private var iptvService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTabItem = .home
    #if os(iOS)
    @State private var playerCoverIsUp = false
    @State private var playerCoverCloseTask: Task<Void, Never>?
    #endif
    @State private var homePath = NavigationPath()
    @State private var moviesPath = NavigationPath()
    @State private var showsPath = NavigationPath()
    @State private var videosPath = NavigationPath()
    @State private var photosPath = NavigationPath()
    @State private var liveTVPath = NavigationPath()
    @State private var playlistsPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var morePath = NavigationPath()
    @State private var librariesViewModel: LibrariesViewModel?
    @State private var liveTVViewModel: LiveTVViewModel?
    @State private var addToPlaylist = AddToPlaylistPresenter()
    #if os(tvOS)
    @Environment(TopShelfLinkRouter.self) private var topShelfLinks
    @State private var isHomeScrolledOffTop = false
    @State private var homeScrollToTopRevision = 0
    #endif

    var body: some View {
        @Bindable var bindableAddToPlaylist = addToPlaylist

        shellView
            .environment(addToPlaylist)
            .duskPopUp(item: $bindableAddToPlaylist.target) { target in
                AddToPlaylistSheet(target: target, plexService: plexService)
            }
            // Which tabs exist depends on the merged library list, so the shell
            // reloads it whenever the set of connected servers changes: it
            // mounts before the first server is connected.
            .task(id: plexService.serverContentRevision) {
                if librariesViewModel == nil {
                    librariesViewModel = LibrariesViewModel(plexService: plexService)
                }
                await librariesViewModel?.loadLibraries()
            }
            // Live TV discovery on its own task: behind the library load, a
            // slow section count or library order held the tab back, and a
            // server connecting mid-load cancelled it before it ever ran.
            .task(id: plexService.serverContentRevision) {
                if liveTVViewModel == nil {
                    liveTVViewModel = LiveTVViewModel(plexService: plexService, iptvService: iptvService)
                }
                iptvService.syncProfile()
                await liveTVViewModel?.discover()
            }
            // Playlists bring their tab in only when the account has one.
            .task(id: plexService.serverContentRevision) {
                await plexService.loadPlaylists()
            }
            // The shell remounts per Plex Home profile, so each profile's
            // account languages become the Audio & Subtitles defaults.
            .task {
                if let accountDefaults = await plexService.fetchAccountLanguageDefaults() {
                    preferences.applyPlexAccountLanguageDefaults(accountDefaults)
                }
            }
            // Teaches Siri the recently watched and added titles, again on
            // each return to the foreground (at most every 30 minutes) and
            // whenever a library is hidden or shown. Waits a moment so it never
            // competes with Home's first paint.
            .task(id: SiriCatalogRefreshTrigger(
                revision: plexService.serverContentRevision,
                isActive: scenePhase == .active,
                hiddenLibraryIDs: plexService.libraryOrder.hiddenSectionIdentities
            )) {
                guard scenePhase == .active else { return }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await SiriTitleCatalog.shared.refreshIfNeeded(plexService: plexService)
            }
            .onChange(of: availableTabs) { _, newTabs in
                guard !newTabs.contains(selectedTab) else { return }
                // Active iPhone tabs are normally retained while the shell
                // folds into or out of More. This remains the fallback for a
                // destination that genuinely disappears with server state.
                switch selectedTab {
                case .search, .settings, .downloads:
                    selectedTab = newTabs.contains(.more) ? .more : .home
                case .more:
                    selectedTab = newTabs.contains(.settings) ? .settings : .home
                default:
                    selectedTab = .home
                }
            }
            #if os(iOS)
            // A plain iPhone turns back to portrait before the cover leaves.
            .onChange(of: playback.showPlayer, initial: true) { _, isShowing in
                playerCoverCloseTask?.cancel()
                if isShowing {
                    PlayerCoverCloseRotation.cancel()
                    playerCoverIsUp = true
                } else {
                    playerCoverCloseTask = Task {
                        await PlayerCoverCloseRotation.rotateToPortrait()
                        guard !Task.isCancelled else { return }
                        playerCoverIsUp = false
                    }
                }
            }
            #endif
            .fullScreenCover(isPresented: playerCoverPresented, onDismiss: {
                playback.onPlayerDismissed()
            }) {
                PlayerView()
                    .environment(plexService)
                    .environment(playback)
                    .environment(playback.preferences)
            }
            #if !os(tvOS)
            .supporterPromptPresenter()
            #endif
            #if DEBUG
            .task(id: plexService.serverContentRevision) {
                await applyScreenshotDestination()
            }
            .modifier(ScreenshotSheetPresenter())
            #endif
            #if os(tvOS)
            // Re-checked whenever a server connects: a cold launch from the
            // Top Shelf delivers the link before the item's server is up.
            .task(id: TopShelfLinkAttempt(link: topShelfLinks.pending, revision: plexService.serverContentRevision)) {
                await openPendingTopShelfLink()
            }
            #endif
    }

    private var playerCoverPresented: Binding<Bool> {
        #if os(iOS)
        Binding(
            get: { playerCoverIsUp },
            set: { if !$0 { playback.showPlayer = false } }
        )
        #else
        @Bindable var bindablePlayback = playback
        return $bindablePlayback.showPlayer
        #endif
    }

    private var tabSelection: Binding<MainTabItem> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                activate(newTab)
            }
        )
    }

    @ViewBuilder
    private var shellView: some View {
        #if os(tvOS)
        MainTabTVShell(
            tabs: availableTabs,
            selection: tabSelection,
            rootBackAction: rootBackAction,
            content: tabRootView(for:)
        )
        #else
        MainTabIOSShell(tabs: availableTabs, selection: tabSelection, content: tabRootView(for:))
        #endif
    }

    #if os(tvOS)
    /// What the Siri Remote's Back press does at the root of a tab, or `nil`
    /// to leave it to the system.
    ///
    /// By default Back at a tab root leaves the app, which feels wrong
    /// anywhere but Home. So every other tab goes back to Home, and Home
    /// scrolled down goes back to its hero. Only Home at its top leaves the
    /// app. Pushed screens keep the system's pop: the shell also checks the
    /// real navigation stack, because settings rows push without the path.
    private var rootBackAction: (() -> Void)? {
        guard path(for: selectedTab).isEmpty else { return nil }
        if selectedTab != .home {
            return { activate(.home) }
        }
        guard isHomeScrolledOffTop else { return nil }
        return { homeScrollToTopRevision += 1 }
    }

    /// Acts on the Top Shelf link once the item's server is connected. Open
    /// lands on the item's detail page in Home; Play resumes it from the
    /// server's current position, not the one the snapshot was written with.
    private func openPendingTopShelfLink() async {
        guard let link = topShelfLinks.pending else { return }
        if link.isStale() {
            topShelfLinks.pending = nil
            return
        }
        guard plexService.pool.connection(for: link.id.serverID) != nil else { return }
        topShelfLinks.pending = nil

        switch link.action {
        case .open:
            if selectedTab != .home {
                activate(.home)
            }
            homePath = NavigationPath([link.route])
        case .play:
            let details = try? await plexService.getMediaDetails(
                ratingKey: link.id.ratingKey,
                serverID: link.id.serverID
            )
            await playback.play(
                id: link.id,
                resumeOffsetMilliseconds: details?.viewOffset,
                resumeOffsetDurationMilliseconds: details?.duration,
                placeholder: details.map(PlaybackPlaceholder.init(details:))
            )
        }
    }
    #endif

    private var hasDownloads: Bool {
        DownloadsFeature.isVisible && !downloadManager.records.isEmpty
    }

    private var availableTabs: [MainTabItem] {
        let desiredTabs = desiredAvailableTabs

        #if os(tvOS)
        return desiredTabs
        #else
        guard UIDevice.current.userInterfaceIdiom != .pad else {
            return desiredTabs
        }

        // Never tear down the selected tab just because a visibility change
        // crosses the iPhone's five-tab limit. Replacing a selected More tab
        // with Settings (or the reverse) destroys its NavigationStack while a
        // pushed settings destination is still active. Keep that container
        // mounted until the user selects a different tab; the desired layout
        // takes effect immediately after the selection changes.
        if selectedTab == .more, !desiredTabs.contains(.more) {
            let trailingTabs: Set<MainTabItem> = [.downloads, .settings]
            return desiredTabs.filter { !trailingTabs.contains($0) } + [.more]
        }

        if !desiredTabs.contains(selectedTab),
           let moreIndex = desiredTabs.firstIndex(of: .more) {
            var retainedTabs = desiredTabs
            retainedTabs[moreIndex] = selectedTab
            return retainedTabs
        }

        return desiredTabs
        #endif
    }

    private var desiredAvailableTabs: [MainTabItem] {
        let availableLibraryTypes = librariesViewModel?.availableLibraryTypes ?? [.movie, .show]
        let contentTabs = preferences.visibleLibraryTabs(from: availableLibraryTypes + dataDrivenTabTypes).map { type in
            switch type {
            case .liveTV: MainTabItem.liveTV
            case .playlists: MainTabItem.playlists
            default: MainTabItem.library(type)
            }
        }
        let baseTabs: [MainTabItem] = [.home] + contentTabs

        #if os(tvOS)
        return baseTabs + [.search, .settings]
        #else
        if UIDevice.current.userInterfaceIdiom == .pad {
            var trailingTabs: [MainTabItem] = []
            if hasDownloads {
                trailingTabs.append(.downloads)
            }
            trailingTabs.append(.settings)
            return baseTabs + trailingTabs
        }

        var trailingTabs: [MainTabItem] = []
        if hasDownloads {
            trailingTabs.append(.downloads)
        }
        trailingTabs.append(.settings)

        if baseTabs.count + trailingTabs.count > 5 {
            return [.home] + Array(contentTabs.prefix(3)) + [.more]
        }

        return baseTabs + trailingTabs
        #endif
    }

    /// Downloads folds into the More tab whenever it no longer fits as its own
    /// tab; the More list only shows a Downloads row in that case.
    private var moreTabIncludesDownloads: Bool {
        hasDownloads && !availableTabs.contains(.downloads)
    }

    private var moreTabContentTypes: [PlexLibraryType] {
        guard availableTabs.contains(.more) else { return [] }
        let availableLibraryTypes = librariesViewModel?.availableLibraryTypes ?? []
        let visibleTypes = preferences.visibleLibraryTabs(from: availableLibraryTypes + dataDrivenTabTypes)
        let flatTypes = availableTabs.compactMap { tab -> PlexLibraryType? in
            switch tab {
            case .library(let type): type
            case .liveTV: .liveTV
            case .playlists: .playlists
            default: nil
            }
        }
        return visibleTypes.filter { !flatTypes.contains($0) }
    }

    /// Destinations that exist only while a server offers them: Live TV with
    /// a DVR, Playlists once the account has a video playlist.
    private var dataDrivenTabTypes: [PlexLibraryType] {
        var types: [PlexLibraryType] = []
        if liveTVViewModel?.isAvailable == true {
            types.append(.liveTV)
        }
        if plexService.playlists.hasPlaylists {
            types.append(.playlists)
        }
        return types
    }

    @ViewBuilder
    private func tabRootView(for tab: MainTabItem) -> some View {
        switch tab {
        case .home:
            #if os(tvOS)
            HomeView(
                path: $homePath,
                isSelected: selectedTab == .home,
                liveTVViewModel: resolvedLiveTVViewModel,
                isScrolledOffTop: $isHomeScrolledOffTop,
                scrollToTopRevision: homeScrollToTopRevision
            )
            #else
            HomeView(
                path: $homePath,
                isSelected: selectedTab == .home,
                liveTVViewModel: resolvedLiveTVViewModel
            )
            #endif
        case .library(let libraryType):
            if let librariesViewModel {
                LibrariesView(
                    libraryType: libraryType,
                    viewModel: librariesViewModel,
                    path: binding(for: libraryType)
                )
            } else {
                NavigationStack(path: binding(for: libraryType)) {
                    ZStack {
                        Color.duskBackground.ignoresSafeArea()
                        FeatureLoadingView()
                    }
                }
            }
        case .liveTV:
            LiveTVView(viewModel: resolvedLiveTVViewModel, path: $liveTVPath)
        case .playlists:
            PlaylistsView(path: $playlistsPath)
        case .downloads:
            DownloadsView(path: $downloadsPath)
        case .search:
            SearchView(path: $searchPath)
        case .settings:
            SettingsView(path: $settingsPath)
        case .more:
            if let librariesViewModel {
                MoreView(
                    path: $morePath,
                    showsDownloads: moreTabIncludesDownloads,
                    contentTypes: moreTabContentTypes,
                    librariesViewModel: librariesViewModel,
                    liveTVViewModel: resolvedLiveTVViewModel
                )
            }
        }
    }

    private var resolvedLiveTVViewModel: LiveTVViewModel {
        if let liveTVViewModel {
            return liveTVViewModel
        }
        let viewModel = LiveTVViewModel(plexService: plexService, iptvService: iptvService)
        return viewModel
    }

    private func activate(_ tab: MainTabItem) {
        if selectedTab == tab {
            popToRoot(for: tab)
            return
        }

        if !desiredAvailableTabs.contains(selectedTab) {
            setPath(NavigationPath(), for: selectedTab)
        }
        selectedTab = tab
    }

    private func popToRoot(for tab: MainTabItem) {
        guard !path(for: tab).isEmpty else { return }

        withAnimation {
            setPath(NavigationPath(), for: tab)
        }
    }

    private func path(for tab: MainTabItem) -> NavigationPath {
        switch tab {
        case .home:
            homePath
        case .library(.movie):
            moviesPath
        case .library(.show):
            showsPath
        case .library(.video):
            videosPath
        case .library(.photo):
            photosPath
        case .library(.liveTV), .liveTV:
            liveTVPath
        case .library(.playlists), .playlists:
            playlistsPath
        case .downloads:
            downloadsPath
        case .search:
            searchPath
        case .settings:
            settingsPath
        case .more:
            morePath
        }
    }

    private func setPath(_ path: NavigationPath, for tab: MainTabItem) {
        switch tab {
        case .home:
            homePath = path
        case .library(.movie):
            moviesPath = path
        case .library(.show):
            showsPath = path
        case .library(.video):
            videosPath = path
        case .library(.photo):
            photosPath = path
        case .library(.liveTV), .liveTV:
            liveTVPath = path
        case .library(.playlists), .playlists:
            playlistsPath = path
        case .downloads:
            downloadsPath = path
        case .search:
            searchPath = path
        case .settings:
            settingsPath = path
        case .more:
            morePath = path
        }
    }

    private func binding(for libraryType: PlexLibraryType) -> Binding<NavigationPath> {
        switch libraryType {
        case .movie:
            $moviesPath
        case .show:
            $showsPath
        case .video:
            $videosPath
        case .photo:
            $photosPath
        case .liveTV:
            $liveTVPath
        case .playlists:
            $playlistsPath
        }
    }
}

#if DEBUG
private extension MainTabView {
    /// Screenshot mode (`ScreenshotMode`): opens the requested screen once the
    /// demo server and its libraries are in.
    func applyScreenshotDestination() async {
        guard ScreenshotMode.isActive else { return }
        for _ in 0..<60 {
            if let destination = await ScreenshotMode.consumeDestination(
                plexService: plexService,
                libraries: librariesViewModel?.libraries ?? [],
                downloadManager: downloadManager
            ) {
                if destination.tab == .playlists {
                    await plexService.loadPlaylists()
                }
                if selectedTab != destination.tab {
                    selectedTab = destination.tab
                }
                setPath(NavigationPath(destination.routes), for: destination.tab)
                ScreenshotMode.pendingSheet = destination.sheet
                if let target = destination.addToPlaylist {
                    // Let the detail page settle under the sheet.
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
                if let index = destination.iptvChannelIndex {
                    await playScreenshotIPTVChannel(index)
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

    /// Waits for the seeded IPTV source to load, then plays one channel with
    /// whatever is on now, like the guide's Watch Live.
    func playScreenshotIPTVChannel(_ index: Int) async {
        for _ in 0..<80 {
            await iptvService.load()
            if let lineup = iptvService.lineups.first?.lineup, !lineup.guides.isEmpty {
                let guide = lineup.guides[min(max(index, 0), lineup.guides.count - 1)]
                try? await Task.sleep(for: .seconds(1))
                if let hours = ScreenshotMode.iptvCatchUpHoursAgo,
                   let past = guide.currentProgram(at: .now.addingTimeInterval(-TimeInterval(hours) * 3600)) {
                    await playback.playIPTVCatchUp(channel: guide.channel, program: past)
                    return
                }
                await playback.playLiveTV(channel: guide.channel, program: guide.currentProgram(), lineup: lineup)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
    }
}
#endif

#if os(tvOS)
private struct TopShelfLinkAttempt: Equatable {
    let link: TopShelfLink?
    let revision: ServerContentRevision
}
#endif

private struct SiriCatalogRefreshTrigger: Equatable {
    let revision: ServerContentRevision
    let isActive: Bool
    let hiddenLibraryIDs: Set<String>
}
