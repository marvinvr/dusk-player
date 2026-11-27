import Foundation

/// Rewrites a Plex fMP4 HLS remux's playlists so a Dolby Vision profile 7
/// stream plays as profile 8.1 through the local conversion proxy.
///
/// Every URI is resolved against the playlist's URL and handed to the
/// `URLMapper`: variant and rendition playlists, the `EXT-X-MAP` init
/// segment, and media segments (with the init segment in effect, so the
/// proxy knows which track layout a segment belongs to). Variants gain the
/// backward-compatible 8.1 signaling `DolbyVisionSignaling` writes for
/// native profile 8; I-frame variants are dropped (their samples would not
/// be converted). Anything the proxy cannot serve converted — byte ranges,
/// encryption, a variant that cannot carry `dvh1.08`, a segment outside
/// any `EXT-X-MAP` of an fMP4 playlist — throws `.unsupportedPlaylist` (as
/// may the mapper) so the caller falls back to the plain remux: an
/// unconverted profile 7 sample must never play behind 8.1 signaling.
enum DolbyVision7PlaylistRewriter {
    struct URLMapper: Sendable {
        /// `isVideo`: an `EXT-X-STREAM-INF` variant (or a `TYPE=VIDEO`
        /// rendition), as opposed to a subtitle or audio rendition.
        let playlist: @Sendable (_ playlist: URL, _ isVideo: Bool) throws -> URL
        let initSegment: @Sendable (URL) throws -> URL
        /// `initSegment` is nil only for segments of a playlist without any
        /// `EXT-X-MAP` (WebVTT), which the mapper may leave on the server.
        let mediaSegment: @Sendable (_ segment: URL, _ initSegment: URL?) throws -> URL
    }

    /// - Parameter requiresInitSegment: the playlist is a video variant:
    ///   every media segment must follow an `EXT-X-MAP`. Any playlist that
    ///   uses `EXT-X-MAP` at all is held to that too.
    static func rewrite(
        _ text: String,
        baseURL: URL,
        target: DolbyVisionConfiguration,
        fallbackCodecs: String? = nil,
        requiresInitSegment: Bool = false,
        mapper: URLMapper
    ) throws -> String {
        var lines: [String] = []
        var nextURIIsVariant = false
        var currentMap: URL?
        let segmentsNeedInitSegment = requiresInitSegment || text.contains("#EXT-X-MAP")

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                lines.append(try variantLine(line, target: target, fallbackCodecs: fallbackCodecs))
                nextURIIsVariant = true
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") {
                continue
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let isVideo = HLSAttributeList(line: line)?.value(of: "TYPE") == "VIDEO"
                lines.append(try mappingURIAttribute(in: line, baseURL: baseURL) { try mapper.playlist($0, isVideo) })
            } else if line.hasPrefix("#EXT-X-MAP") {
                guard let attributes = HLSAttributeList(line: line),
                      attributes.quotedValue(of: "BYTERANGE") == nil,
                      let uri = attributes.quotedValue(of: "URI") else {
                    throw DolbyVision7ConversionError.unsupportedPlaylist("EXT-X-MAP without a plain URI")
                }
                let initSegment = try resolve(uri, against: baseURL)
                currentMap = initSegment
                var mapped = attributes
                mapped.setQuoted("URI", to: try mapper.initSegment(initSegment).absoluteString)
                lines.append(mapped.line)
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                throw DolbyVision7ConversionError.unsupportedPlaylist("EXT-X-BYTERANGE")
            } else if line.hasPrefix("#EXT-X-PART:") || line.hasPrefix("#EXT-X-PRELOAD-HINT") {
                // Low-latency partial segments would reach AVPlayer unconverted.
                throw DolbyVision7ConversionError.unsupportedPlaylist("low-latency HLS parts")
            } else if line.hasPrefix("#EXT-X-KEY") {
                let method = HLSAttributeList(line: line)?.value(of: "METHOD")
                guard method == "NONE" else {
                    throw DolbyVision7ConversionError.unsupportedPlaylist("EXT-X-KEY METHOD=\(method ?? "?")")
                }
                lines.append(line)
            } else if line.isEmpty || line.hasPrefix("#") {
                lines.append(line)
            } else {
                let url = try resolve(line, against: baseURL)
                if nextURIIsVariant {
                    lines.append(try mapper.playlist(url, true).absoluteString)
                    nextURIIsVariant = false
                } else {
                    guard currentMap != nil || !segmentsNeedInitSegment else {
                        throw DolbyVision7ConversionError.unsupportedPlaylist("media segment without EXT-X-MAP")
                    }
                    lines.append(try mapper.mediaSegment(url, currentMap).absoluteString)
                }
            }
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The variant with 8.1 signaling, which must have landed: an `hvc1`
    /// entry kept in `CODECS` and the target's `dvh1.08` in
    /// `SUPPLEMENTAL-CODECS` (a `hev1`, non-HEVC or `dvh1.07` variant is
    /// left alone by `rewrittenStreamInfLine`). A variant without `CODECS`
    /// takes `fallbackCodecs` first (`RemuxVariantCodecs`).
    private static func variantLine(
        _ line: String,
        target: DolbyVisionConfiguration,
        fallbackCodecs: String?
    ) throws -> String {
        let rewritten = DolbyVisionSignaling.rewrittenStreamInfLine(
            line, configuration: target, fallbackCodecs: fallbackCodecs
        )
        let attributes = HLSAttributeList(line: rewritten)
        let codecs = codecList(attributes?.quotedValue(of: "CODECS"))
        let supplemental = codecList(attributes?.quotedValue(of: "SUPPLEMENTAL-CODECS"))
        guard let expected = target.supplementalCodecString,
              supplemental.contains(expected.lowercased()),
              codecs.contains(where: { $0.hasPrefix("hvc1") }),
              !codecs.contains(where: { $0.hasPrefix("hev1") }) else {
            throw DolbyVision7ConversionError.unsupportedPlaylist("variant cannot carry Dolby Vision 8.1")
        }
        return rewritten
    }

    private static func codecList(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func mappingURIAttribute(
        in line: String,
        baseURL: URL,
        using map: (URL) throws -> URL
    ) throws -> String {
        guard line.contains("URI=") else { return line }
        guard var attributes = HLSAttributeList(line: line), let uri = attributes.quotedValue(of: "URI") else {
            throw DolbyVision7ConversionError.unsupportedPlaylist("unparseable URI attribute")
        }
        attributes.setQuoted("URI", to: try map(try resolve(uri, against: baseURL)).absoluteString)
        return attributes.line
    }

    /// RFC 3986 resolution: a relative reference drops the base's query and
    /// keeps its own.
    private static func resolve(_ uri: String, against baseURL: URL) throws -> URL {
        guard let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
            throw DolbyVision7ConversionError.unsupportedPlaylist("unresolvable URI")
        }
        return url
    }
}
