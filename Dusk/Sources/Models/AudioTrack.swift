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
    init(stream: PlexStream) {
        self.id = stream.id
        self.displayTitle = stream.displayTitle ?? stream.language ?? "Unknown"
        self.language = stream.language
        self.languageCode = stream.languageCode
        self.codec = stream.codec
        self.channels = stream.channels
        self.channelLayout = stream.channelLayout
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
