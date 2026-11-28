import Foundation

/// One OpenSubtitles candidate returned by Plex's server-side subtitle search
/// (`GET /library/metadata/{itemID}/subtitles`).
///
/// Plex proxies OpenSubtitles itself, so Dusk needs no OpenSubtitles account or
/// API key. Every field except `key` is optional: the shape varies by server
/// version, agent, and provider, and some servers answer `size: 0` with no
/// `Stream` array at all.
///
/// `key` is the provider-scoped handle (for example
/// `com.plexapp.agents.opensubtitles:///...`) that identifies the candidate when
/// asking the server to download it. It is required, because a result we cannot
/// download is useless to the UI.
struct SubtitleSearchResult: Identifiable, Sendable, Hashable {
    /// Stable identity for SwiftUI lists.
    ///
    /// Search results are not library streams, so most servers send `id: 0` (or
    /// omit it). When the server sends a real non-zero id we use it; otherwise
    /// the provider `key` is the identity, which is stable for a given search.
    let id: String
    /// Provider-specific download handle. Passed straight back to Plex.
    let key: String
    let codec: String?
    let title: String?
    /// Usually `"OpenSubtitles"`.
    let providerTitle: String?
    let sourceTitle: String?
    /// Plex's match score (0...100). Sent as int, double, or string depending on
    /// the server, so it is decoded leniently and rounded.
    let score: Int?
    /// Plex sends ISO 639-2/B here (`eng`), not the 639-1 code used for search.
    let languageCode: String?
    /// Human-readable language name (`English`).
    let language: String?
    let isHearingImpaired: Bool?
    let isForced: Bool?
    /// File format (`srt`, `ass`, ...). Often identical to `codec`.
    let format: String?

    /// Memberwise init for previews, tests, and synthesized rows.
    init(
        id: String? = nil,
        key: String,
        codec: String? = nil,
        title: String? = nil,
        providerTitle: String? = nil,
        sourceTitle: String? = nil,
        score: Int? = nil,
        languageCode: String? = nil,
        language: String? = nil,
        isHearingImpaired: Bool? = nil,
        isForced: Bool? = nil,
        format: String? = nil
    ) {
        self.id = id ?? key
        self.key = key
        self.codec = codec
        self.title = title
        self.providerTitle = providerTitle
        self.sourceTitle = sourceTitle
        self.score = score
        self.languageCode = languageCode
        self.language = language
        self.isHearingImpaired = isHearingImpaired
        self.isForced = isForced
        self.format = format
    }

    /// Primary label for a result row.
    var displayTitle: String {
        title?.nonBlank ?? sourceTitle?.nonBlank ?? "Subtitle"
    }

    /// The file extension Plex should be told to write, preferring the explicit
    /// `format` and falling back to `codec`.
    var fileFormat: String? {
        format?.nonBlank ?? codec?.nonBlank
    }

    /// Secondary label, e.g. `OpenSubtitles · srt · Score 82 · HI`.
    var detailText: String {
        var parts: [String] = []
        if let provider = providerTitle?.nonBlank ?? sourceTitle?.nonBlank, provider != displayTitle {
            parts.append(provider)
        }
        if let fileFormat {
            parts.append(fileFormat.lowercased())
        }
        if let score {
            parts.append("Score \(score)")
        }
        if isHearingImpaired == true {
            parts.append("HI")
        }
        if isForced == true {
            parts.append("Forced")
        }
        return parts.joined(separator: " · ")
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
