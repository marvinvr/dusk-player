import CoreGraphics
import Foundation
import ImageIO

/// How `PlexMarkers` reaches its server: the facade's scrub-preview read,
/// which re-authorizes a missing session and refreshes the token once on a
/// 401 (`MediaService+Markers`). Deliberately not `rawServerRequest`: a
/// missing index is an ordinary 404 and must not start connection recovery.
@MainActor
protocol PlexMarkersTransport: AnyObject, Sendable {
    /// GET `path` on `serverID` with `accept` as the Accept header, served
    /// from the URL cache when it can be.
    func scrubPreviewData(path: String, accept: String, serverID: String) async throws -> Data
}

/// Plex's `MarkerProviding`. Markers arrive with the item's details
/// (`includeMarkers=1`); scrub previews are the part's BIF index,
/// `/library/parts/{partID}/indexes/sd`.
struct PlexMarkers: MarkerProviding {
    /// The server every call goes to.
    let serverID: String
    /// nil only on the provider's own facet (see `PlexServerProvider.markers`),
    /// which then has no previews.
    let transport: (any PlexMarkersTransport)?

    nonisolated init(serverID: String, transport: (any PlexMarkersTransport)?) {
        self.serverID = serverID
        self.transport = transport
    }

    func markers(for details: MediaDetails) -> [Marker] {
        details.markers
    }

    func scrubPreview(forPartID partID: String) async -> (any ScrubPreviewSource)? {
        // Plex part ids are positive numbers; 0 or below is a placeholder.
        guard Int(partID).map({ $0 > 0 }) ?? !partID.isEmpty else { return nil }
        guard let transport else { return nil }

        do {
            let data = try await transport.scrubPreviewData(
                path: "/library/parts/\(partID)/indexes/sd",
                accept: "application/octet-stream,image/*,*/*",
                serverID: serverID
            )
            guard !data.isEmpty, data.count <= PlexBIFIndex.maxFileSize else { return nil }

            let frames = await Task.detached(priority: .utility) {
                PlexBIFIndex.parse(data)
            }.value

            guard !frames.isEmpty else { return nil }
            return PlexScrubPreviewSource(frames: frames)
        } catch {
            return nil
        }
    }
}

extension PlexServerProvider {
    /// Sends through the account's routed send (`PlexServerRouter`).
    var markers: any MarkerProviding {
        PlexMarkers(serverID: descriptor.id, transport: router)
    }
}

// MARK: - BIF

/// Plex's BIF frame set as a `ScrubPreviewSource`. The player controls read
/// its frames synchronously (`frame(at:) -> PlexScrubPreviewFrame?`); this is
/// the same lookup decoded to an image.
extension PlexScrubPreviewSource: ScrubPreviewSource {
    func frame(at time: TimeInterval) async -> CGImage? {
        let frame: PlexScrubPreviewFrame? = frame(at: time)
        guard let frame,
              let source = CGImageSourceCreateWithData(frame.imageData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Roku's BIF container as Plex serves it: an 8-byte magic, the frame count at
/// 12, the timestamp multiplier at 16 (0 means 1000 ms), and from 64 a table
/// of (timestamp, offset) pairs, one per frame plus an end sentinel. Each
/// frame is a JPEG.
private enum PlexBIFIndex {
    static let maxFileSize = 50 * 1024 * 1024

    private static let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]

    static func parse(_ data: Data) -> [PlexScrubPreviewFrame] {
        guard data.count >= 72, data.count <= maxFileSize else { return [] }

        let bytes = [UInt8](data)
        guard Array(bytes.prefix(magic.count)) == magic else { return [] }

        let imageCountValue = uint32(at: 12, in: bytes)
        guard imageCountValue > 0 else {
            return []
        }

        let imageCount = Int(imageCountValue)
        let tableEntryCount = imageCount + 1
        guard tableEntryCount > imageCount,
              tableEntryCount <= (bytes.count - 64) / 8 else {
            return []
        }

        let rawMultiplier = uint32(at: 16, in: bytes)
        let timestampMultiplier = Int64(rawMultiplier == 0 ? 1000 : rawMultiplier)

        var frames: [PlexScrubPreviewFrame] = []
        frames.reserveCapacity(imageCount)

        for index in 0..<imageCount {
            let entryOffset = 64 + (index * 8)
            let timestamp = uint32(at: entryOffset, in: bytes)
            let imageOffset = Int(uint32(at: entryOffset + 4, in: bytes))
            let nextImageOffset = Int(uint32(at: entryOffset + 12, in: bytes))

            guard nextImageOffset > imageOffset,
                  nextImageOffset <= data.count else {
                continue
            }

            frames.append(
                PlexScrubPreviewFrame(
                    timestampMs: Int64(timestamp) * timestampMultiplier,
                    imageData: data.subdata(in: imageOffset..<nextImageOffset)
                )
            )
        }

        return frames
    }

    private static func uint32(at offset: Int, in bytes: [UInt8]) -> UInt32 {
        guard offset >= 0, offset + 3 < bytes.count else { return 0 }

        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
