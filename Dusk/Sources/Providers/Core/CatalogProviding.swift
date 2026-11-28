import Foundation

/// Libraries, browse, details, children, people, extras, search, collections
/// and photos for one server (docs/jellyfin/04-architecture.md §9).
///
/// One value per server: everything comes back stamped with that server.
/// Hidden libraries, the cross-server merge, the alternates index and the
/// next/previous episode walk stay in the facade, which calls these verbs.
///
/// Sorts and filters are neutral values (`LibrarySortOption`, `LibraryFilter`);
/// each provider maps them onto its own query. The menus are built from what
/// the provider lists (`sortFields(for:)`, `filterFields(libraryID:…)`).
///
/// Main-actor isolated, where the facade and its request routing live.
///
/// A web-only trailer rides on `MediaDetails.remoteTrailerURL`; a local one
/// is an extra (04 §9, `trailer(item)`).
@MainActor
protocol CatalogProviding: Sendable {
    // MARK: Libraries and browse

    /// The server's libraries, in its own order.
    func libraries() async throws -> [Library]

    /// One page of a library listing. `sort` nil means the server's default
    /// order. `kind` is the library's, which decides how a watch-state filter
    /// applies (a show is unwatched while any episode is).
    func items(
        libraryID: String,
        kind: LibraryKind?,
        start: Int,
        size: Int,
        sort: LibrarySortOption?,
        filter: LibraryFilter
    ) async throws -> [MediaItem]

    /// How many titles the listing has under `filter`.
    func itemCount(libraryID: String, kind: LibraryKind?, filter: LibraryFilter) async throws -> Int

    /// The A–Z table of a title-sorted listing: how many titles start with
    /// each character, in ascending title-sort order.
    func letterCounts(libraryID: String, kind: LibraryKind?, filter: LibraryFilter) async throws -> [LibraryLetterCount]

    /// The sorts a library of `kind` offers, in menu order.
    func sortFields(for kind: LibraryKind?) -> [LibrarySortField]

    /// The Filters sheet's fields this library offers, in the sheet's order.
    /// `includesCollection` false leaves the collection field out.
    func filterFields(libraryID: String, includesCollection: Bool) async throws -> [LibraryFilterField]

    /// The values a `.values` field offers, in the server's order.
    func filterChoices(for field: LibraryFilterField) async throws -> [LibraryFilterChoice]

    /// The genres the grid's genre menu offers. Each `value` is what
    /// `LibraryFilter.genre` sends back.
    func genreChoices(libraryID: String) async throws -> [LibraryFilterChoice]

    // MARK: Collections

    /// A video library's channels: the collections its grid is browsed by.
    func channelCollections(libraryID: String) async throws -> [MediaCollection]

    /// One page of a library's collections.
    func collections(libraryID: String, start: Int, size: Int) async throws -> MediaItemPage

    /// One page of a collection's titles, in the collection's own order or
    /// in `sort` when given.
    func collectionItems(collectionID: String, start: Int, size: Int, sort: LibrarySortOption?) async throws -> MediaItemPage

    /// The collection itself (title, summary, artwork, count).
    func collection(itemID: String) async throws -> MediaItem?

    /// How the library shows its collections. Anything unreadable is the
    /// default (`.showItems`), so collections stay visible.
    func collectionMode(libraryID: String) async -> LibraryCollectionMode

    // MARK: Details and children

    /// An item with its versions, people, ratings and collections.
    /// `checkFiles` asks the server to check the backing files first, so a
    /// missing version is not chosen for playback.
    func details(itemID: String, checkFiles: Bool) async throws -> MediaDetails

    func seasons(showID: String) async throws -> [Season]

    func episodes(seasonID: String) async throws -> [Episode]

    /// Every episode of a show, across all its seasons.
    func allEpisodes(showID: String) async throws -> [Episode]

    // MARK: People, extras, search

    func person(id: String) async throws -> PersonDetails

    /// The titles a person appears in, unfiltered and unmerged.
    func personMedia(id: String) async throws -> [MediaItem]

