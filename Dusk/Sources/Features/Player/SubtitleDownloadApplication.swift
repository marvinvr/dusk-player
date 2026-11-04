import CryptoKit
import Foundation

/// Tells whether Plex has actually applied a subtitle download yet.
///
/// The download PUT returns before Plex has refreshed the item, so a refetch
/// right after it can still describe (and serve) the previous sidecar. The
/// player polls briefly until one of these signals flips, then reloads.
enum SubtitleDownloadApplication {
    /// The fields Plex rewrites when it installs a sidecar. A second download
    /// in the same language may keep the id and key, so the rest is compared too.
    struct SidecarSignature: Hashable, Sendable {
        let id: Int
        let key: String?
        let codec: String?
        let displayTitle: String?
        let extendedDisplayTitle: String?
        let language: String?
        let isForced: Bool?
        let isHearingImpaired: Bool?

        init(_ stream: PlexStream) {
            id = stream.id
            key = stream.key
            codec = stream.codec
            displayTitle = stream.displayTitle
            extendedDisplayTitle = stream.extendedDisplayTitle
            language = PlayerViewModel.normalizedLanguageCode(stream.languageCode ?? stream.language)
            isForced = stream.isForced
            isHearingImpaired = stream.isHearingImpaired
        }
    }

    /// Delays before each refetch: immediate, then backing off to ~6 s in total.
    static let pollDelays: [Duration] = [
        .zero, .milliseconds(500), .milliseconds(750), .seconds(1), .seconds(1), .milliseconds(1500), .milliseconds(1500),
    ]

    /// Sidecar subtitle streams in `language` (all when nil).
    static func sidecars(in streams: [PlexStream], language: String?) -> [PlexStream] {
        streams.filter { stream in
            stream.streamType == .subtitle && stream.key != nil
                && (language == nil
                    || PlayerViewModel.normalizedLanguageCode(stream.languageCode ?? stream.language) == language)
        }
    }

    /// True when `after` holds a sidecar (in the downloaded language, when
    /// known) that `before` did not have with the same signature. A sidecar
    /// merely disappearing does not count: Plex can drop the old stream a
    /// moment before the new one shows up.
    static func hasNewSidecar(before: [PlexStream], after: [PlexStream], language: String?) -> Bool {
        let previous = Set(sidecars(in: before, language: nil).map(SidecarSignature.init))
        return sidecars(in: after, language: language).contains { !previous.contains(SidecarSignature($0)) }
    }

    static func digest(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
