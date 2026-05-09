import SwiftUI

/// A combined "Libraries" tab that lists available library types (Movies, TV Shows)
/// and lets the user navigate into each one.
struct LibrariesHubView: View {
    @Environment(PlexService.self) private var plexService
    let viewModel: LibrariesViewModel?
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                if let viewModel {
                    let types = viewModel.availableLibraryTypes

                    if viewModel.isLoading && viewModel.libraries.isEmpty {
                        FeatureLoadingView()
                    } else if let error = viewModel.error, viewModel.libraries.isEmpty {
                        FeatureErrorView(message: error) {
                            Task { await viewModel.loadLibraries(force: true) }
                        }
                    } else if types.isEmpty {
                        FeatureEmptyStateView(
                            systemImage: "square.stack",
                            title: "No Libraries",
                            message: "No movie or TV show libraries found on this server."
                        )
                    } else {
                        libraryTypeList(types, viewModel: viewModel)
                    }
                } else {
                    FeatureLoadingView()
                }
            }
            .navigationTitle("Libraries")
            .duskNavigationBarTitleDisplayModeLarge()
            .task {
                await viewModel?.loadLibraries()
            }
            .navigationDestination(for: PlexLibrary.self) { library in
                LibraryRecommendationsView(
                    library: library,
                    plexService: plexService,
                    navigationTitle: library.title
                )
            }
            .duskAppNavigationDestinations()
        }
    }

    private func libraryTypeList(_ types: [PlexLibraryType], viewModel: LibrariesViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(types, id: \.self) { libraryType in
                    let libraries = viewModel.libraries(for: libraryType)

                    if libraries.count == 1, let library = libraries.first {
                        NavigationLink(value: library) {
                            LibrariesHubRow(
                                title: libraryType.tabTitle,
                                systemImage: libraryType.systemImage,
                                subtitle: library.title
                            )
                        }
                        .duskSuppressTVOSButtonChrome()
                    } else {
                        ForEach(libraries) { library in
                            NavigationLink(value: library) {
                                LibrariesHubRow(
                                    title: library.title,
                                    systemImage: libraryType.systemImage,
                                    subtitle: libraryType.tabTitle
                                )
                            }
                            .duskSuppressTVOSButtonChrome()
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }
}

private struct LibrariesHubRow: View {
    let title: String
    let systemImage: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Color.duskSurface
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.duskTextPrimary)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.duskTextSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)
        }
        .padding(12)
        .background(Color.duskSurface)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .duskTVOSFocusEffectShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
