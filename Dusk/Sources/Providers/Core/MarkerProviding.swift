import CoreGraphics
import Foundation

/// Skip markers and scrub previews for one server
/// (docs/jellyfin/04-architecture.md §12.6). `MediaService+Markers` routes to
/// the item's server.
///
/// Main-actor isolated like the other facets: a provider reaches its server
/// through the facade's routed send, which lives on the main actor.
@MainActor
protocol MarkerProviding: Sendable {
    /// The skip markers of an item whose details are already loaded. A
    /// provider whose details carry the markers (Plex, `includeMarkers=1`)
    /// returns them without a request.
    ///
    /// The player still reads `MediaDetails.markers` directly: it builds its
    /// view model in `PlayerSessionView.init`, where no service is reachable.
    func markers(for details: MediaDetails) -> [Marker]

    /// Preview frames for the scrubber of the part being played. Keyed on the
    /// part, not the version: a multi-part item plays one part at a time.
    /// nil when the server has none for it, the id is a placeholder, or the
    /// load failed; the scrubber then shows no thumbnail.
    func scrubPreview(forPartID partID: String) async -> (any ScrubPreviewSource)?
}

/// Preview frames for the scrubber: Plex's BIF file, Jellyfin's trickplay
/// sheets, or frames generated on the device.
///
/// The player controls still take Plex's frame set (`ScrubPreviewFrameSet`)
/// and read it synchronously; moving them to this protocol is not part of
/// Phase 0.
protocol ScrubPreviewSource: Sendable {
    func frame(at time: TimeInterval) async -> CGImage?
}
