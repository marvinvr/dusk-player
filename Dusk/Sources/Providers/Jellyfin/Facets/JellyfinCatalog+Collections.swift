import Foundation

/// Jellyfin's collections (docs/jellyfin/02-jellyfin-api-mapping.md §5,
/// 04 §9): BoxSets.
///
/// - A BoxSet is server-wide, not per library, but
///   `/Items?parentId={library}&recursive=true&includeItemTypes=BoxSet` lists
///   the BoxSets with a title in that library (a BoxSet of films and a show
///   is in both libraries), paged by the server. A library's collections,
///   its Collections filter and the grid's "has collections" probe read that.
/// - `/Items` ignores `parentId` once `ids=` is given (measured on 12.4), so
///   "which of a BoxSet's titles are in this library", which the collection
///   filter needs, is read from each title's `/Ancestors`.
/// - An item names none of its BoxSets, so "Part of" reads the membership
///   index: every BoxSet with its titles, built on first use and kept in
///   memory for `JellyfinCollectionIndex.maxAge`.
/// - A BoxSet's titles are read once per `maxAge` (count, noun, the poster a
///   BoxSet without artwork borrows).
/// - Read-only, as on Plex: creating a BoxSet needs
///   `EnableCollectionManagement`, and Dusk edits no collections anywhere.
/// - Jellyfin has no video channels and no per-library collection mode.
extension JellyfinCatalog {
    func channelCollections(libraryID: String) async throws -> [MediaCollection] { [] }

    func collectionMode(libraryID: String) async -> LibraryCollectionMode { .showItems }

    /// The library's BoxSets in name order, paged by the server.
    func collections(libraryID: String, start: Int, size: Int) async throws -> MediaItemPage {
        let client = try makeClient()
        var query = Self.boxSets(inLibrary: libraryID)
        query.startIndex = start
        query.limit = size
        let result = try await client.send(JellyfinAPI.items(query))
        let collections = try await resolvedCollections(result.items, client: client)
        return MediaItemPage(
            items: collections.map { $0.item(serverID: serverID) },
            totalSize: result.totalRecordCount,
            start: start,
            requestedSize: size
        )
    }

    /// The BoxSet's titles in its own order (the server's display order),
    /// or in `sort`.
    func collectionItems(collectionID: String, start: Int, size: Int, sort: LibrarySortOption?) async throws -> MediaItemPage {
        let client = try makeClient()
        var query = JellyfinItemQuery()
        query.parentID = collectionID
        query.fields = JellyfinBrowseVocabulary.listFields
        if let sort { JellyfinBrowseVocabulary.apply(sort: sort, to: &query) }
        query.startIndex = start
        query.limit = size
        let result = try await client.send(JellyfinAPI.items(query))
        return MediaItemPage(
            items: result.items.map { JellyfinItemMapper.map($0, serverID: serverID) },
            totalSize: result.totalRecordCount,
            start: start,
            requestedSize: size
        )
    }

    /// nil when the id is not a BoxSet the user can see.
    func collection(itemID: String) async throws -> MediaItem? {
        let client = try makeClient()
        return try await resolvedCollections(ids: [JellyfinID.normalized(itemID)], client: client)
            .first?.item(serverID: serverID)
    }

    /// The BoxSets that hold `itemID`, in name order. The library and the
    /// tags are Plex's way in; Jellyfin has the index instead.
    func collections(containing itemID: String, libraryID: String?, tags: [Tag]) async throws -> [MediaItem] {
        let client = try makeClient()
        let index = try await collectionIndex(client: client)
        let wanted = JellyfinID.normalized(itemID)
        return index.collections
            .filter { $0.memberIDs.contains(wanted) }
            .map { $0.item(serverID: serverID) }
    }

    // MARK: - The Collections filter

    /// Whether any BoxSet has a title in the library (one count).
    func libraryHasCollections(libraryID: String, client: JellyfinClient) async throws -> Bool {
        var query = Self.boxSets(inLibrary: libraryID)
        query.fields = []
        query.sortBy = []
        query.limit = 0
        return try await (client.send(JellyfinAPI.items(query)).totalRecordCount ?? 0) > 0
    }

    /// The BoxSets with a title in the library, in name order.
    func collectionChoices(libraryID: String, client: JellyfinClient) async throws -> [LibraryFilterChoice] {
        var query = Self.boxSets(inLibrary: libraryID)
        query.fields = []
        return try await client.send(JellyfinAPI.items(query)).items.compactMap { boxSet in
            guard let title = boxSet.name?.nilIfEmpty else { return nil }
            return LibraryFilterChoice(value: JellyfinID.normalized(boxSet.id), title: title)
        }
    }

