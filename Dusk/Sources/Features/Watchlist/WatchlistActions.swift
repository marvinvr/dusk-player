import SwiftUI

/// Adds a title to the Plex Watchlist or takes it off, for the hero bookmark
/// and the context menus. The store changes at once and is put back if
/// plex.tv refuses (`MediaService.setWatchlisted`).
@MainActor
enum WatchlistActions {
    static func toggle(
        entry: WatchlistEntry,
        match: MediaItem?,
        media: MediaService
    ) async throws {
        let isWatchlisted = media.watchlist.contains(guid: entry.guid) ?? false
        try await media.setWatchlisted(!isWatchlisted, entry: entry, match: match)
    }

    static func menuTitle(isWatchlisted: Bool) -> String {
        isWatchlisted ? "Remove from Watchlist" : "Add to Watchlist"
    }

    static func systemImage(isWatchlisted: Bool) -> String {
        isWatchlisted ? "bookmark.slash" : "bookmark"
    }
}

/// The icon-only hero action on movie and show pages (`bookmark` /
/// `bookmark.fill`). Absent until the Watchlist is known, and for items with
/// no Plex id (legacy agents, personal media), which Plex cannot watchlist.
struct WatchlistHeroButton: View {
    @Environment(MediaService.self) private var media
    @State private var error: String?

    let entry: WatchlistEntry?
    var match: MediaItem? = nil

    var body: some View {
        if let entry, let isWatchlisted = media.watchlist.contains(guid: entry.guid) {
            Button {
                Task {
                    do {
                        try await WatchlistActions.toggle(entry: entry, match: match, media: media)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            } label: {
                DetailHeroSecondaryIconLabel(systemImage: isWatchlisted ? "bookmark.fill" : "bookmark", title: isWatchlisted ? "Remove from Watchlist" : "Add to Watchlist")
            }
            .detailHeroNativeSecondaryButtonStyle()
            .accessibilityLabel(isWatchlisted ? "Remove from Watchlist" : "Add to Watchlist")
            .alert(
                "Couldn’t Update Watchlist",
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }
}

/// The context-menu entry for a watchlist entry or a server movie/show.
struct WatchlistMenuButton: View {
    @Environment(MediaService.self) private var media

    let entry: WatchlistEntry?
    var match: MediaItem? = nil

    init(entry: WatchlistEntry?, match: MediaItem? = nil) {
        self.entry = entry
        self.match = match
    }

    init(item: MediaItem) {
        self.init(entry: WatchlistEntry(item: item), match: item)
    }

    var body: some View {
        if let entry, let isWatchlisted = media.watchlist.contains(guid: entry.guid) {
            Button {
                Task { try? await WatchlistActions.toggle(entry: entry, match: match, media: media) }
            } label: {
                Label(
                    WatchlistActions.menuTitle(isWatchlisted: isWatchlisted),
                    systemImage: WatchlistActions.systemImage(isWatchlisted: isWatchlisted)
                )
            }
        }
    }
}
