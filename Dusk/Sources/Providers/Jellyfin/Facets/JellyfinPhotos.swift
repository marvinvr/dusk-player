import Foundation

/// Photo library pages for `JellyfinCatalog.photoPage` (docs/jellyfin/02-jellyfin-api-mapping.md
/// §13, 04 §9). Every query is one `/Items` page:
///
/// | query | parent | recursive | types | order |
/// | --- | --- | --- | --- | --- |
/// | albums | album or library | no | `PhotoAlbum`, `Folder` | `SortName` |
/// | media | album or library | no | `Photo`, `Video` | `PremiereDate, SortName` ascending |
/// | timeline | library | yes | `Photo`, `Video` | `DateCreated, SortName` descending |
///
/// - `recursive=false` is sent explicitly: with a library as the parent,
///   `includeItemTypes` alone makes the server walk the whole tree (the root of
///   jellyfin-demo's Photos lists 10 albums and 200 loose photos without it,
///   7 and 0 with it).
/// - A plain `Folder` (a directory that only holds albums) is an album.
/// - The album order is Plex's `originallyAvailableAt,titleSort`: a photo's
///   `PremiereDate` is its EXIF date, absent without one, so undated photos
///   sort by name.
/// - The timeline sorts by `DateCreated`, which the server takes from the EXIF
///   date when a photo has one and from the file otherwise: the same date Plex
///   orders its timeline by. A clip's `DateCreated` is always the file's, so a
///   clip with an older recording date sits where its file date puts it.
struct JellyfinPhotos {
    /// What the grid and viewer read beyond the slim list fields.
    static let fields: [JellyfinItemField] = [.dateCreated, .width, .height]

    static func query(libraryID: String, query: PhotoQuery, start: Int, size: Int) -> JellyfinItemQuery {
        var request = JellyfinItemQuery()
        request.fields = fields
        request.startIndex = start
        request.limit = size
        request.enableTotalRecordCount = true
        switch query {
        case .albums(let parent):
            request.parentID = parent ?? libraryID
            request.recursive = false
            request.includeItemTypes = [.photoAlbum, .folder]
            request.sortBy = [.sortName]
            request.sortOrder = .ascending
        case .media(let parent):
            request.parentID = parent ?? libraryID
            request.recursive = false
            request.includeItemTypes = [.photo, .video]
            request.sortBy = [.premiereDate, .sortName]
            request.sortOrder = .ascending
        case .timeline:
            request.parentID = libraryID
            request.recursive = true
            request.includeItemTypes = [.photo, .video]
            request.sortBy = [.dateCreated, .sortName]
            request.sortOrders = [.descending, .ascending]
        }
        return request
    }

    @MainActor
    static func page(
        libraryID: String,
        query photoQuery: PhotoQuery,
        start: Int,
        size: Int,
        serverID: String,
        client: JellyfinClient
    ) async throws -> PhotoPage {
        let result = try await client.send(JellyfinAPI.items(query(libraryID: libraryID, query: photoQuery, start: start, size: size)))
        return PhotoPage(
            items: result.items
                .map { JellyfinItemMapper.photoItem($0, serverID: serverID) }
                .filter { $0.kind != nil },
            totalSize: result.totalRecordCount
        )
    }
}