    /// An item's local extras (trailers, featurettes, …), each playable.
    func extras(itemID: String) async throws -> [Extra]

    /// The server's search results, one group per kind as the server groups
    /// them. The facade drops hidden libraries and splits the groups into
    /// `SearchSection`s.
    func searchGroups(query: String) async throws -> [HomeRow]

    /// Titles of this server that are the title `ids` name: the point lookup
    /// of watchlist matching and movie copies (04 §6.2). `kind`, `title` and
    /// `year` narrow it; a server without an id lookup searches by them.
    func items(matching ids: ExternalIDs, kind: MediaKind?, title: String?, year: Int?) async throws -> [MediaItem]

    /// What the user watched in a library since `since`, newest first, at
    /// most `limit` entries read `pageSize` at a time. `accountID` names the
    /// server account whose history it is where the token alone does not.
    func playbackHistory(
        libraryID: String,
        since: Date,
        limit: Int,
        pageSize: Int,
        accountID: Int?
    ) async throws -> [PlaybackHistoryEntry]

    // MARK: Photos

    /// One page of a photo library query.
    func photoPage(libraryID: String, query: PhotoQuery, start: Int, size: Int) async throws -> PhotoPage
}

// MARK: - Request and result types

/// What a library listing is narrowed to. Every part is combined with AND.
/// Field ids and values are the ones the provider listed in
/// `filterFields(libraryID:…)` and `filterChoices(for:)`.
struct LibraryFilter: Hashable, Sendable {
    /// Only the titles of this collection (a video library's channel grid).
    var collectionID: String?
    /// A genre value the provider listed for the library.
    var genre: String?
    var watchStatus: LibraryWatchStatus = .all
    /// Picked values by field: `LibraryFilterField.parameter` →
    /// `LibraryFilterChoice.value`.
    var choices: [String: String] = [:]
    /// `.toggle` fields switched on, by `LibraryFilterField.parameter`.
    var toggles: Set<String> = []
    /// Shows a collection in place of the titles inside it (the library's
    /// "hide items in collections" mode, plain browse only).
    var foldsCollections = false

    init(
        collectionID: String? = nil,
        genre: String? = nil,
        watchStatus: LibraryWatchStatus = .all,
        choices: [String: String] = [:],
        toggles: Set<String> = [],
        foldsCollections: Bool = false
    ) {
        self.collectionID = collectionID
        self.genre = genre
        self.watchStatus = watchStatus
        self.choices = choices
        self.toggles = toggles
        self.foldsCollections = foldsCollections
    }
}

/// One row of a library's A–Z table: titles whose sort title starts with
/// `key`. Keys are the server's ("#", "%23" or the symbol itself for numbers
/// and symbols); `LibraryLetterIndex` folds them.
struct LibraryLetterCount: Hashable, Sendable {
    let key: String
    let size: Int
}

/// How a movie or TV library shows its collections.
enum LibraryCollectionMode: Sendable, Hashable {
    /// Collections are switched off for the library: nothing offers them.
    case disabled
    /// The library grid shows a collection in place of the titles inside it.
    case hideItems
    /// Collections and their titles both appear (the default).
    case showItems
}

/// One page of a paged listing, with the server's total when it sends one.
struct MediaItemPage: Sendable {
    let items: [MediaItem]
    let totalSize: Int?
    let start: Int
    let requestedSize: Int

    var hasMore: Bool {
        if let totalSize { return start + items.count < totalSize }
        return items.count >= requestedSize
    }
}

/// What a photo grid lists.
enum PhotoQuery: Hashable, Sendable {
    /// The albums directly inside `parent` (the library root when nil).
    case albums(parent: String?)
    /// The photos and clips directly inside `parent` (loose photos in the
    /// library root when nil), oldest first like an album.
    case media(parent: String?)
    /// Every photo and clip in the library, newest first.
    case timeline
}

/// One page of a photo library query and the size of the whole result.
struct PhotoPage: Sendable {
    let items: [PhotoItem]
    let totalSize: Int?
}
