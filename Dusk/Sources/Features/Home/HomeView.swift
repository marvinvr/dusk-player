import SwiftUI
#if os(iOS)
import UIKit
#endif

struct HomeView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Binding var path: NavigationPath
    @State private var viewModel: HomeViewModel?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                if let viewModel {
                    let hasHomeContent = !viewModel.hubs.isEmpty || !viewModel.continueWatching.isEmpty

                    if viewModel.isLoading, !hasHomeContent {
                        FeatureLoadingView()
                    } else if let error = viewModel.error, !hasHomeContent {
                        FeatureErrorView(message: error) {
                            Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                        }
                    } else {
                        platformContent(viewModel)
                    }
                } else {
                    FeatureLoadingView()
                }
            }
            .task(id: plexService.connectedServer?.clientIdentifier) {
                if viewModel == nil {
                    viewModel = HomeViewModel(plexService: plexService)
                }
                await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
            }
            .onAppear {
                guard viewModel != nil else { return }
                Task { await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
            }
            .onChange(of: playback.showPlayer) { _, isShowing in
                if !isShowing {
                    Task { await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                }
            }
            .refreshable {
                await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
            }
            .duskAppNavigationDestinations()
        }
    }

    @ViewBuilder
    private func platformContent(_ viewModel: HomeViewModel) -> some View {
        #if os(tvOS)
        HomeTVView(
            path: $path,
            viewModel: viewModel,
            serverName: plexService.connectedServer?.name,
            recentlyAddedInlineItemLimit: recentlyAddedInlineItemLimit,
            play: play
        )
        #else
        HomeIOSView(
            path: $path,
            viewModel: viewModel,
            serverName: plexService.connectedServer?.name,
            recentlyAddedInlineItemLimit: recentlyAddedInlineItemLimit,
            play: play
        )
        #endif
    }

    private var recentlyAddedInlineItemLimit: Int {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? 15 : 10
        #else
        10
        #endif
    }

    private func play(_ item: PlexItem) {
        Task {
            await playback.play(ratingKey: item.ratingKey)
        }
    }
}
