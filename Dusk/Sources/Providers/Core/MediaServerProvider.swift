import Foundation

/// One server, whatever runs it (docs/jellyfin/04-architecture.md §3). The
/// provider's `ProviderFactory` builds one per session and the pool stores it on
/// that `ServerSession`.
///
/// Each facet starts as an empty protocol. A wave-4 package fills in its facet,
/// moves the Plex code behind it and makes the facade route to it (05-plan.md
/// §4); until then the facade still talks to Plex directly and nothing reads
/// these properties. `permissions` (`ServerPermissions`) joins with the account
/// layer (P0-16), because Plex's answers depend on the active profile.
protocol MediaServerProvider: AnyObject, Sendable {
    var descriptor: ServerDescriptor { get }

    // Required: both platforms can do these.
    var catalog: any CatalogProviding { get }
    var home: any HomeProviding { get }
    var playback: any PlaybackProviding { get }
    var userData: any UserDataProviding { get }
    var markers: any MarkerProviding { get }
    var images: any ImageProviding { get }
    var playlists: any PlaylistProviding { get }
    var downloads: any DownloadProviding { get }

    // Optional: nil means the platform or this server does not have it.
    var liveTV: (any LiveTVProviding)? { get }
    var subtitleSearch: (any SubtitleSearchProviding)? { get }
    var rating: (any UserRatingProviding)? { get }
}

/// Who a server is: id, name, provider, version and owner.
struct ServerDescriptor: Sendable, Hashable {
    let id: String
    let name: String
    let kind: ProviderKind
    let version: String?
    /// The owner's name for a server shared with the account ("Shared by X");
    /// nil for one the account owns.
    let ownerLabel: String?
}

/// What a factory gets to build the provider for one server session.
struct ServerSessionSeed: Sendable, Hashable {
    let serverID: String
    let name: String
    let version: String?
    let owned: Bool
    let sourceTitle: String?
}