    /// A BoxSet's titles that are in the library: its titles, each kept when
    /// its `/Ancestors` include the library.
    func collectionMemberIDs(_ collectionID: String, inLibrary libraryID: String, client: JellyfinClient) async throws -> [String] {
        let wanted = JellyfinID.normalized(collectionID)
        guard let collection = try await resolvedCollections(ids: [wanted], client: client).first else { return [] }
        let key = JellyfinCatalogCache.key(serverID, client, "ancestors")
        var known = JellyfinCollectionIndex.ancestors[key] ?? [:]
        let missing = collection.memberIDs.filter { known[$0] == nil }
        if !missing.isEmpty {
            let found = try await Self.ancestors(of: missing, client: client)
            known.merge(found) { _, new in new }
            JellyfinCollectionIndex.ancestors[key] = known
        }
        let library = JellyfinID.normalized(libraryID)
        return collection.memberIDs.filter { known[$0]?.contains(library) == true }
    }

    // MARK: - Index

    /// Every BoxSet the user sees with its titles, for "Part of"; rebuilt once
    /// it is `maxAge` old. Joins a build already running for the same user.
    func collectionIndex(client: JellyfinClient) async throws -> JellyfinCollectionIndex {
        let key = JellyfinCatalogCache.key(serverID, client, "collections")
        if let cached = JellyfinCollectionIndex.built[key], cached.isFresh { return cached }
        if let running = JellyfinCollectionIndex.building[key] { return try await running.value }

        let catalog = self
        let task = Task { @MainActor () throws -> JellyfinCollectionIndex in
            var query = JellyfinItemQuery()
            query.recursive = true
            query.includeItemTypes = [.boxSet]
            query.sortBy = [.sortName]
            query.fields = Self.boxSetFields
            let boxSets = try await client.send(JellyfinAPI.items(query)).items
            return JellyfinCollectionIndex(
                collections: try await catalog.resolvedCollections(boxSets, client: client),
                builtAt: Date()
            )
        }
        JellyfinCollectionIndex.building[key] = task
        defer { JellyfinCollectionIndex.building[key] = nil }
        let index = try await task.value
        JellyfinCollectionIndex.built[key] = index
        return index
    }

    // MARK: - Requests

    private static let boxSetFields: [JellyfinItemField] = [.overview, .dateCreated]
    /// Requests in flight at once when one is needed per BoxSet or title.
    private static let fanOut = 6

    /// The BoxSets with a title in the library, in name order.
    private static func boxSets(inLibrary libraryID: String) -> JellyfinItemQuery {
        var query = JellyfinItemQuery()
        query.parentID = libraryID
        query.recursive = true
        query.includeItemTypes = [.boxSet]
        query.sortBy = [.sortName]
        query.fields = boxSetFields
        return query
    }

    /// The BoxSets by id, read when not cached.
    private func resolvedCollections(ids: [String], client: JellyfinClient) async throws -> [JellyfinCollectionIndex.Collection] {
        let key = JellyfinCatalogCache.key(serverID, client, "boxset")
        let cached = ids.compactMap { JellyfinCollectionIndex.collections["\(key)|\($0)"] }.filter(\.isFresh)
        if cached.count == ids.count { return cached.map(\.collection) }
        var query = JellyfinItemQuery()
        query.ids = ids
        query.includeItemTypes = [.boxSet]
        query.fields = Self.boxSetFields
        return try await resolvedCollections(client.send(JellyfinAPI.items(query)).items, client: client)
    }

