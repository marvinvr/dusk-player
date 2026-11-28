import Foundation

/// Jellyfin's `HomeProviding` (04 §11, 02 §4). Jellyfin has no hub API, so
/// every row is composed here from fixed queries (`JellyfinHomeRowSpec`):
///
/// - **Home**: one "Recently Added in {library}" row per film, TV and video
///   library that is not in the user's `LatestItemsExcludes`, from
///   `/Items/Latest`. Latest groups new episodes into their season or show and
///   honours the user's "hide played" setting; the row's expansion and Show
///   All read the same list, so the row never reshuffles.
/// - **Continue Watching**: `/UserItems/Resume` and `/Shows/NextUp` per
///   library (so every title carries its library), one entry per show, newest
///   first. A Next Up episode is dated by the last episode of its show the
///   user played, which is what Plex's On Deck shows too.
/// - **Library Recommended tab**: Continue Watching, Recently Released,
///   Recently Added, Top Rated / Top Unwatched and Recently Watched, the rows
///   Plex's `/hubs/sections/{id}` gives, with its conditions.
/// - **Dismiss**: clears the resume point (Jellyfin cannot hide and keep it)
///   and, for an episode, remembers it so Next Up leaves it out until the show
///   moves on (`JellyfinNextUpDismissals`).
/// - **Hide Row**: the library's id in `LatestItemsExcludes`, which other
///   Jellyfin apps honour too.
@MainActor
struct JellyfinHome: HomeProviding {
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

    private typealias Spec = JellyfinHomeRowSpec

    /// Items per row on Home, as Plex's `/hubs` sends them; Home expands
    /// Recently Added to what it shows.
    nonisolated static let homeRowCount = 12
    /// Resume and Next Up entries asked of each library.
    nonisolated static let continueWatchingCount = 20
    /// What Show All asks for: the whole row, like a Plex hub key without a
    /// size. Latest cannot page, so this is its ceiling.
    nonisolated static let showAllCount = 500
    /// Played episodes read to date the Next Up entries.
    nonisolated static let nextUpDatingCount = 100

    private nonisolated static let itemFields = JellyfinBrowseVocabulary.listFields + [.overview]

    // MARK: - Home

