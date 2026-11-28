import Foundation

/// What a provider's HLS output needs from Dusk (docs/jellyfin/04-architecture.md
/// §12.3). `RemuxHLSLoader` runs its init-segment patches and variant filter
/// only when these ask for them.
struct PlaybackTraits: Sendable, Hashable {
    /// Plex: the 13-byte `dec3` box loses the Atmos signalling.
    let remuxNeedsAtmosSignalingPatch: Bool
    /// Plex: the remux carries no `dvcC`/`dvvC` boxes.
    let remuxNeedsDolbyVisionBoxes: Bool
    /// Jellyfin: the master playlist also lists a tone-mapped variant.
    let remuxNeedsVariantFilter: Bool
    /// Jellyfin marks an item played from the stopped report.
    let serverAppliesWatchedThreshold: Bool
    /// Jellyfin remembers the reported tracks as the item's choice.
    let persistsTrackChoiceFromReports: Bool
}
