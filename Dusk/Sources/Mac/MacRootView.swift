#if os(macOS)
import SwiftUI

/// The Mac's main window once the Plex session is ready: the counterpart of
/// `MainTabView`, as a sidebar shell instead of a tab bar.
///
/// - A `NavigationSplitView` whose sidebar lists Home, Search, the content
///   destinations `MainTabView` derives (library types, Live TV, Playlists, in
///   the user's library order and visibility from `UserPreferences`) and
///   Downloads. Settings is the Settings scene (⌘,), not a destination.
/// - One `NavigationStack(path:)` per destination, the same shared root views
///   and `AppNavigationRoute` destinations iOS uses. Paths live in
///   `MacShellRouter`, which the menu bar drives (`MacCommands`).
/// - The player (`MacPlayerView`) covers the whole window, sidebar and toolbar
///   included, while `PlaybackCoordinator.showPlayer` is true; it runs the iOS
///   cover's `onDismiss` teardown itself when it unmounts.
struct MacRootView: View {
    @Environment(PlexService.self) var plexService
    @Environment(PlaybackCoordinator.self) var playback
    @Environment(DownloadManager.self) var downloadManager
    @Environment(UserPreferences.self) private var preferences
    @Environment(IPTVService.self) private var iptvService
    @Environment(MacShellRouter.self) var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var librariesViewModel: LibrariesViewModel?
    @State private var liveTVViewModel: LiveTVViewModel?
    @State var addToPlaylist = AddToPlaylistPresenter()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var bindableAddToPlaylist = addToPlaylist
        @Bindable var bindableRouter = router

