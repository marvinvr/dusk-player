import SwiftUI
#if os(iOS)
import UIKit
#endif

struct SearchView: View {
    @Environment(PlexService.self) private var plexService
    @Binding var path: NavigationPath
    @State private var viewModel: SearchViewModel?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                if let viewModel {
                    searchContent(viewModel)
                }
            }
            .duskNavigationTitle("Search")
            .duskNavigationBarTitleDisplayModeLarge()
            .duskAppNavigationDestinations()
        }
        .onAppear {
            if viewModel == nil {
                viewModel = SearchViewModel(plexService: plexService)
            }
        }
    }

    @ViewBuilder
    private func searchContent(_ vm: SearchViewModel) -> some View {
        @Bindable var vm = vm

        let searchResultsList = List {
            if vm.isSearching && vm.results.isEmpty {
                loadingRow
            } else if let error = vm.error, vm.results.isEmpty {
                errorRow(error)
            } else if vm.hasSearched && vm.results.isEmpty {
                noResultsRow
            } else {
                ForEach(vm.results) { group in
                    resultSection(group)
                }
            }
        }
        .listStyle(.plain)
        .duskScrollContentBackgroundHidden()
        .onChange(of: vm.query) {
            vm.searchDebounced()
        }
        .overlay {
            if !vm.hasSearched && vm.results.isEmpty && !vm.isSearching {
                emptyPrompt
            }
        }

        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            searchResultsList
                .searchable(
                    text: $vm.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Movies, Shows, Actors..."
                )
        } else {
            searchResultsList
                .searchable(text: $vm.query, prompt: "Movies, Shows, Actors...")
        }
        #else
        searchResultsList
            .searchable(text: $vm.query, prompt: "Movies, Shows, Actors...")
        #endif
    }

    // MARK: - Result Sections

    @ViewBuilder
    private func resultSection(_ group: PlexSearchResult) -> some View {
        Section {
            ForEach(group.items) { item in
                NavigationLink(value: route(for: item)) {
                    searchRow(item)
                }
                .listRowBackground(Color.duskSurface)
                .duskSuppressTVOSButtonChrome()
            }
        } header: {
            Text(group.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.duskTextSecondary)
                .textCase(nil)
        }
    }

    // MARK: - Search Row

    @ViewBuilder
    private func searchRow(_ item: PlexItem) -> some View {
        HStack(spacing: 12) {
            posterImage(item)

            VStack(alignment: .leading, spacing: 4) {
                Text(itemTitle(for: item))
                    .font(.body)
                    .foregroundStyle(Color.duskTextPrimary)
                    .lineLimit(2)

                Text(itemSubtitle(for: item))
                    .font(.caption)
                    .foregroundStyle(Color.duskTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if item.isPartiallyWatched, let duration = item.duration, let offset = item.viewOffset {
                progressIndicator(offset: offset, duration: duration)
            } else if item.isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.duskAccent)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func route(for item: PlexItem) -> AppNavigationRoute {
        AppNavigationRoute.destination(for: item)
    }

    @ViewBuilder
    private func posterImage(_ item: PlexItem) -> some View {
        let imageSize = item.type == .person
            ? CGSize(width: 56, height: 56)
            : CGSize(width: 50, height: 75)

        AsyncImage(
            url: viewModel?.imageURL(
                for: item.preferredPosterPath,
                width: Int(imageSize.width.rounded(.up)),
                height: Int(imageSize.height.rounded(.up))
            )
        ) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            default:
                Image(systemName: iconForType(item.type))
                    .font(.title3)
                    .foregroundStyle(Color.duskTextSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.duskSurface)
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .clipShape(item.type == .person ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))
    }

    @ViewBuilder
    private func progressIndicator(offset: Int, duration: Int) -> some View {
        let progress = min(Double(offset) / Double(duration), 1.0)
        CircularProgressView(progress: progress)
            .frame(width: 20, height: 20)
    }

    // MARK: - Empty / Loading / Error States

    private var emptyPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Color.duskTextSecondary)
            Text("Search your Plex library")
                .font(.headline)
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(Color.duskAccent)
            Spacer()
        }
        .listRowBackground(Color.clear)
        .duskListRowSeparatorHidden()
    }

    private func errorRow(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(Color.duskTextSecondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
        .duskListRowSeparatorHidden()
    }

    private var noResultsRow: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.title2)
                .foregroundStyle(Color.duskTextSecondary)
            Text("No results found")
                .font(.subheadline)
                .foregroundStyle(Color.duskTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
        .duskListRowSeparatorHidden()
    }

    // MARK: - Helpers

    private func itemTitle(for item: PlexItem) -> String {
        switch item.type {
        case .episode:
            if let show = item.grandparentTitle {
                return show
            }
            return item.title
        default:
            return item.title
        }
    }

    private func itemSubtitle(for item: PlexItem) -> String {
        var parts: [String] = []

        switch item.type {
        case .movie:
            if let year = item.year { parts.append(String(year)) }
            parts.append("Movie")
        case .show:
            if let year = item.year { parts.append(String(year)) }
            if let count = item.childCount { parts.append("\(count) seasons") }
        case .episode:
            if let label = episodeLabel(season: item.parentIndex, episode: item.index) {
                parts.append(label)
            }
            parts.append(item.title)
        case .season:
            if let show = item.parentTitle { parts.append(show) }
            parts.append(item.title)
        case .person:
            parts.append("Actor")
        default:
            if let year = item.year { parts.append(String(year)) }
            parts.append(item.type.rawValue.capitalized)
        }

        return parts.joined(separator: " · ")
    }

    private func iconForType(_ type: PlexMediaType) -> String {
        MediaTextFormatter.mediaTypeIconName(type)
    }

    private func episodeLabel(season: Int?, episode: Int?) -> String? {
        MediaTextFormatter.seasonEpisodeLabel(season: season, episode: episode, separator: ", ")
    }
}
