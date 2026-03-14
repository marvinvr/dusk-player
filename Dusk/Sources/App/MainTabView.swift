import SwiftUI

enum AppNavigationRoute: Hashable {
    case library(PlexLibrary)
    case hub(PlexHub)
    case media(type: PlexMediaType, ratingKey: String)
    case person(PlexPersonReference)

    static func destination(for item: PlexItem) -> Self {
        if let person = PlexPersonReference(item: item) {
            return .person(person)
        }

        return .media(type: item.type, ratingKey: item.ratingKey)
    }
}

struct AppNavigationDestinationView: View {
    @Environment(PlexService.self) private var plexService

    let route: AppNavigationRoute

    @ViewBuilder
    var body: some View {
        switch route {
        case .library(let library):
            LibraryItemsView(library: library, plexService: plexService)
        case .hub(let hub):
            HomeHubItemsView(hub: hub, plexService: plexService)
        case let .media(type, ratingKey):
            MediaDetailDestinationView(
                type: type,
                ratingKey: ratingKey,
                plexService: plexService
            )
        case .person(let person):
            ActorDetailView(person: person, plexService: plexService)
        }
    }
}

extension View {
    func duskAppNavigationDestinations() -> some View {
        navigationDestination(for: AppNavigationRoute.self) { route in
            AppNavigationDestinationView(route: route)
        }
    }
}

/// The main tab shell shown after authentication and server connection.
struct MainTabView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var selectedTab: Tab = .home
    @State private var homePath = NavigationPath()
    @State private var moviesPath = NavigationPath()
    @State private var showsPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var librariesViewModel: LibrariesViewModel?

    private enum Tab: Hashable, Identifiable {
        case home
        case library(PlexLibraryType)
        case search
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .home:
                "Home"
            case .library(let libraryType):
                libraryType.tabTitle
            case .search:
                "Search"
            case .settings:
                "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .home:
                "house.fill"
            case .library(let libraryType):
                libraryType.systemImage
            case .search:
                "magnifyingglass"
            case .settings:
                "gearshape"
            }
        }
    }

    var body: some View {
        @Bindable var bindablePlayback = playback

        tabView
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

    private var tabSelection: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                activate(newTab)
            }
        )
    }

    private var tabView: some View {
        TabView(selection: tabSelection) {
            ForEach(availableTabs) { tab in
                tabRootView(for: tab)
                    .tag(tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
            }
        }
    }

    private var availableTabs: [Tab] {
        var tabs: [Tab] = [.home]
        tabs += PlexLibraryType.allCases.map(Tab.library)
        tabs += [.search, .settings]
        return tabs
    }

    @ViewBuilder
    private func tabRootView(for tab: Tab) -> some View {
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
        case .search:
            SearchView(path: $searchPath)
        case .settings:
            SettingsView(path: $settingsPath)
        }
    }

    private func activate(_ tab: Tab) {
        if selectedTab == tab {
            popToRoot(for: tab)
            return
        }

        selectedTab = tab
    }

    private func popToRoot(for tab: Tab) {
        guard !path(for: tab).isEmpty else { return }

        withAnimation {
            setPath(NavigationPath(), for: tab)
        }
    }

    private func path(for tab: Tab) -> NavigationPath {
        switch tab {
        case .home:
            homePath
        case .library(.movie):
            moviesPath
        case .library(.show):
            showsPath
        case .search:
            searchPath
        case .settings:
            settingsPath
        }
    }

    private func setPath(_ path: NavigationPath, for tab: Tab) {
        switch tab {
        case .home:
            homePath = path
        case .library(.movie):
            moviesPath = path
        case .library(.show):
            showsPath = path
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
