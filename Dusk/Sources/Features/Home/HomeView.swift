import SwiftUI
#if os(iOS)
import UIKit
#endif

struct HomeView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.scenePhase) private var scenePhase
    @Binding var path: NavigationPath
    let isSelected: Bool
    @State private var viewModel: HomeViewModel?
    @State private var heroSelectionResetRevision = 0

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                if let viewModel {
                    let hasHomeContent = !viewModel.hubs.isEmpty ||
                        !viewModel.continueWatching.isEmpty ||
                        !viewModel.personalizedShelves.isEmpty

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
            .task(id: loadContext) {
                let newViewModel = HomeViewModel(plexService: plexService)
                viewModel = newViewModel
                await newViewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
            }
            .onAppear {
                guard viewModel != nil else { return }
                Task { await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
            }
            .onChange(of: playback.showPlayer) { _, isShowing in
                if !isShowing {
                    resetHeroSelection()
                    Task { await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, viewModel != nil else { return }
                resetHeroSelection()
                Task { await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
            }
            .onChange(of: isSelected) { _, isSelected in
                guard isSelected else { return }
                resetHeroSelection()
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
            heroSelectionResetRevision: heroSelectionResetRevision,
            play: play
        )
        #else
        HomeIOSView(
            path: $path,
            viewModel: viewModel,
            serverName: plexService.connectedServer?.name,
            recentlyAddedInlineItemLimit: recentlyAddedInlineItemLimit,
            heroSelectionResetRevision: heroSelectionResetRevision,
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
            await playback.play(ratingKey: item.ratingKey, placeholder: PlaybackPlaceholder(item: item))
        }
    }

    private func resetHeroSelection() {
        heroSelectionResetRevision += 1
    }

    private var loadContext: HomeLoadContext {
        HomeLoadContext(
            profileID: plexService.activeProfileID,
            serverID: plexService.currentServerIdentifier
        )
    }
}

private struct HomeLoadContext: Hashable {
    let profileID: String?
    let serverID: String?
}
