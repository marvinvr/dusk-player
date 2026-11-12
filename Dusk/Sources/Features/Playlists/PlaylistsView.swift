import SwiftUI

/// The Playlists tab: the account's video playlists on every connected
/// server, as square cards with Plex's mosaic. Shown only while the account
/// has one (`MainTabView.dataDrivenTabTypes`).
struct PlaylistsView: View {
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            PlaylistsRootContent()
                .duskAppNavigationDestinations()
        }
    }
}

struct PlaylistsRootContent: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var renaming: PlexPlaylist?
    @State private var renameText = ""
    @State private var deleting: PlexPlaylist?
    @State private var actionError: String?

    private let horizontalPadding: CGFloat = DuskPosterMetrics.gridHorizontalPadding

    private var store: PlaylistStore { plexService.playlists }
    private var actions: PlaylistActions { PlaylistActions(plexService: plexService) }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if store.playlists.isEmpty {
                switch store.state {
                case .idle, .loading:
                    FeatureLoadingView()
                case .failed(let message):
                    FeatureErrorView(message: message) {
                        Task { await plexService.loadPlaylists(force: true) }
                    }
                case .loaded:
                    FeatureEmptyStateView(
                        systemImage: PlexLibraryType.playlists.systemImage,
                        title: "No playlists",
                        message: "Long-press any movie or episode and choose Add to Playlist."
                    )
                    .padding(.horizontal, 24)
                }
            } else {
                grid
            }
        }
        .duskNavigationTitle("Playlists")
        .duskNavigationBarTitleDisplayModeLarge()
        .task {
            await plexService.loadPlaylists()
        }
        // `presenting:` hands the playlist to the button: dismissing the alert
        // clears `renaming`/`deleting` before the button's action runs.
        .alert("Rename Playlist", isPresented: renameBinding, presenting: renaming) { playlist in
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let title = renameText
                Task { await rename(playlist, to: title) }
            }
        }
        .confirmationDialog(
            deleting.map { "Delete “\($0.title)”?" } ?? "",
            isPresented: deleteBinding,
            titleVisibility: .visible,
            presenting: deleting
        ) { playlist in
            Button("Delete Playlist", role: .destructive) {
                Task { await delete(playlist) }
            }
        } message: { _ in
            Text("This removes the playlist from Plex on every device. The movies and episodes in it stay in your library.")
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
            let layout = AdaptivePosterGridLayout.make(
                containerWidth: geometry.size.width,
                horizontalPadding: horizontalPadding,
                gridSpacing: DuskPosterMetrics.gridSpacing,
                preferredPosterWidth: DuskPosterMetrics.gridPreferredWidth * 1.3,
                minimumColumnCount: 2
            )

            ScrollView {
                LazyVGrid(columns: layout.columns, spacing: DuskPosterMetrics.gridRowSpacing) {
                    ForEach(store.playlists) { playlist in
                        card(playlist, width: layout.posterWidth)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .refreshable {
                await plexService.loadPlaylists(force: true)
            }
        }
    }

    private func card(_ playlist: PlexPlaylist, width: CGFloat) -> some View {
        let side = Int(width.rounded(.up))
        return PosterNavigationCard(
            route: .playlist(id: playlist.id),
            imageURL: plexService.imageURL(
                for: playlist.artworkPath,
                serverID: playlist.serverID,
                width: side,
                height: side
            ),
            title: playlist.title,
            subtitle: subtitle(for: playlist),
            width: width,
            imageAspectRatio: 1
        ) {
            Button {
                Task { await play(playlist, shuffled: false) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button {
                Task { await play(playlist, shuffled: true) }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            PinPlaylistToHomeButton(playlist: playlist)
            if !playlist.smart {
                Button {
                    renameText = playlist.title
                    renaming = playlist
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            Button(role: .destructive) {
                deleting = playlist
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// `12 items · 18 h`, `· Smart` for smart playlists, and the server's
    /// name only when playlists come from more than one server.
    private func subtitle(for playlist: PlexPlaylist) -> String? {
        var parts: [String] = []
        if let count = playlist.leafCount {
            parts.append(count == 1 ? "1 item" : "\(count) items")
        }
        if let duration = MediaTextFormatter.compactDuration(milliseconds: playlist.duration) {
            parts.append(duration)
        }
        if playlist.smart {
            parts.append("Smart")
        }
        if store.spansMultipleServers, let serverID = playlist.serverID {
            parts.append(plexService.pool.displayName(for: serverID))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func play(_ playlist: PlexPlaylist, shuffled: Bool) async {
        do {
            guard let queue = try await actions.queue(for: playlist, shuffled: shuffled).queue else {
                actionError = "“\(playlist.title)” has nothing Dusk can play."
                return
            }
            await playback.playQueue(queue, fromStart: shuffled)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func rename(_ playlist: PlexPlaylist, to title: String) async {
        do {
            _ = try await actions.rename(playlist, to: title)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func delete(_ playlist: PlexPlaylist) async {
        do {
            try await actions.delete(playlist)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }
}
