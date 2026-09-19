import SwiftUI
#if os(iOS)
import UIKit
#endif

struct HomeView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(UserPreferences.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase
    @Binding var path: NavigationPath
    let isSelected: Bool
    let liveTVViewModel: LiveTVViewModel
    @State private var viewModel: HomeViewModel?
    @State private var heroSelectionResetRevision = 0

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                if let viewModel {
                    let hasHomeContent = viewModel.hasLoadedContent

                    if !hasHomeContent, !availability.isReady {
                        // Nothing to show and the cause is the servers, not
                        // Home: say which one, with the action that fixes it.
                        ServerAvailabilityStateView(availability: availability)
                    } else if viewModel.isLoading, !hasHomeContent {
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
            // Keyed on the merged-content revision: Home has to reload when a
            // server connects or drops, when priority changes, and when the
            // profile changes — the tab shell mounts before any of that.
            .task(id: plexService.serverContentRevision) {
                let newViewModel = viewModel ?? HomeViewModel(plexService: plexService)
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
                guard preferences.showsLiveTVOnHome else { return }
                Task { await liveTVViewModel.loadNowPlaying(force: true) }
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
            offlineServerNames: availability.offlineServerNames,
            recentlyAddedInlineItemLimit: recentlyAddedInlineItemLimit,
            heroSelectionResetRevision: heroSelectionResetRevision,
            liveTVViewModel: liveTVViewModel,
            showsLiveTV: preferences.showsLiveTVOnHome,
            playLiveTV: playLiveTV,
            play: play
        )
        #else
        HomeIOSView(
            path: $path,
            viewModel: viewModel,
            offlineServerNames: availability.offlineServerNames,
            recentlyAddedInlineItemLimit: recentlyAddedInlineItemLimit,
            heroSelectionResetRevision: heroSelectionResetRevision,
            liveTVViewModel: liveTVViewModel,
            showsLiveTV: preferences.showsLiveTVOnHome,
            playLiveTV: playLiveTV,
            play: play
        )
        #endif
    }

    private var availability: ServerAvailability {
        plexService.pool.availability
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
            await playback.play(
                id: item.id,
                resumeOffsetMilliseconds: item.viewOffset,
                resumeOffsetDurationMilliseconds: item.duration,
                placeholder: PlaybackPlaceholder(item: item)
            )
        }
    }

    private func playLiveTV(
        _ channel: PlexLiveChannel,
        _ program: PlexLiveProgram,
        _ lineup: PlexLiveTVLineup
    ) {
        Task {
            await playback.playLiveTV(channel: channel, program: program, lineup: lineup)
        }
    }

    private func resetHeroSelection() {
        heroSelectionResetRevision += 1
    }
}