    /// Each BoxSet with its titles, in the given order. A BoxSet's titles
    /// are read once per `maxAge`, `fanOut` requests at a time.
    private func resolvedCollections(_ boxSets: [JellyfinItemDTO], client: JellyfinClient) async throws -> [JellyfinCollectionIndex.Collection] {
        let key = JellyfinCatalogCache.key(serverID, client, "boxset")
        var resolved: [String: JellyfinCollectionIndex.Collection] = [:]
        var missing: [JellyfinItemDTO] = []
        for boxSet in boxSets {
            let id = JellyfinID.normalized(boxSet.id)
            if let cached = JellyfinCollectionIndex.collections["\(key)|\(id)"], cached.isFresh {
                resolved[id] = cached.collection
            } else {
                missing.append(boxSet)
            }
        }
        let read = try await Self.children(of: missing.map(\.id), client: client)
        let now = Date()
        for (boxSet, items) in zip(missing, read) {
            let collection = JellyfinCollectionIndex.Collection(
                dto: boxSet,
                memberIDs: items.map { JellyfinID.normalized($0.id) },
                memberKinds: items.map(JellyfinItemMapper.mediaKind),
                fallbackPoster: items.lazy.compactMap { item in
                    JellyfinArtworkLocator.path(itemID: item.id, type: .primary, tag: item.imageTag(.primary))
                }.first
            )
            resolved[collection.id] = collection
            JellyfinCollectionIndex.collections["\(key)|\(collection.id)"] = .init(collection: collection, readAt: now)
        }
        return boxSets.compactMap { resolved[JellyfinID.normalized($0.id)] }
    }

    /// Each parent's direct children, in the order of `parentIDs`.
    private static func children(of parentIDs: [String], client: JellyfinClient) async throws -> [[JellyfinItemDTO]] {
        try await withThrowingTaskGroup(of: (Int, [JellyfinItemDTO]).self) { group in
            var children = [[JellyfinItemDTO]](repeating: [], count: parentIDs.count)
            var next = 0
            var done = 0
            while next < parentIDs.count || !group.isEmpty {
                while next < parentIDs.count, next - done < fanOut {
                    var query = JellyfinItemQuery()
                    query.parentID = parentIDs[next]
                    query.imageTypeLimit = 1
                    let offset = next
                    next += 1
                    group.addTask { (offset, try await client.send(JellyfinAPI.items(query)).items) }
                }
                guard let (offset, items) = try await group.next() else { break }
                children[offset] = items
                done += 1
            }
            return children
        }
    }

    /// Each title's ancestor ids (its library among them), `fanOut` at a time.
    private static func ancestors(of itemIDs: [String], client: JellyfinClient) async throws -> [String: Set<String>] {
        try await withThrowingTaskGroup(of: (String, Set<String>).self) { group in
            var found: [String: Set<String>] = [:]
            var next = 0
            while next < itemIDs.count || !group.isEmpty {
                while next < itemIDs.count, next - found.count < fanOut {
                    let id = itemIDs[next]
                    next += 1
                    group.addTask {
                        let ancestors = try await client.send(JellyfinAPI.ancestors(itemID: id))
                        return (id, Set(ancestors.map { JellyfinID.normalized($0.id) }))
                    }
                }
                guard let (id, ancestors) = try await group.next() else { break }
                found[id] = ancestors
            }
            return found
        }
    }
}

/// What the Jellyfin catalog remembers about collections, per server and
/// user: a `JellyfinCatalog` is rebuilt on every access, so it cannot hold
/// it. Memory only; nothing is persisted.
@MainActor
struct JellyfinCollectionIndex: Sendable {
    /// Long enough for a browsing session, short enough that a collection an
    /// admin just made or filled shows up without a relaunch.
    nonisolated static let maxAge: TimeInterval = 10 * 60

    /// The "Part of" index, by server|user.
    static var built: [String: JellyfinCollectionIndex] = [:]
    static var building: [String: Task<JellyfinCollectionIndex, Error>] = [:]
    /// Each BoxSet with its titles, by server|user|boxSet.
    static var collections: [String: Cached] = [:]
    /// Each title's ancestor ids, by server|user, for the collection filter.
    /// A title does not move between libraries, so these are kept for the launch.
    static var ancestors: [String: [String: Set<String>]] = [:]

    struct Collection: Sendable {
        let dto: JellyfinItemDTO
        let memberIDs: [String]
        let memberKinds: [MediaKind]
        let fallbackPoster: String?

        var id: String { JellyfinID.normalized(dto.id) }

        func item(serverID: String) -> MediaItem {
            JellyfinItemMapper.collection(dto, serverID: serverID, memberKinds: memberKinds, fallbackPoster: fallbackPoster)
        }
    }

    struct Cached: Sendable {
        let collection: Collection
        let readAt: Date

        var isFresh: Bool { Date().timeIntervalSince(readAt) < JellyfinCollectionIndex.maxAge }
    }

    let collections: [Collection]
    let builtAt: Date

    var isFresh: Bool { Date().timeIntervalSince(builtAt) < Self.maxAge }
}
