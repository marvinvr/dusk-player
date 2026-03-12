import SwiftUI

enum AppNavigationRoute: Hashable {
    case library(PlexLibrary)
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
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var selectedTab: Tab = .home
    @State private var homePath = NavigationPath()
    @State private var librariesPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    private enum Tab: Hashable, CaseIterable, Identifiable {
        case home
        case libraries
        case search
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .home:
                "Home"
            case .libraries:
                "Libraries"
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
            case .libraries:
                "rectangle.stack.fill"
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
        .fullScreenCover(isPresented: $bindablePlayback.showPlayer, onDismiss: {
            playback.onPlayerDismissed()
        }) {
            if let engine = playback.engine,
               let playbackSource = playback.playbackSource {
                PlayerView(
                    engine: engine,
                    playbackSource: playbackSource,
                    debugInfo: playback.debugInfo
                )
            }
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
            tabRootView(for: .home)
                .tag(Tab.home)
                .tabItem {
                    Label(Tab.home.title, systemImage: Tab.home.systemImage)
                }

            tabRootView(for: .libraries)
                .tag(Tab.libraries)
                .tabItem {
                    Label(Tab.libraries.title, systemImage: Tab.libraries.systemImage)
                }

            tabRootView(for: .search)
                .tag(Tab.search)
                .tabItem {
                    Label(Tab.search.title, systemImage: Tab.search.systemImage)
                }

            tabRootView(for: .settings)
                .tag(Tab.settings)
                .tabItem {
                    Label(Tab.settings.title, systemImage: Tab.settings.systemImage)
                }
        }
    }

    @ViewBuilder
    private func tabRootView(for tab: Tab) -> some View {
        switch tab {
        case .home:
            HomeView(path: $homePath)
        case .libraries:
            LibrariesView(path: $librariesPath)
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
        case .libraries:
            librariesPath
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
        case .libraries:
            librariesPath = path
        case .search:
            searchPath = path
        case .settings:
            settingsPath = path
        }
    }
}
