import SwiftUI

/// The trailing "More" tab shown on iOS when the tab bar would otherwise
/// exceed five tabs. Hosts Search, optionally Downloads (when it no longer
/// fits as its own tab), and Settings as pushed destinations.
struct MoreView: View {
    @Binding var path: NavigationPath
    let showsDownloads: Bool

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()
                moreList
            }
            .duskNavigationTitle("More")
            .duskNavigationBarTitleDisplayModeLarge()
            .navigationDestination(for: MoreRoute.self) { route in
                destinationView(for: route)
            }
            .duskAppNavigationDestinations()
        }
    }

    private var moreList: some View {
        List {
            Section {
                NavigationLink(value: MoreRoute.search) {
                    MoreRow(title: "Search", systemImage: "magnifyingglass")
                }

                if showsDownloads {
                    NavigationLink(value: MoreRoute.downloads) {
                        MoreRow(title: "Downloads", systemImage: "arrow.down.circle.fill")
                    }
                }

                NavigationLink(value: MoreRoute.settings) {
                    MoreRow(title: "Settings", systemImage: "gearshape")
                }
            }
            .listRowBackground(Color.duskSurface)
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .duskScrollContentBackgroundHidden()
    }

    @ViewBuilder
    private func destinationView(for route: MoreRoute) -> some View {
        switch route {
        case .search:
            SearchRootContent()
        case .downloads:
            DownloadsRootContent(path: $path)
        case .settings:
            SettingsRootContent()
        }
    }
}

private enum MoreRoute: Hashable {
    case search
    case downloads
    case settings
}

private struct MoreRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.duskAccent.opacity(0.14))
                    .frame(width: 34, height: 34)

                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.duskAccent)
            }

            Text(title)
                .foregroundStyle(Color.duskTextPrimary)

            Spacer()
        }
        .contentShape(Rectangle())
    }
}
