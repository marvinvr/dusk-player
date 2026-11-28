import Foundation

/// Jellyfin's `CatalogProviding` (docs/jellyfin/04-architecture.md §9,
/// 02 §2 – §7): `/UserViews`, `/Items` with the neutral sorts and filters
/// (`JellyfinBrowseVocabulary`), the A–Z table from `nameLessThan` counts,
/// `/Items/{id}`, `/Shows/{id}/Seasons`, person pages, `/LocalTrailers` +
/// `/SpecialFeatures` and one search request per result kind.
///
/// Collections listings and pages (J-07) still answer empty; the collection
/// *filter* works here, by BoxSet membership. Photo pages are `JellyfinPhotos`.
@MainActor
struct JellyfinCatalog: CatalogProviding {
    let serverID: String
    private let makeClient: @MainActor () throws -> JellyfinClient

    nonisolated init(server: JellyfinServerProvider) {
        serverID = server.descriptor.id
        makeClient = { try server.client() }
    }

    /// For tests: a client over a stub transport.
    nonisolated init(serverID: String, client: @escaping @MainActor () throws -> JellyfinClient) {
        self.serverID = serverID
        makeClient = client
    }

    private typealias Vocabulary = JellyfinBrowseVocabulary

    // MARK: - Libraries and browse

    /// The user's views that are libraries. A `homevideos` view holds either
    /// home videos or photos; it is classified once per launch by which it
    /// has more of (02 §2).
    func libraries() async throws -> [Library] {
        let client = try makeClient()
        let views = try await client.send(JellyfinAPI.userViews()).items
        var libraries: [Library] = []
        for view in views {
            var holdsPhotos = false
            if view.collectionType?.matches(.homeVideos) == true {
                holdsPhotos = try await homeVideosHoldPhotos(viewID: view.id, client: client)
            }
            if let library = JellyfinItemMapper.mapLibrary(view, serverID: serverID, homeVideosHoldPhotos: holdsPhotos) {
                libraries.append(library)
            }
        }
        return libraries
    }

    func items(
        libraryID: String,
        kind: LibraryKind?,
        start: Int,
        size: Int,
        sort: LibrarySortOption?,
        filter: LibraryFilter
    ) async throws -> [MediaItem] {
        let client = try makeClient()
        guard var query = try await baseQuery(libraryID: libraryID, kind: kind, filter: filter, client: client) else {
            return []
        }
        Vocabulary.apply(sort: sort, to: &query)
        query.startIndex = start
        query.limit = size
        query.enableTotalRecordCount = false
        return try await client.send(JellyfinAPI.items(query)).items
            .map { JellyfinItemMapper.map($0, serverID: serverID, libraryID: libraryID) }
    }

    func itemCount(libraryID: String, kind: LibraryKind?, filter: LibraryFilter) async throws -> Int {
        let client = try makeClient()
        guard let query = try await baseQuery(libraryID: libraryID, kind: kind, filter: filter, client: client) else {
            return 0
        }
        return try await count(query, client: client)
    }

    /// 26 `nameLessThan` counts in parallel, cached per listing until its
    /// total changes (one count request to check).
    func letterCounts(libraryID: String, kind: LibraryKind?, filter: LibraryFilter) async throws -> [LibraryLetterCount] {
        let client = try makeClient()
        guard let query = try await baseQuery(libraryID: libraryID, kind: kind, filter: filter, client: client) else {
            return []
        }
        let total = try await count(query, client: client)
        let cacheKey = JellyfinCatalogCache.key(serverID, client, query.queryItems.description)
        if let cached = JellyfinCatalogCache.letters[cacheKey], cached.total == total {
            return cached.rows
        }
        let below = try await withThrowingTaskGroup(of: (String, Int).self) { group in
            for letter in Vocabulary.letters {
                var bounded = query
                bounded.nameLessThan = letter
                group.addTask { (letter, try await Self.count(bounded, client: client)) }
            }
            var below: [String: Int] = [:]
            for try await (letter, value) in group { below[letter] = value }
            return below
        }
        let rows = Vocabulary.letterCounts(below: below, total: total)
        JellyfinCatalogCache.letters[cacheKey] = (total, rows)
        return rows
    }

