import SwiftUI

/// The main tab shell shown after authentication and server connection.
struct MainTabView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(UserPreferences.self) private var preferences
    @State private var selectedTab: MainTabItem = .home
    @State private var homePath = NavigationPath()
    @State private var moviesPath = NavigationPath()
    @State private var showsPath = NavigationPath()
    @State private var videosPath = NavigationPath()
    @State private var liveTVPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var morePath = NavigationPath()
    @State private var librariesViewModel: LibrariesViewModel?
    @State private var liveTVViewModel: LiveTVViewModel?

    var body: some View {
        @Bindable var bindablePlayback = playback

        shellView
            .task {
                if librariesViewModel == nil {
                    librariesViewModel = LibrariesViewModel(plexService: plexService)
                }
                if liveTVViewModel == nil {
                    liveTVViewModel = LiveTVViewModel(plexService: plexService)
                }
                await librariesViewModel?.loadLibraries()
                await liveTVViewModel?.discover()
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
            .fullScreenCover(isPresented: $bindablePlayback.showPlayer, onDismiss: {
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
        MainTabTVShell(tabs: availableTabs, selection: tabSelection, content: tabRootView(for:))
        #else
        MainTabIOSShell(tabs: availableTabs, selection: tabSelection, content: tabRootView(for:))
        #endif
    }

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
        let availableTypes = availableLibraryTypes + (liveTVViewModel?.isAvailable == true ? [.liveTV] : [])
        let contentTabs = preferences.visibleLibraryTabs(from: availableTypes).map { type in
            type == .liveTV ? MainTabItem.liveTV : MainTabItem.library(type)
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
        let availableTypes = availableLibraryTypes + (liveTVViewModel?.isAvailable == true ? [.liveTV] : [])
        let visibleTypes = preferences.visibleLibraryTabs(from: availableTypes)
        let flatTypes = availableTabs.compactMap { tab -> PlexLibraryType? in
            switch tab {
            case .library(let type): type
            case .liveTV: .liveTV
            default: nil
            }
        }
        return visibleTypes.filter { !flatTypes.contains($0) }
    }

    @ViewBuilder
    private func tabRootView(for tab: MainTabItem) -> some View {
        switch tab {
        case .home:
            HomeView(
                path: $homePath,
                isSelected: selectedTab == .home,
                liveTVViewModel: resolvedLiveTVViewModel
            )
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
        let viewModel = LiveTVViewModel(plexService: plexService)
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
        case .library(.liveTV), .liveTV:
            liveTVPath
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
        case .library(.liveTV), .liveTV:
            liveTVPath = path
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
        case .liveTV:
            $liveTVPath
        }
    }
}