        ZStack {
            splitView
                // Mounted underneath so every stack keeps its place, but out of
                // reach of the keyboard and VoiceOver while the player is up.
                .disabled(playback.showPlayer)
                .accessibilityHidden(playback.showPlayer)

            if playback.showPlayer {
                MacPlayerView()
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // Shared pages pick their iPad layout from a regular width class; a
        // Mac window is always that, whatever macOS reports by default.
        .environment(\.horizontalSizeClass, .regular)
        .animation(.easeInOut(duration: 0.2), value: playback.showPlayer)
        .toolbar(playback.showPlayer ? .hidden : .automatic, for: .windowToolbar)
        .environment(addToPlaylist)
        .duskPopUp(item: $bindableAddToPlaylist.target) { target in
            AddToPlaylistSheet(target: target, plexService: plexService)
        }
        .sheet(isPresented: homeUserPickerPresented) {
            HomeUserPickerView(
                users: plexService.homeUsers,
                rememberSelection: plexService.automaticHomeSignIn,
                onComplete: { router.isHomeUserPickerPresented = false },
                onCancel: { router.isHomeUserPickerPresented = false }
            )
            .frame(minWidth: 520, minHeight: 440)
        }
        .alert("Sign out of Plex?", isPresented: $bindableRouter.isSignOutConfirmationPresented) {
            Button("Sign Out", role: .destructive) {
                plexService.signOut()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            router.shellDidAppear(session: plexService.activeProfileID)
            router.updateDestinations(destinations)
        }
        .onDisappear {
            // Closing the window (or a profile switch) unmounts `MacPlayerView`
            // too, whose own `onDisappear` runs the iOS cover's `onDismiss`
            // teardown (`onPlayerDismissed`); it must not run twice.
            router.shellDidDisappear()
        }
        .onChange(of: destinations) { _, newDestinations in
            router.updateDestinations(newDestinations)
        }
        // Which destinations exist depends on the merged library list, so the
        // shell reloads it whenever the set of connected servers changes: it
        // mounts before the first server is connected.
        .task(id: plexService.serverContentRevision) {
            if librariesViewModel == nil {
                librariesViewModel = LibrariesViewModel(plexService: plexService)
            }
            await librariesViewModel?.loadLibraries()
        }
        // Live TV discovery on its own task, as in `MainTabView`.
        .task(id: plexService.serverContentRevision) {
            if liveTVViewModel == nil {
                liveTVViewModel = LiveTVViewModel(plexService: plexService, iptvService: iptvService)
            }
            iptvService.syncProfile()
            await liveTVViewModel?.discover()
        }
        // Playlists bring their destination in only when the account has one.
        .task(id: plexService.serverContentRevision) {
            await plexService.loadPlaylists()
        }
        // The shell remounts per Plex Home profile, so each profile's account
        // languages become the Audio & Subtitles defaults.
        .task {
            if let accountDefaults = await plexService.fetchAccountLanguageDefaults() {
                preferences.applyPlexAccountLanguageDefaults(accountDefaults)
            }
        }
        // Teaches Siri the recently watched and added titles; see `MainTabView`.
        .task(id: MacSiriCatalogRefreshTrigger(
            revision: plexService.serverContentRevision,
            isActive: scenePhase == .active,
            hiddenLibraryIDs: plexService.libraryOrder.hiddenSectionIdentities
        )) {
            guard scenePhase == .active else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await SiriTitleCatalog.shared.refreshIfNeeded(plexService: plexService)
        }
        .supporterPromptPresenter()
        #if DEBUG
        .task {
            await applyMacScreenshotDestination { librariesViewModel?.libraries ?? [] }
        }
        #endif
    }

    // MARK: - Split view

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar(
                contentDestinations: contentDestinations,
                showsDownloads: hasDownloads,
                selection: sidebarSelection
            )
        } detail: {
            destinationRoot(for: router.selection)
                // A new identity per destination (and per ⌘R) so a switch
                // shows that destination's own stack and Refresh loads anew.
                .id(MacDestinationIdentity(
                    destination: router.selection,
                    reload: router.reloadRevision(for: router.selection)
                ))
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebarSelection: Binding<MainTabItem> {
        Binding(
            get: { router.selection },
            set: { router.activate($0) }
        )
    }

    @ViewBuilder
    private func destinationRoot(for destination: MainTabItem) -> some View {
        switch destination {
        case .home:
            HomeView(
                path: router.pathBinding(for: .home),
                isSelected: router.selection == .home,
                liveTVViewModel: resolvedLiveTVViewModel
            )
        case .library(let libraryType):
            if let librariesViewModel {
                LibrariesView(
                    libraryType: libraryType,
                    viewModel: librariesViewModel,
                    path: router.pathBinding(for: destination)
                )
            } else {
                NavigationStack(path: router.pathBinding(for: destination)) {
                    ZStack {
                        Color.duskBackground.ignoresSafeArea()
                        FeatureLoadingView()
                    }
                }
            }
        case .liveTV:
            LiveTVView(viewModel: resolvedLiveTVViewModel, path: router.pathBinding(for: .liveTV))
        case .playlists:
            PlaylistsView(path: router.pathBinding(for: .playlists))
        case .downloads:
            DownloadsView(path: router.pathBinding(for: .downloads))
        case .search:
            SearchView(path: router.pathBinding(for: .search))
        case .settings, .more:
            // Never in the sidebar: Settings is its own scene on the Mac.
            EmptyView()
        }
    }

    // MARK: - Destinations

    /// Everything the sidebar lists, in order; the Go menu numbers these.
    private var destinations: [MainTabItem] {
        var items: [MainTabItem] = [.home, .search] + contentDestinations
        if hasDownloads {
            items.append(.downloads)
        }
        return items
    }

    /// The same derivation as `MainTabView.desiredAvailableTabs`: the library
    /// types the servers offer plus the data-driven destinations, filtered and
    /// ordered by the user's library tab preferences.
    private var contentDestinations: [MainTabItem] {
        let availableLibraryTypes = librariesViewModel?.availableLibraryTypes ?? [.movie, .show]
        return preferences.visibleLibraryTabs(from: availableLibraryTypes + dataDrivenTypes).map { type in
            switch type {
            case .liveTV: MainTabItem.liveTV
            case .playlists: MainTabItem.playlists
            default: MainTabItem.library(type)
            }
        }
    }

    /// Destinations that exist only while a server offers them: Live TV with
    /// a DVR or IPTV source, Playlists once the account has a video playlist.
    private var dataDrivenTypes: [PlexLibraryType] {
        var types: [PlexLibraryType] = []
        if liveTVViewModel?.isAvailable == true {
            types.append(.liveTV)
        }
        if plexService.playlists.hasPlaylists {
            types.append(.playlists)
        }
        return types
    }

    private var hasDownloads: Bool {
        DownloadsFeature.isVisible && !downloadManager.records.isEmpty
    }

    private var resolvedLiveTVViewModel: LiveTVViewModel {
        if let liveTVViewModel {
            return liveTVViewModel
        }
        return LiveTVViewModel(plexService: plexService, iptvService: iptvService)
    }

    private var homeUserPickerPresented: Binding<Bool> {
        Binding(
            get: { router.isHomeUserPickerPresented && plexService.hasPlexHome },
            set: { router.isHomeUserPickerPresented = $0 }
        )
    }
}

private struct MacDestinationIdentity: Hashable {
    let destination: MainTabItem
    let reload: Int
}

private struct MacSiriCatalogRefreshTrigger: Equatable {
    let revision: ServerContentRevision
    let isActive: Bool
    let hiddenLibraryIDs: Set<String>
}
#endif