    func sortFields(for kind: LibraryKind?) -> [LibrarySortField] {
        Vocabulary.sortFields(for: kind)
    }

    /// The fields Jellyfin can filter on; Collection only while the server
    /// has a collection this user sees.
    func filterFields(libraryID: String, includesCollection: Bool) async throws -> [LibraryFilterField] {
        let client = try makeClient()
        let kind = try await libraryKind(libraryID: libraryID, client: client)
        var offersCollection = includesCollection
        if includesCollection {
            var boxSets = JellyfinItemQuery()
            boxSets.recursive = true
            boxSets.includeItemTypes = [.boxSet]
            offersCollection = try await count(boxSets, client: client) > 0
        }
        return Vocabulary.filterParameters(for: kind, includesCollection: offersCollection)
            .map { Vocabulary.field($0, libraryID: libraryID, kind: kind) }
    }

    func filterChoices(for field: LibraryFilterField) async throws -> [LibraryFilterChoice] {
        guard case .values(let encoded) = field.kind,
              let source = Vocabulary.ChoiceSource(encoded: encoded) else { return [] }
        let client = try makeClient()
        let libraryID = source.libraryID
        switch source.parameter {
        case .decade, .year, .contentRating:
            let values = try await client.send(JellyfinAPI.itemFilters(parentID: libraryID))
            switch source.parameter {
            case .decade: return Vocabulary.decadeChoices(years: values.years ?? [])
            case .year: return Vocabulary.yearChoices(years: values.years ?? [])
            default:
                return (values.officialRatings ?? []).map { LibraryFilterChoice(value: $0, title: $0) }
            }
        case .resolution:
            return try await resolutionChoices(libraryID: libraryID, kind: source.kind, client: client)
        case .studio:
            return try await client.send(JellyfinAPI.studios(parentID: libraryID)).items.compactMap(Self.choice)
        case .director:
            return try await client.send(JellyfinAPI.persons(parentID: libraryID, personTypes: [.director]))
                .items.compactMap(Self.choice)
        case .actor:
            return try await client.send(JellyfinAPI.persons(parentID: libraryID, personTypes: [.actor]))
                .items.compactMap(Self.choice)
        case .collection:
            return try await collectionChoices(libraryID: libraryID, kind: source.kind, client: client)
        }
    }

    /// `/Genres` of the library; the value is the name `genres=` takes.
    func genreChoices(libraryID: String) async throws -> [LibraryFilterChoice] {
        let client = try makeClient()
        return try await client.send(JellyfinAPI.genres(parentID: libraryID)).items
            .compactMap { $0.name?.nilIfEmpty }
            .map { LibraryFilterChoice(value: $0, title: $0) }
    }

    // MARK: - Collections (J-07)

    /// Jellyfin has no channels: a video library is one grid.
    func channelCollections(libraryID: String) async throws -> [MediaCollection] { [] }

    func collections(libraryID: String, start: Int, size: Int) async throws -> MediaItemPage {
        MediaItemPage(items: [], totalSize: 0, start: start, requestedSize: size)
    }

    func collectionItems(collectionID: String, start: Int, size: Int, sort: LibrarySortOption?) async throws -> MediaItemPage {
        MediaItemPage(items: [], totalSize: 0, start: start, requestedSize: size)
    }

    func collection(itemID: String) async throws -> MediaItem? { nil }

    func collectionMode(libraryID: String) async -> LibraryCollectionMode { .showItems }

    // MARK: - Details and children

    /// `GET /Items/{id}` is the full item, with its skip markers (J-05,
    /// `JellyfinItemDetails`). `checkFiles` has no Jellyfin counterpart.
    func details(itemID: String, checkFiles: Bool) async throws -> MediaDetails {
        let client = try makeClient()
        async let markers = JellyfinItemDetails.markers(itemID: itemID, client: client)
        let dto = try await client.send(JellyfinAPI.item(id: itemID))
        var details = JellyfinItemMapper.mapDetails(dto, serverID: serverID, markers: await markers)
        if (dto.localTrailerCount ?? 0) == 0 {
            details.remoteTrailerURL = JellyfinItemMapper.remoteTrailerURL(dto)
        }
        return details
    }

