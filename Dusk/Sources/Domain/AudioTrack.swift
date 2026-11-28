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
    /// Plex stream id backing this track, when known (from merged part
    /// metadata). Used to pin a server transcode to this exact audio stream
    /// when the local engine cannot decode it.
    var plexStreamID: String? = nil
    /// Whether the engine that produced this track can actually decode it.
    /// A stock VLCKit build ships without TrueHD/MLP, and Dusk's own TrueHD
    /// decoder can still fail on a stream (`failedAudioDecoderTrackID`), so a
    /// track can exist in the container yet be unplayable: selecting its ES
    /// kills the working audio and leaves silence. Automatic selection
    /// skips undecodable tracks; picking one in the picker reroutes playback
    /// through a server transcode pinned to the stream instead.
    var isDecodable: Bool = true

    var compactDisplayTitle: String {
        let title = Self.trimmed(displayTitle)
        guard let bitrateSeparatorRange = title.range(of: " @ ") else {
            return title
        }

        let compactTitle = Self.trimmed(String(title[..<bitrateSeparatorRange.lowerBound]))
        return compactTitle.isEmpty ? title : compactTitle
    }

    var detailDisplayTitle: String? {
        let title = Self.trimmed(displayTitle)
        let compactTitle = compactDisplayTitle

        if title != compactTitle {
            return title
        }

        guard let language = language.map(Self.trimmed),
              !language.isEmpty,
              !compactTitle.localizedCaseInsensitiveContains(language) else {
            return nil
        }

        return language
    }
}

extension AudioTrack {
    /// Create from a Plex audio stream.
    init(stream: MediaStream) {
        // The engine track id; a track built from metadata has none, so it
        // reuses the Plex stream number (0 for an id that is not one).
        self.id = Int(stream.id) ?? 0
        self.displayTitle = stream.displayTitle ?? stream.language ?? "Unknown"
        self.language = stream.language
        self.languageCode = stream.languageCode
        self.codec = stream.codec
        self.channels = stream.channels
        self.channelLayout = stream.channelLayout
        self.plexStreamID = stream.id
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
