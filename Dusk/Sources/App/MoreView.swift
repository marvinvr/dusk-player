import SwiftUI

/// The trailing "More" tab shown on iPhone when the tab bar would otherwise
/// exceed five tabs. Hosts Downloads and Settings as pushed destinations.
struct MoreView: View {
    @Binding var path: NavigationPath
    let showsDownloads: Bool
    let contentTypes: [PlexLibraryType]
    let librariesViewModel: LibrariesViewModel
    let liveTVViewModel: LiveTVViewModel

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
                ForEach(contentTypes, id: \.self) { contentType in
                    NavigationLink(value: MoreRoute.content(contentType)) {
                        MoreRow(title: contentType.tabTitle, systemImage: contentType.systemImage)
                    }
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
        case .content(.liveTV):
            LiveTVRootContent(viewModel: liveTVViewModel)
        case .content(let libraryType):
            LibrariesRootContent(libraryType: libraryType, viewModel: librariesViewModel)
        case .downloads:
            DownloadsRootContent(path: $path)
        case .settings:
            SettingsRootContent()
        }
    }
}

private enum MoreRoute: Hashable {
    case content(PlexLibraryType)
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
