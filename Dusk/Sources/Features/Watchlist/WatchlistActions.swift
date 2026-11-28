import SwiftUI

/// Adds a title to the Watchlist or takes it off, for the hero bookmark and
/// the context menus. The store changes at once and is put back if the
/// account's service refuses (`MediaService.setWatchlisted`).
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
/// `bookmark.fill`). Absent until the Watchlist is known, and for titles the
/// account cannot list (on Plex: no `plex://` id, such as legacy agents and
/// personal media).
struct WatchlistHeroButton: View {
    @Environment(MediaService.self) private var media
    @State private var error: String?

    private let entry: WatchlistEntry?
    private let details: MediaDetails?

    /// A title that is on no server (Seerr, the light Watchlist page).
    init(entry: WatchlistEntry?) {
        self.entry = entry
        self.details = nil
    }

    /// A server movie or show; the account says whether it can be listed.
    init(details: MediaDetails?) {
        self.entry = nil
        self.details = details
    }

    var body: some View {
        if let entry = entry ?? details.flatMap(media.watchlistEntry(for:)),
           let isWatchlisted = media.watchlist.contains(guid: entry.guid) {
            Button {
                Task {
                    do {
                        try await WatchlistActions.toggle(entry: entry, match: nil, media: media)
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

    private let entry: WatchlistEntry?
    private let match: MediaItem?

    init(entry: WatchlistEntry?, match: MediaItem? = nil) {
        self.entry = entry
        self.match = match
    }

    /// A server movie or show; the account says whether it can be listed.
    init(item: MediaItem) {
        self.init(entry: nil, match: item)
    }

    var body: some View {
        if let entry = entry ?? match.flatMap(media.watchlistEntry(for:)),
           let isWatchlisted = media.watchlist.contains(guid: entry.guid) {
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
