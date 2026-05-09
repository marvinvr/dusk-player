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
    @State private var librariesPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
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
                if !newTabs.contains(selectedTab) {
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

    private var availableTabs: [MainTabItem] {
        let libraryTypes = librariesViewModel?.availableLibraryTypes ?? PlexLibraryType.allCases
        let hasDownloads = !downloadManager.records.isEmpty

        var tabs: [MainTabItem] = [.home, .search]

        if libraryTypes.count == 1, let only = libraryTypes.first {
            tabs.append(.library(only))
        } else if libraryTypes.count == 2, !hasDownloads {
            tabs += libraryTypes.map(MainTabItem.library)
        } else if !libraryTypes.isEmpty {
            tabs.append(.libraries)
        }

        if hasDownloads {
            tabs.append(.downloads)
        }

        tabs.append(.settings)
        return tabs
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
        case .libraries:
            LibrariesHubView(
                viewModel: librariesViewModel,
                path: $librariesPath
            )
        case .downloads:
            DownloadsView(path: $downloadsPath)
        case .search:
            SearchView(path: $searchPath)
        case .settings:
            SettingsView(path: $settingsPath)
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
        case .libraries:
            librariesPath
        case .downloads:
            downloadsPath
        case .search:
            searchPath
        case .settings:
            settingsPath
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
        case .libraries:
            librariesPath = path
        case .downloads:
            downloadsPath = path
        case .search:
            searchPath = path
        case .settings:
            settingsPath = path
        }
    }

    private func binding(for libraryType: PlexLibraryType) -> Binding<NavigationPath> {
        switch libraryType {
        case .movie:
            $moviesPath
        case .show:
            $showsPath
        }
    }
}
