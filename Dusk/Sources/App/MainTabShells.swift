import SwiftUI

enum MainTabItem: Hashable, Identifiable {
    case home
    case library(PlexLibraryType)
    case libraries
    case downloads
    case search
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .library(let libraryType):
            libraryType.tabTitle
        case .libraries:
            "Libraries"
        case .downloads:
            "Downloads"
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
        case .libraries:
            "square.stack.fill"
        case .downloads:
            "arrow.down.circle.fill"
        case .search:
            "magnifyingglass"
        case .settings:
            "gearshape"
        }
    }
}

struct MainTabIOSShell<Content: View>: View {
    let tabs: [MainTabItem]
    let selection: Binding<MainTabItem>
    let content: (MainTabItem) -> Content

    var body: some View {
        TabView(selection: selection) {
            ForEach(tabs) { tab in
                content(tab)
                    .tint(Color.duskAccent)
                    .tag(tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
            }
        }
        .tint(.primary)
    }
}

struct MainTabTVShell<Content: View>: View {
    let tabs: [MainTabItem]
    let selection: Binding<MainTabItem>
    let content: (MainTabItem) -> Content

    var body: some View {
        TabView(selection: selection) {
            ForEach(tabs) { tab in
                content(tab)
                    .tag(tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
            }
        }
        .background(Color.duskBackground.ignoresSafeArea())
    }
}
