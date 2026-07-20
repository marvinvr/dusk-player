import SwiftUI

/// The main tab shell shown after authentication and server connection.
struct MainTabView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager
    @State private var selectedTab: MainTabItem = .home
    @State private var homePath = NavigationPath()
    @State private var moviesPath = NavigationPath()
    @State private var showsPath = NavigationPath()
    @State private var videosPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var morePath = NavigationPath()
    @State private var librariesViewModel: LibrariesViewModel?

    var body: some View {
        @Bindable var bindablePlayback = playback

        shellView
            .task {
                if librariesViewModel == nil {
                    librariesViewModel = LibrariesViewModel(plexService: plexService)
                }
                await librariesViewModel?.loadLibraries()
            }
            .onChange(of: availableTabs) { _, newTabs in
                guard !newTabs.contains(selectedTab) else { return }
                // Tabs can fold into (or out of) More while the user is on
                // them, e.g. queuing the first download replaces Search and
                // Settings with More. Follow the fold instead of yanking the
                // user back to Home.
                switch selectedTab {
                case .search, .settings, .downloads:
                    selectedTab = newTabs.contains(.more) ? .more : .home
                case .more:
                    selectedTab = newTabs.contains(.search) ? .search : .home
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
        let libraryTypes = librariesViewModel?.availableLibraryTypes ?? [.movie, .show]
        let baseTabs: [MainTabItem] = [.home] + libraryTypes.map(MainTabItem.library)

        #if os(tvOS)
        return baseTabs + [.search, .settings]
        #else
        var trailingTabs: [MainTabItem] = [.search]
        if hasDownloads {
            trailingTabs.append(.downloads)
        }
        trailingTabs.append(.settings)

        if baseTabs.count + trailingTabs.count > 5 {
            trailingTabs = hasDownloads ? [.downloads, .more] : [.more]
        }
        if baseTabs.count + trailingTabs.count > 5 {
            trailingTabs = [.more]
        }

        return baseTabs + trailingTabs
        #endif
    }

    /// Downloads folds into the More tab whenever it no longer fits as its own
    /// tab; the More list only shows a Downloads row in that case.
    private var moreTabIncludesDownloads: Bool {
        hasDownloads && !availableTabs.contains(.downloads)
    }

    @ViewBuilder
    private func tabRootView(for tab: MainTabItem) -> some View {
        switch tab {
        case .home:
            HomeView(path: $homePath)
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
        case .downloads:
            DownloadsView(path: $downloadsPath)
        case .search:
            SearchView(path: $searchPath)
        case .settings:
            SettingsView(path: $settingsPath)
        case .more:
            MoreView(path: $morePath, showsDownloads: moreTabIncludesDownloads)
        }
    }

    private func activate(_ tab: MainTabItem) {
        if selectedTab == tab {
            popToRoot(for: tab)
            return
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
        }
    }
}
