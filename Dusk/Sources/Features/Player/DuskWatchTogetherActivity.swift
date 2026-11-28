import Foundation
import GroupActivities

/// The server-scoped item a SharePlay group watches together.
///
/// Playback URLs and auth tokens deliberately never cross the Group Activities
/// boundary. Every participant resolves this identity against their own
/// session with that server and may independently use direct play, a local
/// download, or a server stream.
///
/// Frozen wire format (docs/jellyfin/04-architecture.md §12.7, §18): the
/// activity identifier, the Codable keys (`serverIdentifier`, `ratingKey`) and
/// the `plex://` playback item identifier are what other participants' builds,
/// including older ones, decode and compare. Swift names may change; these
/// strings may not.
struct DuskWatchTogetherActivity: GroupActivity, Equatable, Sendable {
    static let activityIdentifier = "com.dusk-player.app.watch-together"

    let serverIdentifier: String
    let itemID: String
    let title: String
    let subtitle: String?

    enum CodingKeys: String, CodingKey {
        case serverIdentifier, itemID = "ratingKey", title, subtitle
    }

    /// Shared by AVPlayer and VLCKit playback coordinators. An item id is
    /// unique only within one server, so both pieces are required. The
    /// `plex://` scheme stays for Plex items (a Jellyfin item will use
    /// `dusk://`, 04 §12.7).
    var playbackItemIdentifier: String {
        "plex://\(serverIdentifier)/metadata/\(itemID)"
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
