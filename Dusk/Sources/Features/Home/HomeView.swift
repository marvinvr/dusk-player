import SwiftUI
#if os(iOS)
import UIKit
#endif

struct HomeView: View {
    @Environment(PlexService.self) private var plexService
    @Binding var path: NavigationPath
    @State private var viewModel: HomeViewModel?

    private let continueWatchingCardWidth: CGFloat = 280
    private let continueWatchingAspectRatio: CGFloat = 16.0 / 9.0

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                if let viewModel {
                    if viewModel.isLoading, viewModel.hubs.isEmpty {
                        ProgressView()
                            .tint(Color.duskAccent)
                    } else if let error = viewModel.error, viewModel.hubs.isEmpty {
                        errorView(error)
                    } else {
                        contentView(viewModel)
                    }
                }
            }
            .task(id: plexService.connectedServer?.clientIdentifier) {
                if viewModel == nil {
                    viewModel = HomeViewModel(plexService: plexService)
                }
                await viewModel?.load()
            }
            .refreshable {
                await viewModel?.load()
            }
            .duskNavigationTitle("Home")
            .duskNavigationBarTitleDisplayModeLarge()
            .duskAppNavigationDestinations()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func contentView(_ vm: HomeViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showsHomeServerSubtitle, let serverName = plexService.connectedServer?.name {
                    homeSubtitle(serverName)
                        .padding(.bottom, 12)
                }

                LazyVStack(alignment: .leading, spacing: 18) {
                    // Continue Watching (Task B) — top of home
                    if !vm.continueWatching.isEmpty {
                        continueWatchingSection(vm)
                    }

                    // Hub carousels (Task A) — Recently Added, etc.
                    ForEach(vm.hubs) { hub in
                        let items = vm.visibleItems(in: hub)
                        if !items.isEmpty {
                            hubSection(hub, items: items, vm: vm)
                        }
                    }
                }
            }
            .padding(.top, showsHomeServerSubtitle ? -10 : 16)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 88)
        }
    }

    // MARK: - Continue Watching

    @ViewBuilder
    private func continueWatchingSection(_ vm: HomeViewModel) -> some View {
        let imageWidth = Int(continueWatchingCardWidth.rounded(.up))
        let imageHeight = Int((continueWatchingCardWidth / continueWatchingAspectRatio).rounded(.up))

        MediaCarousel(title: "Continue Watching") {
            ForEach(vm.continueWatching) { item in
                #if os(tvOS)
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink(value: AppNavigationRoute.destination(for: item)) {
                        PosterArtwork(
                            imageURL: vm.landscapeImageURL(for: item, width: imageWidth, height: imageHeight),
                            progress: vm.progress(for: item),
                            width: continueWatchingCardWidth,
                            imageAspectRatio: continueWatchingAspectRatio
                        )
                    }
                    .buttonStyle(.plain)
                    .duskSuppressTVOSButtonChrome()

                    PosterCardText(
                        title: vm.displayTitle(for: item),
                        subtitle: vm.displaySubtitle(for: item),
                        width: continueWatchingCardWidth
                    )
                }
                .frame(width: continueWatchingCardWidth, alignment: .topLeading)
                #else
                NavigationLink(value: AppNavigationRoute.destination(for: item)) {
                    PosterCard(
                        imageURL: vm.landscapeImageURL(for: item, width: imageWidth, height: imageHeight),
                        title: vm.displayTitle(for: item),
                        subtitle: vm.displaySubtitle(for: item),
                        progress: vm.progress(for: item),
                        width: continueWatchingCardWidth,
                        imageAspectRatio: continueWatchingAspectRatio
                    )
                }
                .buttonStyle(.plain)
                .duskSuppressTVOSButtonChrome()
                #endif
            }
        }
    }

    // MARK: - Hub Section

    @ViewBuilder
    private func hubSection(_ hub: PlexHub, items: [PlexItem], vm: HomeViewModel) -> some View {
        let imageWidth = 130
        let imageHeight = 195

        MediaCarousel(title: hub.title) {
            ForEach(items) { item in
                #if os(tvOS)
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink(value: AppNavigationRoute.destination(for: item)) {
                        PosterArtwork(
                            imageURL: vm.posterURL(for: item, width: imageWidth, height: imageHeight),
                            width: 130,
                            imageAspectRatio: 2.0 / 3.0
                        )
                    }
                    .buttonStyle(.plain)
                    .duskSuppressTVOSButtonChrome()

                    PosterCardText(
                        title: item.title,
                        subtitle: item.year.map(String.init),
                        width: 130
                    )
                }
                .frame(width: 130, alignment: .topLeading)
                #else
                NavigationLink(value: AppNavigationRoute.destination(for: item)) {
                    PosterCard(
                        imageURL: vm.posterURL(for: item, width: imageWidth, height: imageHeight),
                        title: item.title,
                        subtitle: item.year.map(String.init)
                    )
                }
                .buttonStyle(.plain)
                .duskSuppressTVOSButtonChrome()
                #endif
            }
        }
    }

    // MARK: - Error

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Color.duskTextSecondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") {
                Task { await viewModel?.load() }
            }
            .foregroundStyle(Color.duskAccent)
            .duskSuppressTVOSButtonChrome()
        }
    }

    private func homeSubtitle(_ serverName: String) -> some View {
        Text(serverName)
            .font(.subheadline)
            .foregroundStyle(Color.duskTextSecondary)
            .lineLimit(1)
            .padding(.horizontal, 20)
    }

    private var showsHomeServerSubtitle: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}
