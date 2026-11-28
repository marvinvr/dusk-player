import Foundation

/// Where the Watchlist row sits among Home's arranged hubs.
///
/// The row is always below the hero / Continue Watching (and Live TV): the
/// result is an index into `hubs` only, never above them.
///
/// - Plex's own Home layout wins when the account customized it (Plex Web's
///   `homeSettings.hubs`): hidden there means hidden here, and otherwise the
///   row follows the nearest row before it in Plex's list that Home also
///   shows. With none of those before it, it leads the hubs.
/// - Otherwise it goes after the last Recently Added hub. Those rows lead
///   each library block, so this sits after every library's Recently Added.
///   With none, it goes after the Plex hubs, before Dusk's personalized
///   shelves.
///
/// Hubs are already in the account's library order (`HomeHubArrangement`),
/// so anchoring to a hub follows Library Order too.
enum HomeWatchlistPlacement {
    /// The index in `hubs` the row is inserted before (`hubs.count` = after
    /// every hub), or nil when Plex's layout hides the Watchlist.
    static func index(in hubs: [HomeRow], homeLayoutHubs: [HomeLayoutHub]?) -> Int? {
        if let homeLayoutHubs, let position = homeLayoutHubs.firstIndex(where: \.isWatchlist) {
            if homeLayoutHubs[position].isHidden { return nil }
            for preceding in homeLayoutHubs[..<position].reversed() where !preceding.isHidden {
                if let anchor = hubs.firstIndex(where: { matches($0, preceding) }) {
                    return anchor + 1
                }
            }
            return 0
        }
        return defaultIndex(in: hubs)
    }

    /// Index in `hubs` the row is inserted before. `hubs.count` is after every
    /// Plex hub (and before the personalized shelves, which are not in `hubs`).
    static func defaultIndex(in hubs: [HomeRow]) -> Int {
        guard let lastRecentlyAdded = hubs.lastIndex(where: isRecentlyAdded) else {
            return hubs.count
        }
        return lastRecentlyAdded + 1
    }

    private static func isRecentlyAdded(_ hub: HomeRow) -> Bool {
        [hub.hubIdentifier, hub.key].contains { $0?.lowercased().contains("recentlyadded") == true }
    }

    private static func matches(_ hub: HomeRow, _ setting: HomeLayoutHub) -> Bool {
        // A merged row carries its representative server's identifier; the
        // other servers' copies of the row cannot be told apart from it.
        guard hub.hubIdentifier == setting.hubIdentifier else { return false }
        guard let machineIdentifier = setting.machineIdentifier else { return true }
        return hub.serverID == machineIdentifier || hub.sources.contains { $0.serverID == machineIdentifier }
    }
}
