import CoreGraphics
import Foundation

/// Skip markers and scrub previews (docs/jellyfin/04-architecture.md §12.6).
/// Empty until P0-11.
protocol MarkerProviding: Sendable {}

/// Preview frames for the scrubber: Plex's BIF file, Jellyfin's trickplay
/// sheets, or frames generated on the device.
protocol ScrubPreviewSource: Sendable {
    func frame(at time: TimeInterval) async -> CGImage?
}
