import Foundation

/// Skip markers and scrub previews, routed to the item's server's
/// `MarkerProviding` (docs/jellyfin/04-architecture.md §12.6).

extension MediaService {
    /// The marker facet of `serverID`'s provider (nil = the primary server).
    func markerFacet(on serverID: String?) throws -> any MarkerProviding {
        serverProvider(for: try resolveServerID(serverID)).markers
    }

    /// Preview frames for the scrubber of the part being played on `serverID`.
    /// nil when there are none or loading them failed; never throws, because
    /// a missing thumbnail is not an error the player shows.
    func scrubPreview(forPartID partID: String, serverID: String? = nil) async -> (any ScrubPreviewSource)? {
        guard let facet = try? markerFacet(on: serverID) else { return nil }
        return await facet.scrubPreview(forPartID: partID)
    }
}
