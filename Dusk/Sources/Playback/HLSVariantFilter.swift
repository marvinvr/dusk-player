import Foundation

/// Keeps a server's HLS master to the one stream Dusk asked for
/// (`PlaybackTraits.remuxNeedsVariantFilter`, docs/jellyfin/04-architecture.md
/// §12.3).
///
/// Jellyfin's master for an HDR source always adds a tone-mapped H.264 SDR
/// variant at the same bandwidth (Dolby Vision 5 a third, plain HEVC, one),
/// and AVPlayer picks variants by display: on an SDR panel it would take the
/// tone-mapped one and start a 4K re-encode nobody asked for (03 §5.2). The
/// first variant is always the one the request's profile describes. The
/// master also lists every text subtitle as a rendition, the requested one
/// `DEFAULT=YES`; Plex's lists only the requested one, which is what the
/// player expects.
enum HLSVariantFilter {
    /// The master with only its first `EXT-X-STREAM-INF` variant, no I-frame
    /// or image (trickplay) variants, and only the `DEFAULT=YES` subtitle
    /// rendition (none when subtitles are off; the variant's `SUBTITLES`
    /// group goes with them). With `keepsDolbyVision` false a `dvh1`/`dvhe`
    /// entry leaves `SUPPLEMENTAL-CODECS`: the server advertises it even
    /// when it stripped Dolby Vision from the stream (03 §5.3). HDR10+'s
    /// `…/cdm4` stays. A media playlist comes back unchanged.
    static func firstVariantOnly(_ playlist: String, keepsDolbyVision: Bool) -> String {
        guard playlist.contains("#EXT-X-STREAM-INF") else { return playlist }
        let lines = playlist.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var keptSubtitleGroups = Set<String>()
        for line in lines where isSubtitleRendition(line) {
            if let attributes = HLSAttributeList(line: line), attributes.value(of: "DEFAULT") == "YES",
               let group = attributes.quotedValue(of: "GROUP-ID") {
                keptSubtitleGroups.insert(group)
            }
        }

        var output: [String] = []
        var hasVariant = false
        var dropsNextURI = false
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                if hasVariant {
                    dropsNextURI = true
                } else {
                    hasVariant = true
                    output.append(pinnedVariantLine(line, keepsDolbyVision: keepsDolbyVision, subtitleGroups: keptSubtitleGroups))
                }
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") || line.hasPrefix("#EXT-X-IMAGE-STREAM-INF") {
                continue
            } else if isSubtitleRendition(line) {
                if HLSAttributeList(line: line)?.value(of: "DEFAULT") == "YES" { output.append(line) }
            } else if !line.isEmpty, !line.hasPrefix("#") {
                if dropsNextURI {
                    dropsNextURI = false
                } else {
                    output.append(line)
                }
            } else {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }

    private static func isSubtitleRendition(_ line: String) -> Bool {
        line.hasPrefix("#EXT-X-MEDIA:") && HLSAttributeList(line: line)?.value(of: "TYPE") == "SUBTITLES"
    }

    private static func pinnedVariantLine(_ line: String, keepsDolbyVision: Bool, subtitleGroups: Set<String>) -> String {
        guard var attributes = HLSAttributeList(line: line) else { return line }
        if let group = attributes.quotedValue(of: "SUBTITLES"), !subtitleGroups.contains(group) {
            attributes.remove("SUBTITLES")
        }
        if !keepsDolbyVision, let supplemental = attributes.quotedValue(of: "SUPPLEMENTAL-CODECS") {
            let kept = supplemental.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { entry in
                    let lowered = entry.lowercased()
                    return !entry.isEmpty && !lowered.hasPrefix("dvh1") && !lowered.hasPrefix("dvhe")
                }
            if kept.isEmpty {
                attributes.remove("SUPPLEMENTAL-CODECS")
            } else {
                attributes.setQuoted("SUPPLEMENTAL-CODECS", to: kept.joined(separator: ","))
            }
        }
        return attributes.line
    }
}
