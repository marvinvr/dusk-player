import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Jellyfin's skip markers and scrub previews (04 §12.6). Markers come with
/// the details (`JellyfinItemDetails`); previews are the part's trickplay
/// sheets.
@MainActor
struct JellyfinMarkers: MarkerProviding {
    let server: JellyfinServerProvider

    nonisolated init(server: JellyfinServerProvider) {
        self.server = server
    }

    func markers(for details: MediaDetails) -> [Marker] { details.markers }

    /// A part is a media source, and a source id is an item id, so the part's
    /// own item names its trickplay renditions (`Trickplay[sourceId][width]`).
    /// The player controls read Plex's frame set synchronously, so every
    /// sheet is fetched and cut into frames up front, as Plex's BIF file is
    /// fetched whole: a 2 h film is 8 sheets of about 1 MB at 320 px.
    func scrubPreview(forPartID partID: String) async -> (any ScrubPreviewSource)? {
        guard !partID.isEmpty, let client = try? server.client(),
              let item = try? await client.send(JellyfinAPI.item(id: partID)),
              let info = JellyfinTrickplay.rendition(in: item.trickplay, sourceID: partID) else { return nil }

        let sheets = await JellyfinTrickplay.sheets(itemID: partID, info: info, client: client)
        let frames = await Task.detached(priority: .utility) {
            JellyfinTrickplay.frames(from: sheets, info: info)
        }.value
        return frames.isEmpty ? nil : ScrubPreviewFrameSet(frames: frames)
    }
}

/// Trickplay (02 §11): `ThumbnailCount` thumbnails every `Interval` ms, laid
/// out row by row on sheets of `TileWidth` × `TileHeight` tiles of
/// `Width` × `Height` px, `/Videos/{id}/Trickplay/{width}/{n}.jpg`. The last
/// sheet is only as tall as its rows.
enum JellyfinTrickplay {
    /// The width closest to Plex's BIF thumbnails.
    static let preferredWidth = 320

    static func rendition(
        in trickplay: [String: [String: JellyfinTrickplayInfoDTO]]?,
        sourceID: String
    ) -> JellyfinTrickplayInfoDTO? {
        guard let renditions = trickplay?.first(where: { JellyfinID.same($0.key, sourceID) })?.value else { return nil }
        return renditions.values
            .filter { $0.width > 0 && $0.height > 0 && $0.tileWidth > 0 && $0.tileHeight > 0
                && $0.thumbnailCount > 0 && $0.interval > 0 }
            .min { abs($0.width - preferredWidth) < abs($1.width - preferredWidth) }
    }

    static func sheetCount(_ info: JellyfinTrickplayInfoDTO) -> Int {
        let perSheet = info.tileWidth * info.tileHeight
        return (info.thumbnailCount + perSheet - 1) / perSheet
    }

    struct Sheet: Sendable {
        let index: Int
        let data: Data?
    }

    /// Every sheet, in order. A sheet that fails leaves its thumbnails out.
    static func sheets(itemID: String, info: JellyfinTrickplayInfoDTO, client: JellyfinClient) async -> [Sheet] {
        let count = sheetCount(info)
        let id = JellyfinID.normalized(itemID)
        return await withTaskGroup(of: Sheet.self) { group in
            for index in 0..<count {
                group.addTask {
                    let tile = JellyfinAPI.trickplayTilePath(itemID: id, mediaSourceID: id, width: info.width, index: index)
                    let request = JellyfinRequest<Data>(path: tile.path, query: tile.query) { data, _ in data }
                    return Sheet(index: index, data: try? await client.send(request))
                }
            }
            var sheets: [Sheet] = []
            for await sheet in group { sheets.append(sheet) }
            return sheets.sorted { $0.index < $1.index }
        }
    }

    /// The thumbnails cut out of `sheets` as JPEG frames, thumbnail `n` at
    /// `n × Interval` ms.
    static func frames(from sheets: [Sheet], info: JellyfinTrickplayInfoDTO) -> [ScrubPreviewFrame] {
        let perSheet = info.tileWidth * info.tileHeight
        var frames: [ScrubPreviewFrame] = []
        frames.reserveCapacity(info.thumbnailCount)
        for sheet in sheets {
            guard let data = sheet.data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            for tile in 0..<perSheet {
                let number = sheet.index * perSheet + tile
                guard number < info.thumbnailCount else { break }
                let rect = CGRect(
                    x: (tile % info.tileWidth) * info.width,
                    y: (tile / info.tileWidth) * info.height,
                    width: info.width,
                    height: info.height
                )
                guard rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height),
                      let thumbnail = image.cropping(to: rect),
                      let jpeg = jpegData(thumbnail) else { continue }
                frames.append(ScrubPreviewFrame(timestampMs: Int64(number) * Int64(info.interval), imageData: jpeg))
            }
        }
        return frames
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