    func seasons(showID: String) async throws -> [Season] {
        let client = try makeClient()
        return try await client.send(JellyfinAPI.seasons(seriesID: showID, fields: [.childCount, .recursiveItemCount, .dateCreated]))
            .items.map { JellyfinItemMapper.mapSeason($0, serverID: serverID) }
    }

    /// A season's own episodes in episode order. `/Items` takes the season
    /// alone, where `/Shows/{id}/Episodes` would need the show first.
    func episodes(seasonID: String) async throws -> [Episode] {
        try await episodes(parentID: seasonID, recursive: nil)
    }

    func allEpisodes(showID: String) async throws -> [Episode] {
        try await episodes(parentID: showID, recursive: true)
    }

    private func episodes(parentID: String, recursive: Bool?) async throws -> [Episode] {
        let client = try makeClient()
        var query = JellyfinItemQuery()
        query.parentID = parentID
        query.recursive = recursive
        query.includeItemTypes = [.episode]
        query.isMissing = false
        query.sortBy = [.parentIndexNumber, .indexNumber, .sortName]
        query.fields = [.overview, .dateCreated, .providerIDs]
        return try await client.send(JellyfinAPI.items(query)).items
            .map { JellyfinItemMapper.mapEpisode($0, serverID: serverID) }
    }

    // MARK: - People, extras, search

    func person(id: String) async throws -> PersonDetails {
        let client = try makeClient()
        return JellyfinItemMapper.mapPerson(try await client.send(JellyfinAPI.item(id: id)))
    }

    func personMedia(id: String) async throws -> [MediaItem] {
        let client = try makeClient()
        var query = JellyfinItemQuery()
        query.personIDs = [id]
        query.recursive = true
        query.includeItemTypes = [.movie, .series]
        query.fields = Vocabulary.listFields
        query.sortBy = [.productionYear, .sortName]
        query.sortOrders = [.descending, .ascending]
        return try await client.send(JellyfinAPI.items(query)).items
            .map { JellyfinItemMapper.map($0, serverID: serverID) }
    }

    /// Local trailers first, then the special features in the server's order.
    /// Theme videos are background loops, not extras.
    func extras(itemID: String) async throws -> [Extra] {
        let client = try makeClient()
        async let trailers = client.send(JellyfinAPI.localTrailers(itemID: itemID))
        async let features = client.send(JellyfinAPI.specialFeatures(itemID: itemID))
        let rows = try await trailers + features
        return rows.compactMap { dto in
            guard let kind = JellyfinItemMapper.extraKind(dto.extraType) else { return nil }
            return Extra(item: JellyfinItemMapper.map(dto, serverID: serverID), kind: kind)
        }
    }