    func homeRows() async throws -> [HomeRow] {
        let client = try makeClient()
        async let configuration = client.send(JellyfinAPI.currentUserConfiguration())
        let libraries = try await homeLibraries()
        let excluded = Self.latestExcludes(in: try await configuration)
        let shown = libraries.filter { !excluded.contains($0.id) }
        let serverID = serverID
        return try await withThrowingTaskGroup(of: (Int, HomeRow?).self) { group in
            for (index, library) in shown.enumerated() {
                group.addTask {
                    let spec = Spec(row: .recentlyAdded, libraryKind: library.kind, libraryID: library.id)
                    let row = try await Self.row(spec, library: library, count: Self.homeRowCount,
                                                 client: client, serverID: serverID)
                    return (index, row)
                }
            }
            var rows: [(Int, HomeRow)] = []
            for try await (index, row) in group {
                if let row { rows.append((index, row)) }
            }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func continueWatching() async throws -> [MediaItem] {
        let client = try makeClient()
        let libraries = try await homeLibraries()
        return try await Self.continueWatching(in: libraries, count: Self.continueWatchingCount,
                                               client: client, serverID: serverID)
    }

    // MARK: - Library rows

    func libraryRows(libraryID: String, count: Int) async throws -> [HomeRow] {
        try await rows(Spec.libraryRows, libraryID: libraryID, count: count)
    }

    /// Continue Watching and Recently Added, the top of the tab.
    func promotedLibraryRows(libraryID: String, count: Int) async throws -> [HomeRow] {
        try await rows({ kind in Spec.libraryRows(for: kind).filter { $0 == .continueWatching || $0 == .recentlyAdded } },
                       libraryID: libraryID, count: count)
    }

    private func rows(
        _ rows: (LibraryKind) -> [Spec.Row],
        libraryID: String,
        count: Int
    ) async throws -> [HomeRow] {
        let client = try makeClient()
        guard let library = try await homeLibrary(libraryID) else { return [] }
        let specs = rows(library.kind).map { Spec(row: $0, libraryKind: library.kind, libraryID: library.id) }
        let serverID = serverID
        return try await withThrowingTaskGroup(of: (Int, HomeRow?).self) { group in
            for (index, spec) in specs.enumerated() {
                group.addTask {
                    (index, try await Self.row(spec, library: library, count: count, client: client, serverID: serverID))
                }
            }
            var built: [(Int, HomeRow)] = []
            for try await (index, row) in group {
                if let row { built.append((index, row)) }
            }
            return built.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Show All and Home's Recently Added expansion. `size` nil is the whole
    /// row (up to `showAllCount`).
    func rowItems(rowKey: String, start: Int, size: Int?) async throws -> [MediaItem] {
        guard let spec = Spec(key: rowKey) else { return [] }
        let client = try makeClient()
        let limit = size ?? Self.showAllCount
        return try await Self.items(for: spec, start: start, limit: limit, client: client, serverID: serverID)
    }

    // MARK: - Hiding rows

    func managedRows(libraryID: String) async throws -> [ManagedHub] {
        let client = try makeClient()
        async let configuration = client.send(JellyfinAPI.currentUserConfiguration())
        guard let library = try await homeLibrary(libraryID) else { return [] }
        let excluded = Self.latestExcludes(in: try await configuration)
        let spec = Spec(row: .recentlyAdded, libraryKind: library.kind, libraryID: library.id)
        return [spec.managedRow(onHome: !excluded.contains(library.id))]
    }

    /// Reads the user's `Configuration` fresh and changes only
    /// `LatestItemsExcludes`, so another app's (or Dusk's) change to the rest
    /// of it in the meantime is kept.
    func setManagedRow(_ row: ManagedHub, libraryID: String) async throws {
        let client = try makeClient()
        let configuration = try await client.send(JellyfinAPI.currentUserConfiguration())
        guard let updated = Self.configuration(configuration, showingLatestOf: libraryID, onHome: row.promotedToOwnHome) else {
            return
        }
        _ = try await client.send(JellyfinAPI.updateUserConfiguration(raw: updated))
    }

    /// Only Recently Added has a switch; the row's key names its library.
    func managedRow(for row: HomeRow, source: HomeRowSource, libraryIDs: [String]) async -> ManagedHomeRow? {
        guard source.serverID == serverID,
              let spec = (source.key ?? row.key).flatMap(Spec.init(key:)),
              spec.row == .recentlyAdded else { return nil }
        return ManagedHomeRow(serverID: serverID, sectionID: spec.libraryID, hub: spec.managedRow(onHome: true))
    }

    // MARK: - Continue Watching dismiss

    /// A resumable title loses its resume point; an episode is also kept out
    /// of Next Up until its show moves on.
    func dismissFromContinueWatching(itemID: String) async throws {
        let client = try makeClient()
        let item = try await client.send(JellyfinAPI.item(id: itemID))
        if (item.userData?.playbackPositionTicks?.rawValue ?? 0) > 0 {
            var update = JellyfinUserDataUpdateDTO()
            update.playbackPositionTicks = JellyfinTicks(0)
            _ = try await client.send(JellyfinAPI.updateUserData(itemID: itemID, update))
        }
        if item.type?.matches(.episode) == true, let seriesID = item.seriesID,
           let scope = Self.dismissalScope(serverID: serverID, client: client) {
            JellyfinNextUpDismissals.dismiss(episodeID: item.id, seriesID: seriesID, scope: scope)
        }
    }

    // MARK: - Building rows

    /// The film, TV and video libraries, in the server's order.
    private func homeLibraries() async throws -> [JellyfinHomeLibrary] {
        try await JellyfinCatalog(serverID: serverID, client: makeClient).libraries().compactMap { library in
            guard let kind = library.libraryType, Spec.hasHomeRow(kind) else { return nil }
            return JellyfinHomeLibrary(id: JellyfinID.normalized(library.key), title: library.title, kind: kind)
        }
    }

    private func homeLibrary(_ libraryID: String) async throws -> JellyfinHomeLibrary? {
        let id = JellyfinID.normalized(libraryID)
        return try await homeLibraries().first { $0.id == id }
    }

    /// One row of one library; nil when it holds nothing.
    private nonisolated static func row(
        _ spec: Spec,
        library: JellyfinHomeLibrary,
        count: Int,
        client: JellyfinClient,
        serverID: String
    ) async throws -> HomeRow? {
        let items: [MediaItem]
        if spec.row == .continueWatching {
            items = try await continueWatching(in: [library], count: count, client: client, serverID: serverID)
        } else {
            items = try await self.items(for: spec, start: 0, limit: count, client: client, serverID: serverID)
        }
        guard !items.isEmpty else { return nil }
        return spec.homeRow(items: items, libraryTitle: library.title, more: items.count >= count, serverID: serverID)
    }

    private nonisolated static func items(
        for spec: Spec,
        start: Int,
        limit: Int,
        client: JellyfinClient,
        serverID: String
    ) async throws -> [MediaItem] {
        let dtos: [JellyfinItemDTO]
        switch spec.row {
        case .continueWatching:
            guard start == 0 else { return [] }
            let library = JellyfinHomeLibrary(id: spec.libraryID, title: "", kind: spec.libraryKind)
            return try await continueWatching(in: [library], count: limit, client: client, serverID: serverID)
        case .recentlyAdded:
            // No paging: ask for everything up to the page's end.
            let latest = try await client.send(JellyfinAPI.latest(
                parentID: spec.libraryID, limit: start + limit, fields: itemFields))
            dtos = Array(latest.dropFirst(start))
        default:
            guard let query = spec.itemsQuery(start: start, limit: limit) else { return [] }
            let now = Date()
            dtos = try await client.send(JellyfinAPI.items(query)).items.filter { spec.keeps($0, now: now) }
        }
        return dtos.map { JellyfinItemMapper.map($0, serverID: serverID, libraryID: spec.libraryID) }
    }

    /// Resume ∪ Next Up of `libraries`, one entry per show, newest first.
    private nonisolated static func continueWatching(
        in libraries: [JellyfinHomeLibrary],
        count: Int,
        client: JellyfinClient,
        serverID: String
    ) async throws -> [MediaItem] {
        let fields = itemFields
        let lists = try await withThrowingTaskGroup(of: (Int, [JellyfinItemDTO], [JellyfinItemDTO]).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    async let resume = client.send(JellyfinAPI.resume(parentID: library.id, limit: count, fields: fields))
                    // Only TV has Next Up.
                    let nextUp = library.kind == .show
                        ? try await client.send(JellyfinAPI.nextUp(parentID: library.id, limit: count, fields: fields)).items
                        : []
                    return (index, try await resume.items, nextUp)
                }
            }
            var lists: [(Int, [JellyfinItemDTO], [JellyfinItemDTO])] = []
            for try await list in group { lists.append(list) }
            return lists.sorted { $0.0 < $1.0 }
        }

        var nextUp = lists.flatMap { $0.2 }
        if let scope = await dismissalScope(serverID: serverID, client: client) {
            nextUp = await JellyfinNextUpDismissals.filter(nextUp, scope: scope)
        }
        let showDates = nextUp.isEmpty ? [:] : try await lastPlayedByShow(client: client)

        var entries: [JellyfinContinueWatchingEntry] = []
        for (index, resume, _) in lists {
            let libraryID = libraries[index].id
            entries += resume.map { JellyfinContinueWatchingEntry(dto: $0, libraryID: libraryID, playedAt: $0.userData?.lastPlayedDate?.date) }
        }
        let libraryByItem = Dictionary(
            lists.flatMap { index, _, next in next.map { (JellyfinID.normalized($0.id), libraries[index].id) } },
            uniquingKeysWith: { first, _ in first }
        )
        entries += nextUp.map { dto in
            JellyfinContinueWatchingEntry(
                dto: dto,
                libraryID: libraryByItem[JellyfinID.normalized(dto.id)],
                playedAt: dto.seriesID.flatMap { showDates[JellyfinID.normalized($0)] }
            )
        }
        return JellyfinContinueWatchingEntry.ordered(entries).map { entry in
            let item = JellyfinItemMapper.map(entry.dto, serverID: serverID, libraryID: entry.libraryID)
            return entry.isNextUp ? item.lastPlayed(at: entry.playedAt) : item
        }
    }

    /// When the user last played an episode of each show (normalised series
    /// id → date), from their most recently played episodes.
    private nonisolated static func lastPlayedByShow(client: JellyfinClient) async throws -> [String: Date] {
        var query = JellyfinItemQuery()
        query.recursive = true
        query.includeItemTypes = [.episode]
        query.isPlayed = true
        query.sortBy = [.datePlayed]
        query.sortOrder = .descending
        query.limit = nextUpDatingCount
        query.enableTotalRecordCount = false
        query.enableImages = false
        var dates: [String: Date] = [:]
        for dto in try await client.send(JellyfinAPI.items(query)).items {
            guard let seriesID = dto.seriesID.map(JellyfinID.normalized),
                  let played = dto.userData?.lastPlayedDate?.date else { continue }
            dates[seriesID] = max(dates[seriesID] ?? played, played)
        }
        return dates
    }

    @MainActor
    private static func dismissalScope(serverID: String, client: JellyfinClient) -> String? {
        client.credentials.map { JellyfinNextUpDismissals.scope(serverID: serverID, userID: $0.userID) }
    }

    // MARK: - Configuration

    static func latestExcludes(in configuration: JellyfinJSONObject) -> Set<String> {
        Set((configuration["LatestItemsExcludes"]?.strings ?? []).map(JellyfinID.normalized))
    }

    /// `configuration` with `libraryID` taken out of (or put into)
    /// `LatestItemsExcludes`; nil when it already is as asked.
    static func configuration(
        _ configuration: JellyfinJSONObject,
        showingLatestOf libraryID: String,
        onHome: Bool
    ) -> JellyfinJSONObject? {
        let id = JellyfinID.normalized(libraryID)
        let current = configuration["LatestItemsExcludes"]?.strings ?? []
        let isExcluded = current.contains { JellyfinID.normalized($0) == id }
        guard isExcluded == onHome else { return nil }
        let updated = onHome ? current.filter { JellyfinID.normalized($0) != id } : current + [id]
        var configuration = configuration
        configuration["LatestItemsExcludes"] = .array(updated.map(JellyfinJSONValue.string))
        return configuration
    }
}

/// One Continue Watching candidate before mapping.
struct JellyfinContinueWatchingEntry: Sendable {
    let dto: JellyfinItemDTO
    let libraryID: String?
    let playedAt: Date?

    var isNextUp: Bool { (dto.userData?.playbackPositionTicks?.rawValue ?? 0) == 0 }

    /// Newest first; undated entries (a Next Up show last played long ago)
    /// after them in the server's order. One entry per show: its newest.
    static func ordered(_ entries: [JellyfinContinueWatchingEntry]) -> [JellyfinContinueWatchingEntry] {
        let sorted = entries.enumerated().sorted { lhs, rhs in
            switch (lhs.element.playedAt, rhs.element.playedAt) {
            case let (left?, right?) where left != right: return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
        var seenShows: Set<String> = []
        var seenItems: Set<String> = []
        return sorted.filter { entry in
            guard seenItems.insert(JellyfinID.normalized(entry.dto.id)).inserted else { return false }
            guard entry.dto.type?.matches(.episode) == true,
                  let seriesID = entry.dto.seriesID.map(JellyfinID.normalized) else { return true }
            return seenShows.insert(seriesID).inserted
        }
    }
}

/// A library Home has rows for: `Library.key` (normalised), title, kind.
struct JellyfinHomeLibrary: Sendable {
    let id: String
    let title: String
    let kind: LibraryKind
}

private extension MediaItem {
    /// The item dated `date` (a Next Up episode takes its show's last play).
    func lastPlayed(at date: Date?) -> MediaItem {
        guard let date else { return self }
        return MediaItem(
            serverID: serverID, itemID: itemID, key: key, type: type, subtype: subtype, libraryID: libraryID,
            title: title, editionTitle: editionTitle, summary: summary, studio: studio,
            contentRating: contentRating, year: year, originallyAvailableAt: originallyAvailableAt,
            thumb: thumb, art: art, banner: banner, clearLogo: clearLogo, rating: rating,
            audienceRating: audienceRating, duration: duration, playCount: playCount,
            resumeOffsetMs: resumeOffsetMs, lastPlayedAt: Int(date.timeIntervalSince1970.rounded(.down)),
            addedAt: addedAt, updatedAt: updatedAt, index: index, parentIndex: parentIndex,
            parentID: parentID, parentTitle: parentTitle, parentThumb: parentThumb,
            grandparentID: grandparentID, grandparentTitle: grandparentTitle,
            grandparentThumb: grandparentThumb, grandparentArt: grandparentArt,
            episodeCount: episodeCount, watchedEpisodeCount: watchedEpisodeCount, childCount: childCount,
            smart: smart, genres: genres, directors: directors, writers: writers, roles: roles,
            guid: guid, guids: guids
        )
    }
}
