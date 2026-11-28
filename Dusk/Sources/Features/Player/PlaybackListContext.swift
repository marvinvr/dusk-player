import Foundation

/// A list of videos on screen that playback should continue through: the
/// grid of a Videos library or folder, a video library's row, a collection.
/// Carried by the navigation route into the item's page so its Play starts a
/// `PlaybackQueue` at that item (`queue(startingAt:)`) and Up Next follows the
/// list's current order. Only movies and videos join — episodes keep their
/// show's own next-episode behaviour.
struct PlaybackListContext: Hashable, Sendable {
    let title: String
    let items: [PlaybackQueueItem]

    init(title: String, items: [PlaybackQueueItem]) {
        self.title = title
        self.items = items
    }

    /// The movies and videos of `items`, in order; nil when there are fewer
    /// than two (nothing to continue to).
    init?(title: String, plexItems: [MediaItem]) {
        let items = plexItems
            .filter { Self.joins($0) }
            .map(PlaybackQueueItem.init(item:))
        guard items.count > 1 else { return nil }
        self.init(title: title, items: items)
    }

    static func joins(_ item: MediaItem) -> Bool {
        item.isClip || item.type == .movie
    }

    func queue(startingAt id: MediaItemID) -> PlaybackQueue? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return PlaybackQueue.list(title: title, items: items, startIndex: index)
    }

    static func == (lhs: PlaybackListContext, rhs: PlaybackListContext) -> Bool {
        lhs.title == rhs.title && lhs.items.map(\.id) == rhs.items.map(\.id)
    }

    /// Cheap on purpose: a route is hashed on every navigation.
    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(items.count)
        hasher.combine(items.first?.id)
    }
}

extension AppNavigationRoute {
    /// `destination(for:)`, except that a movie or video inside `list` opens
    /// its page knowing the list, so playing it continues through the rest.
    static func destination(for item: MediaItem, in list: PlaybackListContext?) -> Self {
        guard let list, PlaybackListContext.joins(item),
              list.items.contains(where: { $0.id == item.id }) else {
            return destination(for: item)
        }
        return item.isClip ? .videoInList(id: item.id, list: list) : .movieInList(id: item.id, list: list)
    }
}
