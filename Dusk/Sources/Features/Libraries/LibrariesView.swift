import SwiftUI

struct LibrariesView: View {
    let libraryType: PlexLibraryType
    let viewModel: LibrariesViewModel
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            LibrariesRootContent(libraryType: libraryType, viewModel: viewModel)
                .duskAppNavigationDestinations()
        }
    }
}

struct LibrariesRootContent: View {
    @Environment(PlexService.self) private var plexService
    let libraryType: PlexLibraryType
    let viewModel: LibrariesViewModel

    var body: some View {
        rootContent
            .task {
                await viewModel.loadLibraries()
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        let libraries = viewModel.libraries(for: libraryType)

        if viewModel.isLoading && viewModel.libraries.isEmpty {
            loadingView
        } else if let error = viewModel.error, viewModel.libraries.isEmpty {
            errorView(message: error)
        } else if libraries.count == 1, let library = libraries.first {
            LibraryRecommendationsView(
                library: library,
                plexService: plexService,
                navigationTitle: libraryType.tabTitle
            )
        } else if libraries.isEmpty {
            emptyView
        } else {
            libraryList(libraries)
        }
    }

    private var loadingView: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()
            FeatureLoadingView()
        }
        .duskNavigationTitle(libraryType.tabTitle)
        .duskNavigationBarTitleDisplayModeLarge()
    }

    private func errorView(message: String) -> some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()
            FeatureErrorView(message: message) {
                Task { await viewModel.loadLibraries(force: true) }
            }
        }
        .duskNavigationTitle(libraryType.tabTitle)
        .duskNavigationBarTitleDisplayModeLarge()
    }

    private var emptyView: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()
            FeatureEmptyStateView(
                systemImage: libraryType.systemImage,
                title: "No \(libraryType.tabTitle) libraries found"
            )
        }
        .duskNavigationTitle(libraryType.tabTitle)
        .duskNavigationBarTitleDisplayModeLarge()
    }

    private func libraryList(_ libraries: [PlexLibrary]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(libraries) { library in
                    NavigationLink(value: AppNavigationRoute.libraryRecommendations(library)) {
                        LibraryRowContent(library: library, vm: viewModel)
                    }
                    .duskSuppressTVOSButtonChrome()
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .background(Color.duskBackground.ignoresSafeArea())
        .duskNavigationTitle(libraryType.tabTitle)
        .duskNavigationBarTitleDisplayModeLarge()
    }
}

private struct LibraryRowContent: View {
    let library: PlexLibrary
    let vm: LibrariesViewModel

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                if let url = vm.artURL(for: library, width: 64, height: 64) {
                    DuskAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            libraryIconPlaceholder(vm.iconName(for: library))
                        }
                    }
                } else {
                    libraryIconPlaceholder(vm.iconName(for: library))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 4) {
                Text(library.title)
                    .font(.headline)
                    .foregroundStyle(Color.duskTextPrimary)

                Text(libraryTypeLabel)
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

    private var libraryTypeLabel: String {
        library.libraryType?.tabTitle ?? library.type.capitalized
    }

    private func libraryIconPlaceholder(_ iconName: String) -> some View {
        Color.duskSurface
            .overlay {
                Image(systemName: iconName)
                    .font(libraryPlaceholderIconFont)
                    .foregroundStyle(Color.duskTextSecondary)
            }
    }

    private var libraryPlaceholderIconFont: Font {
        #if os(tvOS)
        .system(size: 20, weight: .medium)
        #else
        .title2
        #endif
    }
}

// MARK: - PlexLibrary Hashable conformance for NavigationLink

extension PlexLibrary: Hashable {
    static func == (lhs: PlexLibrary, rhs: PlexLibrary) -> Bool {
        lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}
