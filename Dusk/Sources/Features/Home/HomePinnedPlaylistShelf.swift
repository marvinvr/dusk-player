import SwiftUI

/// A playlist pinned to Home: its items as ordinary posters, in playlist
/// order. Selecting one plays the playlist from there, like the playlist
/// page; Show All opens the playlist page.
struct HomePinnedPlaylistRow: Identifiable, Equatable {
    let id: PlexItemID
    let title: String
    let entries: [PlexPlaylistEntry]

    /// A playlist can hold a title twice; a row shows each item once.
    var items: [PlexItem] {
        // Eager on purpose: a lazy filter may run its predicate more than
        // once per element, and `insert` would reject the second pass.
        var seen: Set<PlexItemID> = []
        var items: [PlexItem] = []
        for entry in entries where items.count < Self.inlineLimit && seen.insert(entry.item.id).inserted {
            items.append(entry.item)
        }
        return items
    }

    var showsAll: Bool {
        entries.count > items.count
    }

    static let inlineLimit = 30
}

struct HomePinnedPlaylistShelf: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback

    let row: HomePinnedPlaylistRow
    let viewModel: HomeViewModel

    var body: some View {
        PlexItemActionCarouselSection(
            title: row.title,
            items: row.items,
            action: play,
            posterWidth: DuskPosterMetrics.carouselPosterWidth,
            imageAspectRatio: 2.0 / 3.0,
            showAllRoute: row.showsAll ? .playlist(id: row.id) : nil,
            subtitle: { $0.hubPosterSubtitle },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            }
        ) { item in
            Button {
                play(item)
            } label: {
                Label("Play from Here", systemImage: "play.fill")
            }

            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                },
                detailsRoute: AppNavigationRoute.destination(for: item),
                detailsLabel: "Go to Details",
                showsAddToPlaylist: false
            )

            NavigationLink(value: AppNavigationRoute.playlist(id: row.id)) {
                Label("Go to Playlist", systemImage: PlexLibraryType.playlists.systemImage)
            }

            Button {
                plexService.setPlaylistPinned(false, id: row.id, title: row.title)
            } label: {
                Label("Unpin from Home", systemImage: "pin.slash")
            }
        }
    }

    /// Plays the playlist from this item on, like selecting it on the
    /// playlist page.
    private func play(_ item: PlexItem) {
        guard let index = row.entries.firstIndex(where: { $0.item.id == item.id }),
              let queue = PlaybackQueue.playlist(
                id: row.id,
                title: row.title,
                items: row.entries.map { PlaybackQueueItem(item: $0.item) },
                startIndex: index
              ) else { return }
        Task { await playback.playQueue(queue) }
    }
}
