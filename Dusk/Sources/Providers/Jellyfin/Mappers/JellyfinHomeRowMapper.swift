import Foundation

/// The rows Jellyfin's Home and library Recommended tabs get (04 §11). The
/// server has no hub API, so each row is a fixed query; this file names them
/// and turns their items into `HomeRow`s.
///
/// Identifier, title and type are the ones Plex gives the same row of a
/// library of that kind (`movie.recentlyadded.<section>`, "Recently Added in
/// Movies", `movie`; plex-demo `/hubs/sections/{id}`), so `mergeKey` and the
/// library tab's row handling treat both servers' rows alike, and a mixed
/// account (J-13) merges them. Only Recently Added has a Home switch
/// (`LatestItemsExcludes`).
struct JellyfinHomeRowSpec: Hashable, Sendable {
    enum Row: String, CaseIterable, Sendable {
        case continueWatching
        case recentlyReleased
        case recentlyAdded
        case topRated
        case recentlyWatched
    }

    let row: Row
    let libraryKind: LibraryKind
    /// `Library.key`: the normalised view id.
    let libraryID: String

    /// The rows a library's Recommended tab shows, in Plex's order.
    static func libraryRows(for kind: LibraryKind) -> [Row] {
        switch kind {
        case .movie, .show: Row.allCases
        case .video: [.continueWatching, .recentlyAdded, .recentlyWatched]
        default: []
        }
    }

    /// Libraries with a Recently Added row on Home and in Hidden Rows.
    static func hasHomeRow(_ kind: LibraryKind) -> Bool {
        [.movie, .show, .video].contains(kind)
    }

    // MARK: Row key

    /// `HomeRow.key` / `HomeRowSource.key`: what `rowItems` pages.
    private static let keyPrefix = "jellyfin-row"

    var key: String {
        [Self.keyPrefix, row.rawValue, libraryKind.rawValue, libraryID].joined(separator: "/")
    }

    init(row: Row, libraryKind: LibraryKind, libraryID: String) {
        self.row = row
        self.libraryKind = libraryKind
        self.libraryID = libraryID
    }

    init?(key: String) {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == Self.keyPrefix,
              let row = Row(rawValue: parts[1]),
              let kind = LibraryKind(rawValue: parts[2]),
              !parts[3].isEmpty else { return nil }
        self.init(row: row, libraryKind: kind, libraryID: parts[3])
    }

    // MARK: Plex's names for the row

    private var typePrefix: String {
        switch libraryKind {
        case .show: "tv"
        case .video: "video"
        default: "movie"
        }
    }

    /// Plex's hub identifier without the section suffix.
    var identifier: String {
        let name = switch (row, libraryKind) {
        case (.continueWatching, _): "inprogress"
        case (.recentlyReleased, .show): "recentlyaired"
        case (.recentlyReleased, _): "recentlyreleased"
        case (.recentlyAdded, .video): "recent"
        case (.recentlyAdded, _): "recentlyadded"
        case (.topRated, .show): "toprated"
        case (.topRated, _): "topunwatched"
        case (.recentlyWatched, _): "recentlyviewed"
        }
        return "\(typePrefix).\(name)"
    }

    func title(libraryTitle: String) -> String {
        switch (row, libraryKind) {
        case (.continueWatching, _): "Continue Watching"
        case (.recentlyReleased, .show): "Recently Released Episodes"
        case (.recentlyReleased, _): "Recently Released Movies"
        case (.recentlyAdded, _): "Recently Added in \(libraryTitle)"
        case (.topRated, .show): "Top Rated TV"
        case (.topRated, _): "Top Unwatched Movies"
        case (.recentlyWatched, .show): "Recently Watched Episodes"
        case (.recentlyWatched, .video): "Recently Watched Videos"
        case (.recentlyWatched, _): "Recently Watched Movies"
        }
    }

    /// Plex's hub `type`, part of `mergeKey`.
    var type: String {
        switch (row, libraryKind) {
        case (_, .video): "clip"
        case (.recentlyAdded, .show): "mixed"
        case (.topRated, .show): "show"
        case (_, .show): "episode"
        default: "movie"
        }
    }

    var kind: HomeRow.Kind {
        switch row {
        case .continueWatching: .continueWatching
        case .recentlyAdded: .recentlyAdded
        default: .other
        }
    }

    // MARK: Queries

    /// The `/Items` listing behind a row that is one; Continue Watching
    /// (Resume + Next Up) and Recently Added (`/Items/Latest`) are not.
    func itemsQuery(start: Int, limit: Int) -> JellyfinItemQuery? {
        var query = JellyfinItemQuery()
        query.parentID = libraryID
        query.recursive = true
        query.fields = JellyfinBrowseVocabulary.listFields
        query.startIndex = start > 0 ? start : nil
        query.limit = limit
        query.enableTotalRecordCount = false
        switch row {
        case .continueWatching, .recentlyAdded:
            return nil
        case .recentlyReleased:
            query.includeItemTypes = libraryKind == .show ? [.episode] : [.movie]
            query.isMissing = libraryKind == .show ? false : nil
            query.sortBy = [.premiereDate, .sortName]
            query.sortOrders = [.descending, .ascending]
        case .topRated:
            query.includeItemTypes = libraryKind == .show ? [.series] : [.movie]
            query.isPlayed = false
            query.sortBy = [.communityRating, .sortName]
            query.sortOrders = [.descending, .ascending]
        case .recentlyWatched:
            query.includeItemTypes = switch libraryKind {
            case .show: [.episode]
            case .video: [.video]
            default: [.movie]
            }
            query.isPlayed = true
            query.sortBy = [.datePlayed]
            query.sortOrder = .descending
        }
        return query
    }

    /// Plex's conditions the query cannot state: Recently Released Movies is
    /// the last year (`originallyAvailableAt>=-1y`), the top row rated 7 or
    /// more. Both lists are sorted on that field, so this cuts a tail.
    func keeps(_ dto: JellyfinItemDTO, now: Date) -> Bool {
        switch row {
        case .recentlyReleased where libraryKind != .show:
            guard let released = dto.premiereDate?.date else { return false }
            return released >= now.addingTimeInterval(-365 * 24 * 3600)
        case .topRated:
            return (dto.communityRating ?? 0) >= 7
        default:
            return true
        }
    }

    // MARK: Rows

    func homeRow(items: [MediaItem], libraryTitle: String, more: Bool, serverID: String) -> HomeRow {
        let identifier = "\(identifier).\(libraryID)"
        return HomeRow(
            key: key,
            title: title(libraryTitle: libraryTitle),
            type: type,
            hubIdentifier: identifier,
            size: items.count,
            more: more,
            libraryID: libraryID,
            librarySectionTitle: libraryTitle,
            items: items,
            kind: kind,
            libraryScope: .section(libraryID),
            mergeKey: "id:\(self.identifier)|\(type)",
            canHide: row == .recentlyAdded,
            serverID: serverID,
            sources: [HomeRowSource(serverID: serverID, key: key, size: items.count, more: more, hubIdentifier: identifier)]
        )
    }

    /// The entry in Settings › Home › Hidden Rows.
    func managedRow(onHome: Bool) -> ManagedHub {
        ManagedHub(identifier: identifier, title: "Recently Added", promotedToOwnHome: onHome)
    }
}
