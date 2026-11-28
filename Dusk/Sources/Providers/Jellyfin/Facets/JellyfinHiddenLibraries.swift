import Foundation

/// Search hits from libraries the user hides (`MyMediaExcludes`). Jellyfin's
/// search ignores the exclusions and its items name no library (`ParentId` is
/// the folder on disk), so the facade's `HiddenLibraryFilter` has nothing to
/// match them on: the catalog drops them before they leave it.
enum JellyfinHiddenLibraries {
    /// Asks the same search once more per hidden view, narrowed to it
    /// (`parentId`), and drops what it names. Same order and limit: a hit the
    /// unrestricted search returned has no more predecessors inside one view
    /// than outside it, so it is always within the narrowed answer.
    static func dropping(
        _ hiddenViewIDs: Set<String>,
        from items: [MediaItem],
        search: JellyfinItemQuery,
        client: JellyfinClient
    ) async throws -> [MediaItem] {
        guard !hiddenViewIDs.isEmpty, !items.isEmpty else { return items }
        var hiddenItemIDs: Set<String> = []
        for viewID in hiddenViewIDs.sorted() {
            var narrowed = search
            narrowed.parentID = viewID
            narrowed.fields = []
            narrowed.enableImages = false
            narrowed.enableUserData = false
            let hits = try await client.send(JellyfinAPI.items(narrowed)).items
            hiddenItemIDs.formUnion(hits.map { JellyfinID.normalized($0.id) })
        }
        return items.filter { !hiddenItemIDs.contains(JellyfinID.normalized($0.itemID)) }
    }
}
