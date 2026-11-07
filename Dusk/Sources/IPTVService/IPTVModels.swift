import Foundation

/// A user-added IPTV source: a standard M3U playlist plus an optional XMLTV
/// guide. Generic by design — Dusk knows nothing about any particular
/// provider. Stored per Plex profile (`IPTVSourceStore`); the header value is
/// a secret and lives in the Keychain, never in this struct's persisted form.
struct IPTVSource: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var playlistURL: URL
    /// Explicit guide URL. When nil the playlist header's `url-tvg` /
    /// `x-tvg-url` is used instead.
    var guideURL: URL?
    /// Name of the optional request header sent with every request for this
    /// source (playlist, guide, stream, FairPlay certificate and license).
    var headerName: String?

    init(
        id: UUID = UUID(),
        name: String,
        playlistURL: URL,
        guideURL: URL? = nil,
        headerName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.playlistURL = playlistURL
        self.guideURL = guideURL
        self.headerName = headerName
    }

    static let defaultHeaderName = "Authorization"
}

/// What the license lines of an M3U entry ask for.
struct IPTVDRMConfiguration: Hashable, Sendable {
    /// Raw `inputstream.adaptive.license_type`, e.g. `com.apple.fps`.
    var licenseType: String?
    /// `inputstream.adaptive.license_key`: the license server URL (Kodi's
    /// `url|headers|body|response` suffix is dropped).
    var licenseURL: URL?
    /// `inputstream.adaptive.server_certificate`: where the FairPlay
    /// application certificate is fetched from.
    var certificateURL: URL?

    enum KeySystem: Hashable, Sendable {
        case fairPlay
        /// Widevine, PlayReady, ClearKey… Apple devices cannot play these.
        case unsupported(String)
    }

    /// Nil when the entry names no license type: an entry with only a license
    /// URL is treated as FairPlay, since that is the only system AVPlayer has.
    var keySystem: KeySystem? {
        guard let type = licenseType?.trimmingCharacters(in: .whitespaces).lowercased().nilIfEmpty else {
            return licenseURL == nil ? nil : .fairPlay
        }
        if Self.fairPlayTypes.contains(type) { return .fairPlay }
        return .unsupported(licenseType ?? type)
    }

    var isEmpty: Bool {
        licenseType == nil && licenseURL == nil && certificateURL == nil
    }

    static let fairPlayTypes: Set<String> = [
        "com.apple.fps", "com.apple.fps.1_0", "com.apple.streamingkeydelivery", "fairplay", "fps",
    ]
}

/// One channel line of an M3U playlist.
struct IPTVPlaylistEntry: Hashable, Sendable {
    var title: String
    var streamURL: URL
    var tvgID: String?
    var tvgName: String?
    var logoURL: URL?
    var group: String?
    var number: String?
    var userAgent: String?
    var referrer: String?
    /// Headers from Kodi's `url|Header=value&…` stream suffix.
    var streamHeaders: [String: String] = [:]
    var drm: IPTVDRMConfiguration?
}

struct IPTVPlaylist: Hashable, Sendable {
    /// Guide URLs advertised by `#EXTM3U url-tvg=… x-tvg-url=…`.
    var guideURLs: [URL]
    var entries: [IPTVPlaylistEntry]
}

/// One XMLTV `<programme>`.
struct IPTVProgramme: Hashable, Sendable {
    var channelID: String
    var start: Date
    var stop: Date
    var title: String
    var subtitle: String?
    var summary: String?
    var iconURL: URL?
}

struct IPTVGuideChannel: Hashable, Sendable {
    var id: String
    var displayNames: [String]
    var iconURL: URL?
}

struct IPTVGuide: Hashable, Sendable {
    var channels: [String: IPTVGuideChannel]
    /// Keyed by XMLTV channel id, sorted by start.
    var programmes: [String: [IPTVProgramme]]

    static let empty = IPTVGuide(channels: [:], programmes: [:])
}

/// Everything AVPlayer needs to open one IPTV channel. Rides on
/// `PlexLiveChannel.iptv`, which is how the shared Live TV guide and player
/// tell an IPTV channel from a Plex tuner channel.
struct IPTVPlayableChannel: Hashable, Sendable {
    let sourceID: UUID
    let streamURL: URL
    /// Source header plus the entry's referrer / pipe headers. Applied to the
    /// playlist, segments, certificate and license requests.
    let headers: [String: String]
    let userAgent: String?
    let drm: IPTVDRMConfiguration?
}

/// A loaded source, ready for the guide.
struct IPTVSourceLineup: Hashable, Sendable {
    let source: IPTVSource
    let lineup: PlexLiveTVLineup
    /// A guide that failed to load does not hide the channels; it is noted.
    let guideError: String?
}

enum IPTVImages {
    /// Sentinel "server" for IPTV artwork. Logos and programme icons are
    /// absolute URLs on arbitrary hosts; `PlexService.imageURL` returns them
    /// untouched for this server ID instead of routing them through a Plex
    /// photo transcoder, which may not even be connected.
    static let serverID = "dusk.iptv"
}