    /// One request per group, as Plex's `/hubs/search` groups them (02 §7):
    /// films with videos (the facade splits videos into their own section),
    /// shows, episodes. Matching is on names; the server ranks nothing.
    func searchGroups(query: String) async throws -> [HomeRow] {
        let client = try makeClient()
        let serverID = serverID
        return try await withThrowingTaskGroup(of: (Int, HomeRow?).self) { group in
            for (index, spec) in JellyfinItemMapper.searchGroups.enumerated() {
                var request = JellyfinItemQuery()
                request.searchTerm = query
                request.recursive = true
                request.includeItemTypes = spec.types
                request.fields = Vocabulary.listFields
                request.limit = 10
                group.addTask {
                    let items = try await client.send(JellyfinAPI.items(request)).items
                        .map { JellyfinItemMapper.map($0, serverID: serverID) }
                    return (index, items.isEmpty ? nil : JellyfinItemMapper.searchRow(spec, items: items, serverID: serverID))
                }
            }
            var rows: [(Int, HomeRow)] = []
            for try await (index, row) in group {
                if let row { rows.append((index, row)) }
            }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Jellyfin ignores `anyProviderIdEquals` (02 §6): a title search
    /// (narrowed by kind and year), kept where a `ProviderIds` value matches.
    /// Without a title there is nothing to search by.
    func items(matching ids: ExternalIDs, kind: MediaKind?, title: String?, year: Int?) async throws -> [MediaItem] {
        guard let title = title?.nilIfEmpty, !ids.uris.isEmpty else { return [] }
        let client = try makeClient()
        var query = JellyfinItemQuery()
        query.searchTerm = title
        query.recursive = true
        query.includeItemTypes = JellyfinItemMapper.itemTypes(matching: kind)
        query.fields = Vocabulary.listFields
        if let year { query.years = [year] }
        let wanted = Set(JellyfinItemMapper.externalNamespaces.flatMap { namespace in
            ids.values(for: namespace).map { "\(namespace)://\($0.lowercased())" }
        })
        return try await client.send(JellyfinAPI.items(query)).items
            .map { JellyfinItemMapper.map($0, serverID: serverID) }
            .filter { item in item.guids.contains { wanted.contains($0.id.lowercased()) } }
    }

    /// Played titles newest first (`DatePlayed`), until one was last played
    /// before `since`. Jellyfin keeps the last play per title, not every
    /// play, and the token already names the user.
    func playbackHistory(
        libraryID: String,
        since: Date,
        limit: Int,
        pageSize: Int,
        accountID: Int?
    ) async throws -> [PlaybackHistoryEntry] {
        guard limit > 0 else { return [] }
        let client = try makeClient()
        let cutoff = Int(since.timeIntervalSince1970.rounded(.down))
        var entries: [PlaybackHistoryEntry] = []
        var start = 0
        while entries.count < limit {
            var query = JellyfinItemQuery()
            query.parentID = libraryID
            query.recursive = true
            query.includeItemTypes = [.movie, .episode, .video]
            query.sortBy = [.datePlayed]
            query.sortOrder = .descending
            query.startIndex = start
            query.limit = min(max(pageSize, 1), limit - entries.count)
            query.enableTotalRecordCount = false
            let page = try await client.send(JellyfinAPI.items(query)).items
            for dto in page {
                guard let entry = JellyfinItemMapper.historyEntry(dto, serverID: serverID, libraryID: libraryID),
                      let viewedAt = entry.viewedAt, viewedAt > cutoff else { return entries }
                entries.append(entry)
            }
            guard page.count == query.limit else { break }
            start += page.count
        }
        return entries
    }

    // MARK: - Photos (J-10)

    func photoPage(libraryID: String, query: PhotoQuery, start: Int, size: Int) async throws -> PhotoPage {
        try await JellyfinPhotos.page(libraryID: libraryID, query: query, start: start, size: size, serverID: serverID, client: makeClient())
    }

    // MARK: - Requests

    private func count(_ query: JellyfinItemQuery, client: JellyfinClient) async throws -> Int {
        try await Self.count(query, client: client)
    }

    /// The listing's size from a `limit=0` request.
    private nonisolated static func count(_ query: JellyfinItemQuery, client: JellyfinClient) async throws -> Int {
        var counted = query
        counted.fields = []
        counted.sortBy = []
        counted.sortOrders = []
        counted.startIndex = nil
        counted.limit = 0
        counted.enableTotalRecordCount = nil
        return try await client.send(JellyfinAPI.items(counted)).totalRecordCount ?? 0
    }

    /// The base listing, or nil when a picked collection has no titles at
    /// all (an empty `ids=` would not narrow anything).
    private func baseQuery(
        libraryID: String,
        kind: LibraryKind?,
        filter: LibraryFilter,
        client: JellyfinClient
    ) async throws -> JellyfinItemQuery? {
        var members: [String]?
        if let collectionID = filter.choices[Vocabulary.FilterParameter.collection.rawValue] {
            let ids = try await collectionMemberIDs(collectionID, client: client)
            guard !ids.isEmpty else { return nil }
            members = ids
        }
        return Vocabulary.baseQuery(libraryID: libraryID, kind: kind, filter: filter, collectionMembers: members)
    }

    /// The ids of a BoxSet's titles, cached for the launch.
    private func collectionMemberIDs(_ collectionID: String, client: JellyfinClient) async throws -> [String] {
        let cacheKey = JellyfinCatalogCache.key(serverID, client, collectionID)
        if let cached = JellyfinCatalogCache.collectionMembers[cacheKey] { return cached }
        var query = JellyfinItemQuery()
        query.parentID = collectionID
        query.enableImages = false
        let ids = try await client.send(JellyfinAPI.items(query)).items.map { JellyfinID.normalized($0.id) }
        JellyfinCatalogCache.collectionMembers[cacheKey] = ids
        return ids
    }

    /// The collections with at least one title in this library.
    private func collectionChoices(libraryID: String, kind: LibraryKind?, client: JellyfinClient) async throws -> [LibraryFilterChoice] {
        var query = JellyfinItemQuery()
        query.recursive = true
        query.includeItemTypes = [.boxSet]
        query.sortBy = [.sortName]
        let boxSets = try await client.send(JellyfinAPI.items(query)).items
        var choices: [LibraryFilterChoice] = []
        for boxSet in boxSets {
            guard let title = boxSet.name?.nilIfEmpty else { continue }
            let members = try await collectionMemberIDs(boxSet.id, client: client)
            guard !members.isEmpty else { continue }
            let inLibrary = Vocabulary.baseQuery(
                libraryID: libraryID, kind: kind, filter: LibraryFilter(), collectionMembers: members
            )
            if try await count(inLibrary, client: client) > 0 {
                choices.append(LibraryFilterChoice(value: JellyfinID.normalized(boxSet.id), title: title))
            }
        }
        return choices
    }

    /// Only the resolutions the library has titles in, as Plex lists them.
    private func resolutionChoices(libraryID: String, kind: LibraryKind?, client: JellyfinClient) async throws -> [LibraryFilterChoice] {
        var choices: [LibraryFilterChoice] = []
        for resolution in Vocabulary.Resolution.allCases {
            var filter = LibraryFilter()
            filter.choices = [Vocabulary.FilterParameter.resolution.rawValue: resolution.rawValue]
            let query = Vocabulary.baseQuery(libraryID: libraryID, kind: kind, filter: filter)
            if try await count(query, client: client) > 0 {
                choices.append(LibraryFilterChoice(value: resolution.rawValue, title: resolution.title))
            }
        }
        return choices
    }

    /// The kind of one of this user's libraries (`filterFields` gets only the
    /// id).
    private func libraryKind(libraryID: String, client: JellyfinClient) async throws -> LibraryKind? {
        let wanted = JellyfinID.normalized(libraryID)
        let cacheKey = JellyfinCatalogCache.key(serverID, client, "kind|\(wanted)")
        if let cached = JellyfinCatalogCache.libraryKinds[cacheKey] { return cached }
        let kind = try await libraries().first { $0.key == wanted }?.libraryType
        JellyfinCatalogCache.libraryKinds[cacheKey] = kind
        return kind
    }

    private func homeVideosHoldPhotos(viewID: String, client: JellyfinClient) async throws -> Bool {
        let cacheKey = JellyfinCatalogCache.key(serverID, client, "photos|\(JellyfinID.normalized(viewID))")
        if let cached = JellyfinCatalogCache.homeVideoPhotos[cacheKey] { return cached }
        func count(_ type: JellyfinItemKind) async throws -> Int {
            var query = JellyfinItemQuery()
            query.parentID = viewID
            query.recursive = true
            query.includeItemTypes = [type]
            return try await self.count(query, client: client)
        }
        async let photos = count(.photo)
        async let videos = count(.video)
        let holdsPhotos = try await photos > videos
        JellyfinCatalogCache.homeVideoPhotos[cacheKey] = holdsPhotos
        return holdsPhotos
    }

    private static func choice(_ dto: JellyfinItemDTO) -> LibraryFilterChoice? {
        guard let name = dto.name?.nilIfEmpty else { return nil }
        return LibraryFilterChoice(value: JellyfinID.normalized(dto.id), title: name)
    }
}

/// What the catalog remembers for the launch, per server and user: a
/// `JellyfinCatalog` is rebuilt on every access, so it cannot hold it.
/// Memory only; nothing is persisted.
@MainActor
enum JellyfinCatalogCache {
    static var letters: [String: (total: Int, rows: [LibraryLetterCount])] = [:]
    static var collectionMembers: [String: [String]] = [:]
    static var homeVideoPhotos: [String: Bool] = [:]
    static var libraryKinds: [String: LibraryKind?] = [:]

    static func key(_ serverID: String, _ client: JellyfinClient, _ rest: String) -> String {
        "\(serverID)|\(client.credentials?.userID ?? "")|\(rest)"
    }
}
