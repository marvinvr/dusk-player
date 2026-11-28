import Foundation

/// Kept for `PhotoBrowserViewModel` until it names the neutral types
/// (`PhotoQuery`, `PhotoPage`, declared with `CatalogProviding`).
typealias PlexPhotoQuery = PhotoQuery
typealias PlexPhotoPage = PhotoPage

/// Photo libraries: the grid's pages route to the server's catalog facet;
/// the tile and viewer image URLs are built here on the image helpers.
extension MediaService {
    func getPhotoItems(
        sectionId: String,
        query: PhotoQuery,
        start: Int,
        size: Int,
        serverID: String?
    ) async throws -> PhotoPage {
        try await catalog(on: resolveServerID(serverID))
            .photoPage(libraryID: sectionId, query: query, start: start, size: size)
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
