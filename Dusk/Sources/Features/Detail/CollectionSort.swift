import Foundation

/// Sorting a collection's titles. A collection opens in its own order (the
/// server's Collection Sort setting: release date, alphabetical or custom),
/// which is why no sort is the default; the other choices reuse the library
/// grid's fields that make sense across a collection's titles.
///
/// Plex is asked to sort `/children` (`sort=`). Whether a server honours that
/// on a collection is checked against the first page; one that ignores it
/// gets every title loaded and sorted here instead.
enum CollectionSort {
    static let defaultTitle = "Collection Order"

    static func fields(forSubtype subtype: String?) -> [LibrarySortField] {
        switch subtype {
        case "clip":
            [.releaseDate, .addedAt, .title]
        default:
            [.releaseDate, .title, .addedAt, .criticRating, .audienceRating]
        }
    }

    /// Whether `items` (a server page) are already in `sort`'s order. Titles
    /// missing the value are skipped, and a few inversions are tolerated
    /// (Plex's collation of titles differs slightly from ours); a server
    /// that ignored the sort leaves about half the neighbours out of order.
    static func follows(_ items: [MediaItem], sort: LibrarySortOption) -> Bool {
        let keys = items.compactMap { key(for: $0, field: sort.field) }
        guard keys.count > 2 else { return true }
        var inversions = 0
        for (lhs, rhs) in zip(keys, keys.dropFirst()) {
            let order = lhs.compare(to: rhs)
            if sort.isDescending ? order == .orderedAscending : order == .orderedDescending {
                inversions += 1
            }
        }
        return Double(inversions) <= Double(keys.count - 1) * 0.1
    }

    /// `items` in `sort`'s order; titles missing the value go last, and
    /// ties keep the collection's order.
    static func sorted(_ items: [MediaItem], by sort: LibrarySortOption) -> [MediaItem] {
        if sort.field == .random { return items.shuffled() }
        let keyed = items.enumerated().map { (offset: $0.offset, item: $0.element, key: key(for: $0.element, field: sort.field)) }
        return keyed.sorted { lhs, rhs in
            switch (lhs.key, rhs.key) {
            case let (l?, r?):
                let order = l.compare(to: r)
                if order == .orderedSame { return lhs.offset < rhs.offset }
                return sort.isDescending ? order == .orderedDescending : order == .orderedAscending
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }
        .map(\.item)
    }

    private static func key(for item: MediaItem, field: LibrarySortField) -> SortKey? {
        switch field {
        case .title:
            return .text(titleSortKey(item.title))
        case .releaseDate:
            if let date = item.originallyAvailableAt?.nilIfEmpty { return .text(date) }
            return item.year.map { .text(String(format: "%04d", $0)) }
        case .year:
            return item.year.map { .number(Double($0)) }
        case .addedAt:
            return item.addedAt.map { .number(Double($0)) }
        case .criticRating:
            return item.rating.map(SortKey.number)
        case .audienceRating:
            return item.audienceRating.map(SortKey.number)
        case .duration:
            return item.duration.map { .number(Double($0)) }
        case .lastViewed:
            return item.lastViewedAt.map { .number(Double($0)) }
        case .userRating, .lastEpisodeAdded, .random:
            return nil
        }
    }

    /// Plex sorts titles without a leading English article ("The Incredibles"
    /// under I).
    static func titleSortKey(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for article in ["the ", "a ", "an "] where folded.hasPrefix(article) && folded.count > article.count {
            return String(folded.dropFirst(article.count))
        }
        return folded
    }

    private enum SortKey {
        case text(String)
        case number(Double)

        func compare(to other: SortKey) -> ComparisonResult {
            switch (self, other) {
            case let (.text(l), .text(r)):
                return l.localizedStandardCompare(r)
            case let (.number(l), .number(r)):
                return l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
            default:
                return .orderedSame
            }
        }
    }
}

/// Remembers the sort picked per collection (server and rating key),
/// device-local like the library grids' sort. Nothing stored is the
/// collection's own order.
struct CollectionSortStore {
    static let keyPrefix = "collectionSort."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func sort(for id: MediaItemID) -> LibrarySortOption? {
        defaults.string(forKey: Self.key(for: id)).flatMap(LibrarySortOption.init(rawValue:))
    }

    func setSort(_ sort: LibrarySortOption?, for id: MediaItemID) {
        if let sort {
            defaults.set(sort.rawValue, forKey: Self.key(for: id))
        } else {
            defaults.removeObject(forKey: Self.key(for: id))
        }
    }

    static func key(for id: MediaItemID) -> String {
        "\(keyPrefix)\(id.serverID ?? "")|\(id.ratingKey)"
    }
}
