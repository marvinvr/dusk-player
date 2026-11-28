import Foundation

/// One page of a photo library query and the size of the whole result.
struct PlexPhotoPage: Sendable {
    let items: [PhotoItem]
    let totalSize: Int?
}

/// What a photo grid lists. Every query goes through the section's `/all`
/// rather than an album's `/children`: `/children` mixes sub-albums in with
/// the photos, so a date-sorted, paged walk over it would bury the albums on
/// the last page.
enum PlexPhotoQuery: Hashable, Sendable {
    /// The albums directly inside `parent` (the library root when nil).
    case albums(parent: String?)
    /// The photos and clips directly inside `parent` (loose photos in the
    /// library root when nil), oldest first like an album.
    case media(parent: String?)
    /// Every photo and clip in the library, newest first.
    case timeline
}

extension PlexService {
    /// Plex search type ids: clip 12, photo 13, photo album 14.
    private static let photoAlbumType = "14"
    private static let photoMediaTypes = "13,12"

    func getPhotoItems(
        sectionId: String,
        query: PlexPhotoQuery,
        start: Int,
        size: Int,
        serverID: String?
    ) async throws -> PlexPhotoPage {
        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(size)),
        ]

        switch query {
        case .albums(let parent):
            queryItems.append(URLQueryItem(name: "type", value: Self.photoAlbumType))
            queryItems.append(URLQueryItem(name: "sort", value: "titleSort"))
            if let parent {
                queryItems.append(URLQueryItem(name: "parent", value: parent))
            }
        case .media(let parent):
            queryItems.append(URLQueryItem(name: "type", value: Self.photoMediaTypes))
            queryItems.append(URLQueryItem(name: "sort", value: "originallyAvailableAt,titleSort"))
            if let parent {
                queryItems.append(URLQueryItem(name: "parent", value: parent))
            }
        case .timeline:
            // Without `clusterZoomLevel=1` the type filter only reaches the
            // photos loose in the library root.
            queryItems.append(URLQueryItem(name: "type", value: Self.photoMediaTypes))
            queryItems.append(URLQueryItem(name: "clusterZoomLevel", value: "1"))
            queryItems.append(URLQueryItem(name: "sort", value: "originallyAvailableAt:desc,addedAt:desc"))
        }

        let targetID = try resolveServerID(serverID)
        let data = try await rawServerRequest(
            path: "/library/sections/\(sectionId)/all",
            queryItems: queryItems,
            serverID: targetID
        )
        let response = try decodeJSON(MetadataResponse<PlexPhotoItemDTO>.self, from: data, serverID: targetID)
        return PlexPhotoPage(
            items: (response.MediaContainer.Metadata ?? [])
                .map { PlexUserContentMapper.photoItem($0, serverID: targetID) }
                .filter { $0.kind != nil },
            totalSize: response.MediaContainer.totalSize
        )
    }

    /// A square-cropped grid tile. `imageURL` asks the transcoder to fill the
    /// box (`minSize=1`), and the tile crops what overflows.
    func photoThumbnailURL(for item: PhotoItem, side: Int) -> URL? {
        imageURL(
            for: ArtworkRef(serverID: item.serverID, path: item.isAlbum ? (item.composite ?? item.thumb) : item.thumb),
            size: ImageSize(width: side, height: side)
        )
    }

    /// The viewer's full-screen image: the original file, fitted *inside*
    /// `width`×`height` points (no `minSize`, which would overflow a portrait
    /// photo), with the transcoder applying the EXIF rotation and turning HEIC
    /// into JPEG. Clips have no transcodable original, so they use their thumb.
    func photoDisplayURL(for item: PhotoItem, width: Int, height: Int) -> URL? {
        guard item.kind == .photo, let partKey = item.partKey,
              let connection = pool.connection(for: item.serverID),
              let original = transcodeSourceURLString(for: partKey, serverID: item.serverID) else {
            return imageURL(for: ArtworkRef(serverID: item.serverID, path: item.thumb), size: ImageSize(width: width, height: height))
        }

        let base = connection.baseURL.absoluteString.hasSuffix("/")
            ? String(connection.baseURL.absoluteString.dropLast())
            : connection.baseURL.absoluteString
        var components = URLComponents(string: base + "/photo/:/transcode")
        components?.queryItems = [
            URLQueryItem(name: "width", value: String(scaledImageDimension(width) ?? width)),
            URLQueryItem(name: "height", value: String(scaledImageDimension(height) ?? height)),
            URLQueryItem(name: "upscale", value: "0"),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "url", value: original),
        ]
        return components?.url
    }
}
