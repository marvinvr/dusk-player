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
    /// Plex stream id backing this engine track, when metadata matching found
    /// one. AirPlay uses it to rebuild the server-rendered HLS selection.
    var plexStreamID: Int? = nil

    /// For external (sidecar) subtitle files, the URL to fetch them.
    let externalURL: URL?

    /// True for a Plex sidecar the *current* engine cannot mount (AVPlayer),
    /// so picking it restarts the session on VLCKit. Automatic selection never
    /// chooses one of these — swapping engines is the viewer's call.
    var requiresEngineSwitch = false
}

extension SubtitleTrack {
    /// Secondary line in the player's subtitle pickers.
    /// Forced / SDH are named here: AVPlayer adds a forced-only copy of each
    /// track with the same title, and the two rows looked identical.
    var pickerDetailTitle: String? {
        var parts: [String] = []
        if let language, !language.isEmpty { parts.append(language) }
        // Plex titles often say it already ("English Forced (SRT)").
        let title = displayTitle.lowercased()
        if isForced, !title.contains("forced") { parts.append("Forced") }
        if isHearingImpaired, !title.contains("sdh"), !title.contains("hearing") { parts.append("SDH") }
        if isExternal {
            parts.append(requiresEngineSwitch ? "External · switches to VLC engine" : "External")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
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
        self.plexStreamID = stream.id
        self.externalURL = nil // Constructed at playback time with server URL + token
    }
}
