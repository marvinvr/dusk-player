import Foundation

/// Jellyfin's skip markers and scrub previews. Placeholder until J-05
/// (`/MediaSegments`, trickplay): the item's own markers, no previews.
@MainActor
struct JellyfinMarkers: MarkerProviding {
    let server: JellyfinServerProvider

    nonisolated init(server: JellyfinServerProvider) {
        self.server = server
    }

    func markers(for details: MediaDetails) -> [Marker] { details.markers }

    func scrubPreview(forPartID partID: String) async -> (any ScrubPreviewSource)? { nil }
}
