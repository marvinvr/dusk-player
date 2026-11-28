import Foundation

/// Collections: listed per library, expanded into their titles. Each method
/// is a route to the server's catalog facet (`CatalogProviding`,
/// `PlexCatalog`); `MediaItemPage` and `LibraryCollectionMode` are declared
/// with it.
extension MediaService {
    func getCollections(
        sectionId: String,
        start: Int = 0,
        size: Int = 50,
        serverID: String? = nil
    ) async throws -> MediaItemPage {
        try await catalog(on: resolveServerID(serverID)).collections(libraryID: sectionId, start: start, size: size)
    }

    /// A collection's titles, in the collection's own sort order, or in
    /// `sort` (a Plex sort value such as `titleSort:desc`,
    /// `LibrarySortOption.plexValue`) when given.
    func getCollectionItems(
        itemID: String,
        start: Int = 0,
        size: Int = 50,
        sort: String? = nil,
        serverID: String? = nil
    ) async throws -> MediaItemPage {
        try await plexCatalog(on: resolveServerID(serverID))
            .rawCollectionItems(collectionID: itemID, start: start, size: size, sort: sort)
    }

    /// The collection itself (title, summary, artwork, count).
    func getCollection(itemID: String, serverID: String? = nil) async throws -> MediaItem? {
        try await catalog(on: resolveServerID(serverID)).collection(itemID: itemID)
    }

    /// The library's collection display setting. Anything unreadable is the
    /// default, so collections stay visible.
    func collectionMode(sectionId: String, serverID: String? = nil) async -> LibraryCollectionMode {
        guard let targetID = try? resolveServerID(serverID) else { return .showItems }
        return await catalog(on: targetID).collectionMode(libraryID: sectionId)
    }
}
