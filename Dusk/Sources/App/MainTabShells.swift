import SwiftUI

enum MainTabItem: Hashable, Identifiable {
    case home
    case library(PlexLibraryType)
    case liveTV
    case downloads
    case search
    case settings
    case more

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .library(let libraryType):
            libraryType.tabTitle
        case .liveTV:
            "Live TV"
        case .downloads:
            "Downloads"
        case .search:
            "Search"
        case .settings:
            "Settings"
        case .more:
            "More"
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            "house"
        case .library(let libraryType):
            libraryType.systemImage
        case .liveTV:
            "dot.radiowaves.left.and.right"
        case .downloads:
            "arrow.down.circle"
        case .search:
            "magnifyingglass"
        case .settings:
            "gearshape"
        case .more:
            "ellipsis"
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
                Tab(
                    tab.title,
                    systemImage: tab.systemImage,
                    value: tab
                ) {
                    content(tab)
                        .tint(Color.duskAccent)
                }
            }
        }
        .tint(.primary)
    }
}

struct MainTabTVShell<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

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
                            .symbolRenderingMode(.monochrome)
                    }
            }
        }
        .tint(colorScheme == .dark ? Color.duskBackground : Color.primary)
        .background(Color.duskBackground.ignoresSafeArea())
    }
}
