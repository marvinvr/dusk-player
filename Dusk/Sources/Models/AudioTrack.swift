import Foundation

/// An app-level audio track used by the playback engine.
/// Decoupled from Plex API models so either engine can produce these.
struct AudioTrack: Sendable, Identifiable, Hashable {
    let id: Int
    let displayTitle: String
    let language: String?
    let languageCode: String?
    let codec: String?
    let channels: Int?
    let channelLayout: String?
}

extension AudioTrack {
    /// Create from a Plex audio stream.
    init(stream: PlexStream) {
        self.id = stream.id
        self.displayTitle = stream.displayTitle ?? stream.language ?? "Unknown"
        self.language = stream.language
        self.languageCode = stream.languageCode
        self.codec = stream.codec
        self.channels = stream.channels
        self.channelLayout = stream.channelLayout
    }
}
