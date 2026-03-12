import SwiftUI

struct LibrariesView: View {
    @Environment(PlexService.self) private var plexService
    @Binding var path: NavigationPath
    @State private var viewModel: LibrariesViewModel?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                if let vm = viewModel {
                    if vm.isLoading && vm.libraries.isEmpty {
                        ProgressView()
                            .tint(Color.duskAccent)
                    } else if let error = vm.error, vm.libraries.isEmpty {
                        errorView(error)
                    } else if vm.libraries.isEmpty {
                        emptyView
                    } else {
                        libraryList(vm)
                    }
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = LibrariesViewModel(plexService: plexService)
                }
                await viewModel?.loadLibraries()
            }
            .duskNavigationTitle("Libraries")
            .duskNavigationBarTitleDisplayModeLarge()
            .duskAppNavigationDestinations()
        }
    }

    // MARK: - Library List

    @ViewBuilder
    private func libraryList(_ vm: LibrariesViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(vm.libraries) { library in
                    NavigationLink(value: AppNavigationRoute.library(library)) {
                        libraryRow(library, vm: vm)
                    }
                    .duskSuppressTVOSButtonChrome()
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func libraryRow(_ library: PlexLibrary, vm: LibrariesViewModel) -> some View {
        LibraryRowContent(library: library, vm: vm)
    }

    private func libraryIconPlaceholder(_ iconName: String) -> some View {
        Color.duskSurface
            .overlay {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(Color.duskTextSecondary)
            }
    }

    // MARK: - Empty / Error

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.largeTitle)
                .foregroundStyle(Color.duskTextSecondary)
            Text("No libraries found")
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Color.duskTextSecondary)
            Text(message)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") {
                Task { await viewModel?.loadLibraries() }
            }
            .foregroundStyle(Color.duskAccent)
            .duskSuppressTVOSButtonChrome()
        }
    }
}

private struct LibraryRowContent: View {
    let library: PlexLibrary
    let vm: LibrariesViewModel

    var body: some View {
        HStack(spacing: 16) {
            // Library art thumbnail
            ZStack {
                if let url = vm.artURL(for: library, width: 64, height: 64) {
                    AsyncImage(url: url) { phase in
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

                Text(library.type.capitalized)
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
