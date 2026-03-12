import Foundation

/// An app-level subtitle track used by the playback engine.
/// Decoupled from Plex API models so either engine can produce these.
struct SubtitleTrack: Sendable, Identifiable, Hashable {
    let id: Int
    let displayTitle: String
    let language: String?
    let languageCode: String?
    let codec: String?
    let isForced: Bool
    let isHearingImpaired: Bool
    let isExternal: Bool

    /// For external (sidecar) subtitle files, the URL to fetch them.
    let externalURL: URL?
}

extension SubtitleTrack {
    /// Create from a Plex subtitle stream.
    init(stream: PlexStream) {
        self.id = stream.id
        self.displayTitle = stream.displayTitle ?? stream.language ?? "Unknown"
        self.language = stream.language
        self.languageCode = stream.languageCode
        self.codec = stream.codec
        self.isForced = stream.isForced ?? false
        self.isHearingImpaired = stream.isHearingImpaired ?? false
        self.isExternal = stream.key != nil
        self.externalURL = nil // Constructed at playback time with server URL + token
    }
}
