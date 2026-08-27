import Foundation
import GroupActivities

/// The server-scoped Plex item a SharePlay group watches together.
///
/// Playback URLs and auth tokens deliberately never cross the Group Activities
/// boundary. Every participant resolves this identity against their own Plex
/// session and may independently use direct play, a local download, or a Plex
/// server stream.
struct DuskWatchTogetherActivity: GroupActivity, Equatable, Sendable {
    static let activityIdentifier = "com.dusk-player.app.watch-together"

    let serverIdentifier: String
    let ratingKey: String
    let title: String
    let subtitle: String?

    /// Shared by AVPlayer and VLCKit playback coordinators. A rating key is
    /// unique only within one Plex server, so both pieces are required.
    var playbackItemIdentifier: String {
        "plex://\(serverIdentifier)/metadata/\(ratingKey)"
    }

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.type = .watchTogether
        metadata.title = title
        metadata.subtitle = subtitle ?? "Watch together in Dusk"
        metadata.supportsContinuationOnTV = true
        metadata.lifetimePolicy = .automatic
        return metadata
    }
}
