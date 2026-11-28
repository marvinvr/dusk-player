import SwiftUI

/// Home's "Watchlist" row: the account's Plex Watchlist in Plex's order
/// (newest first). A title on a connected server is its server item (detail
/// page, progress, watched mark); one that is not opens Seerr or the light
/// Watchlist page. Renders nothing unless there is at least one title, so a
/// failed, empty or missing Watchlist leaves no trace on Home.
struct HomeWatchlistShelf: View {
    let viewModel: HomeViewModel
    let onMarkWatched: (MediaItem, Bool) -> Void

    static let title = "Watchlist"

    var body: some View {
        let entries = viewModel.watchlistEntries
        if !entries.isEmpty {
            let width = DuskPosterMetrics.carouselPosterWidth
            let imageWidth = Int((width * 2).rounded(.up))
            let imageHeight = Int((width * 3).rounded(.up))

            MediaCarousel(title: Self.title) {
                ForEach(entries) { entry in
                    card(entry, width: width, imageWidth: imageWidth, imageHeight: imageHeight)
                        .carouselItemFocusLock(isLeadingItem: entry.id == entries.first?.id)
                }
            }
        }
    }

    @ViewBuilder
    private func card(_ entry: WatchlistEntry, width: CGFloat, imageWidth: Int, imageHeight: Int) -> some View {
        if let item = viewModel.watchlistMatch(for: entry) {
            PosterNavigationCard(
                route: AppNavigationRoute.destination(for: item),
                imageURL: viewModel.posterURL(for: item, width: imageWidth, height: imageHeight),
                fallbackImageURL: entry.posterURL(width: imageWidth),
                title: item.posterCardTitle,
                subtitle: item.hubPosterSubtitle,
                progress: item.posterProgress,
                width: width,
                isWatched: item.posterIsWatched
            ) {
                MediaItemContextMenuContent(
                    item: item,
                    onMarkWatched: { onMarkWatched(item, true) },
                    onMarkUnwatched: { onMarkWatched(item, false) }
                )
            }
        } else {
            PosterNavigationCard(
                route: .watchlistItem(entry),
                imageURL: entry.posterURL(width: imageWidth),
                title: entry.title,
                subtitle: "Not on your servers",
                width: width
            ) {
                WatchlistMenuButton(entry: entry)
            }
        }
    }
}
