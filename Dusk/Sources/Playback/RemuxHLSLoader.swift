import AVFoundation
import Foundation
import OSLog

private let atmosSignalingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "AtmosSignaling"
)

/// Restores Dolby Atmos signaling on Plex's fragmented-MP4 HLS remux.
///
/// Plex's transcoder copies an E-AC-3 + JOC (Dolby Atmos) bitstream into
/// fMP4 segments intact, but writes a 13-byte `dec3` box without the
/// `flag_ec3_extension_type_a` / `complexity_index_type_a` trailer. AVFoundation
/// derives the track's format from that box, so it sees plain 5.1 E-AC-3 and
/// never offers the Atmos (`ec+3`) layer — no Atmos over HDMI, no multichannel
/// spatial audio. (MPEG-TS remuxes are unaffected: AVFoundation reads the
/// signaling from the bitstream there, but HEVC cannot ride MPEG-TS HLS.)
///
/// Only use it for streams Plex reports as Atmos: the patch asserts JOC, and
/// a plain E-AC-3 track must not be labelled Atmos.
///
/// `RemuxHLSLoader` sits in front of the stream as an
/// `AVAssetResourceLoader` delegate. It rewrites the playlists so only the
/// init segment (`EXT-X-MAP`) comes back through it, patches that segment's
/// `dec3`, and points every media segment straight at the server — segment
/// traffic never passes through the app.
enum EAC3JOCSignaling {
    /// Complexity index written into the restored trailer. Plex does not
    /// surface the bitstream's value; 16 is what Dolby's encoders emit for
    /// streaming DD+ Atmos, and what ffmpeg reproduces from those streams.
    static let defaultComplexityIndex: UInt8 = 16

    private static let containerHeaderPadding: [String: Int] = [
        "moov": 0, "trak": 0, "mdia": 0, "minf": 0, "stbl": 0,
        "stsd": 8,    // full box header + entry count
        "ec-3": 28,   // AudioSampleEntry fields
    ]

    /// Returns the init segment with the JOC trailer appended to every
    /// `dec3` box that lacks one (and every enclosing box resized), or nil
    /// when there was nothing to patch or the data is not a parseable MP4.
    static func patchedInitSegment(
        _ data: Data,
        complexityIndex: UInt8 = defaultComplexityIndex
    ) -> Data? {
        var didPatch = false
        guard let patched = MP4BoxRewriter.rewrite(
            [UInt8](data),
            containerHeaderPadding: containerHeaderPadding,
            transform: { type, box in
                guard type == "dec3",
                      let extended = extendedDEC3(box, complexityIndex: complexityIndex) else {
                    return nil
                }
                didPatch = true
                return extended
            }
        ), didPatch else {
            return nil
        }
        return Data(patched)
    }

    /// `dec3` payload: data_rate(13) num_ind_sub(3), then per independent
    /// substream fscod(2) bsid(5) reserved(1) asvc(1) bsmod(3) acmod(3)
    /// lfeon(1) reserved(3) num_dep_sub(4) and either chan_loc(9) or
    /// reserved(1) — three bytes each. An optional trailer follows:
    /// reserved(7) flag_ec3_extension_type_a(1) complexity_index_type_a(8).
    private static func extendedDEC3(_ box: [UInt8], complexityIndex: UInt8) -> [UInt8]? {
        let payload = box.count - 8
        guard payload >= 2 else { return nil }
        let independentSubstreams = Int(box[9] & 0x07) + 1
        let baseLength = 2 + independentSubstreams * 3
        // Already carries a trailer (or is something we do not understand).
        guard payload == baseLength else { return nil }

        var extended = box + [0x01, complexityIndex]
        MP4BoxRewriter.writeUInt32(UInt32(extended.count), into: &extended, at: 0)
        return extended
    }
}

/// The Dolby Vision configuration of a stream, as Plex reports it.
struct DolbyVisionConfiguration: Sendable, Equatable {
    let profile: Int
    let level: Int
    let blSignalCompatibilityID: Int
    /// Luma samples per second (width × height × fps), when Plex reports all three.
    let lumaSampleRate: Double?
    /// Luma samples per picture, when Plex reports the dimensions.
    let lumaPictureSize: Double?
    /// Average video bitrate in kbit/s, when Plex reports it.
    let bitrateKbps: Int?
    /// The source profile when this is the target of an on-device
    /// conversion (Dolby Vision 7 played as 8.1); nil for Plex's own.
    let convertedFromProfile: Int?

    init(
        profile: Int,
        level: Int,
        blSignalCompatibilityID: Int,
        lumaSampleRate: Double?,
        lumaPictureSize: Double?,
        bitrateKbps: Int?,
        convertedFromProfile: Int? = nil
    ) {
        self.profile = profile
        self.level = level
        self.blSignalCompatibilityID = blSignalCompatibilityID
        self.lumaSampleRate = lumaSampleRate
        self.lumaPictureSize = lumaPictureSize
        self.bitrateKbps = bitrateKbps
        self.convertedFromProfile = convertedFromProfile
    }

    init?(stream: MediaStream) {
        guard let profile = stream.dolbyVision?.profile, (0...127).contains(profile) else { return nil }
        self.profile = profile
        self.level = stream.dolbyVision?.level.flatMap { (1...63).contains($0) ? $0 : nil }
            ?? Self.fallbackLevel(for: stream)
        self.blSignalCompatibilityID = min(max(stream.dolbyVision?.blCompatID ?? 0, 0), 15)
        if let width = stream.width, let height = stream.height, width > 0, height > 0 {
            lumaPictureSize = Double(width) * Double(height)
            lumaSampleRate = stream.frameRate.flatMap { $0 > 0 ? Double(width) * Double(height) * $0 : nil }
        } else {
            lumaPictureSize = nil
            lumaSampleRate = nil
        }
        bitrateKbps = stream.bitrate.flatMap { $0 > 0 ? $0 : nil }
        convertedFromProfile = nil
    }

    /// Profile 8.1 at the same level and stream metrics: what a profile 7
    /// stream becomes once its RPUs are converted and its enhancement layer
    /// dropped (`DolbyVision7InitRewriter`, `FMP4FragmentRewriter`).
    func convertedToProfile81() -> DolbyVisionConfiguration {
        DolbyVisionConfiguration(
            profile: 8,
            level: level,
            blSignalCompatibilityID: 1,
            lumaSampleRate: lumaSampleRate,
            lumaPictureSize: lumaPictureSize,
            bitrateKbps: bitrateKbps,
            convertedFromProfile: profile
        )
    }

    /// RFC 6381 codec string for an HLS `CODECS` attribute, e.g. `dvh1.05.06`.
    var codecString: String {
        codecString(sampleEntry: "dvh1")
    }

    /// Same, for the sample-entry family actually in the file (`dvhe` when
    /// the HEVC entry was `hev1`).
    func codecString(sampleEntry: String) -> String {
        String(format: "%@.%02d.%02d", sampleEntry, profile, level)
    }

    /// Whether the content provably fits HEVC level 5.1 for `highTier`:
    /// picture size, luma sample rate and (average) bitrate all within the
    /// level's limits. Missing metadata means "unknown" — never true.
    func fitsHEVCLevel51(highTier: Bool) -> Bool {
        guard let lumaPictureSize, let lumaSampleRate, let bitrateKbps else { return false }
        return lumaPictureSize <= 8_912_896
            && lumaSampleRate <= 534_773_760
            && bitrateKbps <= (highTier ? 160_000 : 40_000)
    }

    /// Profile 8.1 (HDR10 base) and 8.4 (HLG base): the base layer is plain
    /// HEVC every decoder can show, so the track stays `hvc1` and Dolby Vision
    /// is announced alongside it (`dvvC` + `SUPPLEMENTAL-CODECS`) instead of
    /// replacing it. Profile 5 has no such base and must be relabelled.
    var hasCompatibleBaseLayer: Bool {
        profile == 8 && (blSignalCompatibilityID == 1 || blSignalCompatibilityID == 4)
    }

    /// The base layer is HLG (profile 8.4) rather than HDR10 (8.1).
    var hasHLGBaseLayer: Bool {
        hasCompatibleBaseLayer && blSignalCompatibilityID == 4
    }

    /// HLS `SUPPLEMENTAL-CODECS` value for a backward-compatible stream,
    /// e.g. `dvh1.08.06/db1p` (8.1) or `dvh1.08.06/db4h` (8.4).
    var supplementalCodecString: String? {
        guard hasCompatibleBaseLayer else { return nil }
        return codecString + (hasHLGBaseLayer ? "/db4h" : "/db1p")
    }

    /// Short human label, e.g. `Dolby Vision 8.1` or, converted,
    /// `Dolby Vision 8.1 (from profile 7)`.
    var displayName: String {
        let name = hasCompatibleBaseLayer
            ? "Dolby Vision \(profile).\(blSignalCompatibilityID)"
            : "Dolby Vision profile \(profile)"
        return convertedFromProfile.map { "\(name) (from profile \($0))" } ?? name
    }

    /// The level Dolby's pixel-rate table gives the stream, for when Plex
    /// omits `DOVILevel`.
    private static func fallbackLevel(for stream: MediaStream) -> Int {
        let width = Double(stream.width ?? 3840)
        let height = Double(stream.height ?? 2160)
        let frameRate = stream.frameRate ?? 24
        let pixelRate = width * height * frameRate
        let maxPixelRates: [(level: Int, rate: Double)] = [
            (1, 22_118_400), (2, 27_648_000), (3, 49_766_400), (4, 62_208_000),
            (5, 124_416_000), (6, 199_065_600), (7, 248_832_000), (8, 398_131_200),
            (9, 497_664_000), (10, 995_328_000), (11, 995_328_000), (12, 1_990_656_000),
            (13, 3_981_312_000),
        ]
        return maxPixelRates.first { pixelRate <= $0.rate * 1.01 }?.level ?? 13
    }
}

/// RFC 6381 `CODECS` for a Plex fMP4 remux variant, rebuilt from Plex's
/// metadata for masters that omit the attribute (PMS writes
/// `#EXT-X-STREAM-INF:…,VIDEO-RANGE=PQ` with no `CODECS` on copy and
/// converted-audio remuxes alike). The result matches what Plex writes when
/// it does include one, e.g. `hvc1.2.4.L153.b0,ec-3`: Main tier, Plex's
/// reported level, the source's sample-entry family. The decoder reads the
/// real profile/tier/level from `hvcC`; this only declares the variant so
/// `DolbyVisionSignaling` can add `dvh1` (profile 5) or
/// `SUPPLEMENTAL-CODECS` (8.1/8.4, and DV7 converted to 8.1).
enum RemuxVariantCodecs {
    /// The full attribute value, or nil when the video is not HEVC Main/Main
    /// 10 or the remux audio has no known codec string (a wrong or partial
    /// declaration is worse than none).
    static func codecs(video: MediaStream, audioCodec: String?, hasAudio: Bool) -> String? {
        guard let videoCodec = hevcCodec(for: video) else { return nil }
        guard hasAudio else { return videoCodec }
        guard let audio = audioCodecString(audioCodec) else { return nil }
        return "\(videoCodec),\(audio)"
    }

    /// `hvc1.2.4.L153.b0` (Main 10) / `hvc1.1.6.L120.b0` (Main); `hev1` when
    /// the source's sample entry is `hev1`/`dvhe`, which a remux keeps.
    static func hevcCodec(for stream: MediaStream) -> String? {
        guard stream.kind == .video, stream.codec?.lowercased() == "hevc" else { return nil }
        let profile: String
        // Every Dolby Vision profile Dusk signals is Main 10 ("main 10").
        let reported = stream.profile?.lowercased().trimmingCharacters(in: .whitespaces)
            ?? ((stream.bitDepth ?? 10) > 8 ? "main 10" : "main")
        switch reported {
        case "main 10", "main10": profile = "2.4"
        case "main": profile = "1.6"
        default: return nil
        }
        let family = ["hev1", "dvhe"].contains(stream.codecID?.lowercased() ?? "") ? "hev1" : "hvc1"
        let level = stream.level.flatMap { validLevels.contains($0) ? $0 : nil } ?? fallbackLevel(for: stream)
        return "\(family).\(profile).L\(level).b0"
    }

    /// Plex's codec name for the remux audio → its HLS codec string.
    static func audioCodecString(_ codec: String?) -> String? {
        switch codec?.lowercased() {
        case "eac3": "ec-3"
        case "ac3": "ac-3"
        case "aac": "mp4a.40.2"
        default: nil
        }
    }

    /// general_level_idc values (30 × level).
    private static let validLevels: Set<Int> = [30, 60, 63, 90, 93, 120, 123, 150, 153, 156, 180, 183, 186]

    /// Lowest level whose MaxLumaPs/MaxLumaSr fit the stream, for when Plex
    /// reports no level.
    private static func fallbackLevel(for stream: MediaStream) -> Int {
        let pictureSize = Double(stream.width ?? 3840) * Double(stream.height ?? 2160)
        let sampleRate = pictureSize * (stream.frameRate ?? 24)
        let limits: [(level: Int, pictureSize: Double, sampleRate: Double)] = [
            (120, 2_228_224, 66_846_720), (123, 2_228_224, 133_693_440),
            (150, 8_912_896, 267_386_880), (153, 8_912_896, 534_773_760),
            (156, 8_912_896, 1_069_547_520), (183, 35_651_584, 1_069_547_520),
        ]
        return limits.first { pictureSize <= $0.pictureSize && sampleRate <= $0.sampleRate }?.level ?? 186
    }
}

/// Restores Dolby Vision signaling on Plex's fragmented-MP4 HLS remux.
///
/// Plex copies a Dolby Vision HEVC bitstream (RPU NAL units included) into
/// fMP4 segments but labels the track as plain HEVC (`hvc1`) with no
/// configuration box, so AVFoundation never applies the RPU.
///
/// - Profile 5 has no HDR10/SDR-compatible base layer; decoded as HEVC its
///   IPTPQc2 color is green/purple garbage. The sample entry is relabelled
///   `dvh1` with a `dvcC` box — how Apple devices render DV5 from any MP4 —
///   and the playlist's `CODECS` entry is rewritten to match.
/// - Profile 8.1/8.4 keeps its `hvc1` entry (the HDR10/HLG base stays
///   decodable everywhere) and gains a `dvvC` box plus a
///   `SUPPLEMENTAL-CODECS="dvh1.08.LL/db1p|db4h"` variant attribute, the
///   backward-compatible packaging Apple's HLS spec uses for these profiles.
///   AVPlayer then applies the RPU (real Dolby Vision on a DV display,
///   RPU-guided tone mapping elsewhere).
enum DolbyVisionSignaling {
    private static let containerHeaderPadding: [String: Int] = [
        "moov": 0, "trak": 0, "mdia": 0, "minf": 0, "stbl": 0,
        "stsd": 8,    // full box header + entry count
    ]

    /// VisualSampleEntry fields between the box header and its child boxes.
    private static let visualSampleEntryFieldsLength = 78

    private static let sampleEntryRenames: [String: String] = [
        "hvc1": "dvh1",
        "hev1": "dvhe",
    ]

    /// Level a profile 8 variant's HEVC `CODECS` entry is lowered to when
    /// the source over-declares. tvOS 27 refuses a Dolby Vision master that
    /// declares level 5.2 (`L156`) with -11848, while the same 4K24 stream
    /// declared 5.1 plays with Dolby Vision engaged (AetherEngine #674).
    /// Only applied when the content provably fits 5.1
    /// (`DolbyVisionConfiguration.fitsHEVCLevel51`), so the declaration is
    /// never lower than what the stream needs; only the playlist changes,
    /// the decoder reads `hvcC`.
    static let cappedHEVCLevel = 153

    /// Returns the init segment with every HEVC sample entry signalled as
    /// Dolby Vision (relabelled for profile 5, kept `hvc1` for 8.1/8.4) and
    /// given a `dvcC`/`dvvC` box when it has none, or nil when there was
    /// nothing to patch or the data is not a parseable MP4.
    static func patchedInitSegment(_ data: Data, configuration: DolbyVisionConfiguration) -> Data? {
        var didPatch = false
        guard let patched = MP4BoxRewriter.rewrite(
            [UInt8](data),
            containerHeaderPadding: containerHeaderPadding,
            transform: { type, box in
                guard let renamed = sampleEntryRenames[type] else { return nil }
                // Profile 8 is signalled only on `hvc1` (Apple requires it for
                // 8.4, and `hev1` keeps its parameter sets in-band); a `hev1`
                // entry stays plain HEVC, matching `rewrittenStreamInfLine`.
                if configuration.hasCompatibleBaseLayer && type != "hvc1" { return nil }
                let entryType = configuration.hasCompatibleBaseLayer ? type : renamed
                guard let entry = dolbyVisionSampleEntry(box, type: entryType, configuration: configuration),
                      entry != box else {
                    return nil
                }
                didPatch = true
                return entry
            }
        ), didPatch else {
            return nil
        }
        return Data(patched)
    }

    /// Rewrites an `EXT-X-STREAM-INF` line so the variant announces Dolby
    /// Vision; AVFoundation picks the decoder for a variant from it before
    /// it ever reads the init segment.
    ///
    /// - Profile 5 replaces the HEVC `CODECS` entry with `dvh1.05.LL`
    ///   (`dvhe` for a `hev1` entry, matching the renamed sample entry).
    /// - 8.1/8.4 keep the `hvc1` entry (level capped only when the content
    ///   fits, see `cappedHEVCLevel`), merge `dvh1.08.LL/db1p|db4h` into
    ///   `SUPPLEMENTAL-CODECS` (other supplemental codecs are kept, an
    ///   existing Dolby Vision one is replaced) and set `VIDEO-RANGE` to the
    ///   base layer's `PQ`/`HLG`, which Apple requires to match the brand.
    ///   A `hev1` variant is left alone, like its init segment.
    ///
    /// Lines without an HEVC entry, or that do not parse, are left alone.
    /// A line without any `CODECS` first takes `fallbackCodecs`
    /// (`RemuxVariantCodecs`, built from Plex's metadata): Plex omits the
    /// attribute on its fMP4 remux masters, and without it neither profile 5
    /// nor 8.x can be declared.
    static func rewrittenStreamInfLine(
        _ line: String,
        configuration: DolbyVisionConfiguration,
        fallbackCodecs: String? = nil
    ) -> String {
        guard var list = HLSAttributeList(line: line) else { return line }
        if list.value(of: "CODECS") == nil, let fallbackCodecs, !fallbackCodecs.isEmpty {
            list.setQuoted("CODECS", to: fallbackCodecs)
        }
        guard let codecsValue = list.quotedValue(of: "CODECS") else {
            return line
        }
        let codecs = codecsValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let hevcFamilies = codecs.map { codec -> String? in
            let lowered = codec.lowercased()
            return lowered.hasPrefix("hvc1") ? "hvc1" : lowered.hasPrefix("hev1") ? "hev1" : nil
        }
        guard hevcFamilies.contains(where: { $0 != nil }) else { return line }

        guard let supplemental = configuration.supplementalCodecString else {
            let rewritten = zip(codecs, hevcFamilies).map { codec, family in
                family.map { configuration.codecString(sampleEntry: $0 == "hev1" ? "dvhe" : "dvh1") } ?? codec
            }
            list.setQuoted("CODECS", to: rewritten.joined(separator: ","))
            return list.line
        }

        guard !hevcFamilies.contains("hev1") else { return line }
        let rewritten = zip(codecs, hevcFamilies).map { codec, family in
            family == nil ? codec : cappingHEVCLevel(codec, configuration: configuration)
        }
        list.setQuoted("CODECS", to: rewritten.joined(separator: ","))

        let otherSupplementals = (list.quotedValue(of: "SUPPLEMENTAL-CODECS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { entry in
                let lowered = entry.lowercased()
                return !entry.isEmpty && !lowered.hasPrefix("dvh1") && !lowered.hasPrefix("dvhe")
            }
        list.setQuoted("SUPPLEMENTAL-CODECS", to: ([supplemental] + otherSupplementals).joined(separator: ","))
        list.set("VIDEO-RANGE", to: configuration.hasHLGBaseLayer ? "HLG" : "PQ")
        return list.line
    }

    /// `hvc1.2.4.L156.b0` → `hvc1.2.4.L153.b0` when the content fits level
    /// 5.1 for the declared tier; anything unparseable, already at/below the
    /// cap, or not provably within 5.1 is returned unchanged.
    static func cappingHEVCLevel(_ codec: String, configuration: DolbyVisionConfiguration) -> String {
        var parts = codec.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4,
              let tier = parts[3].first?.uppercased().first, tier == "L" || tier == "H",
              let level = Int(parts[3].dropFirst()),
              level > cappedHEVCLevel,
              configuration.fitsHEVCLevel51(highTier: tier == "H") else {
            return codec
        }
        parts[3] = "\(parts[3].prefix(1))\(cappedHEVCLevel)"
        return parts.joined(separator: ".")
    }

    private static func dolbyVisionSampleEntry(
        _ box: [UInt8],
        type: String,
        configuration: DolbyVisionConfiguration
    ) -> [UInt8]? {
        let headerLength = 8 + visualSampleEntryFieldsLength
        guard box.count >= headerLength,
              let childTypes = MP4BoxRewriter.childTypes(Array(box[headerLength...])) else {
            return nil
        }
        var entry = box
        entry.replaceSubrange(4..<8, with: Array(type.utf8))
        if !childTypes.contains("dvcC") && !childTypes.contains("dvvC") {
            entry += configurationBox(configuration)
            MP4BoxRewriter.writeUInt32(UInt32(entry.count), into: &entry, at: 0)
        }
        return entry
    }

    /// `DOVIDecoderConfigurationRecord` (Dolby Vision streams within the ISO
    /// base media file format, v2.x): version 1.0, then
    /// profile(7) level(6) rpu(1) el(1) bl(1), bl_signal_compatibility_id(4),
    /// and reserved bits up to 24 bytes. Profiles above 7 use `dvvC`.
    static func configurationBox(_ configuration: DolbyVisionConfiguration) -> [UInt8] {
        var flags = UInt16(configuration.profile & 0x7F) << 9
        flags |= UInt16(configuration.level & 0x3F) << 3
        flags |= 0b101 // rpu_present_flag and bl_present_flag; single layer, no EL
        var payload: [UInt8] = [
            1, 0,
            UInt8(flags >> 8), UInt8(flags & 0xFF),
            UInt8(configuration.blSignalCompatibilityID & 0x0F) << 4,
        ]
        payload += [UInt8](repeating: 0, count: 24 - payload.count)

        var box = [UInt8](repeating: 0, count: 4)
        box += Array((configuration.profile > 7 ? "dvvC" : "dvcC").utf8)
        box += payload
        MP4BoxRewriter.writeUInt32(UInt32(box.count), into: &box, at: 0)
        return box
    }
}

/// An HLS tag's attribute list (`#TAG:NAME=value,NAME="quoted, value"`),
/// parsed by full attribute name so `CODECS` never matches inside
/// `SUPPLEMENTAL-CODECS`, and serialized back in the original order.
struct HLSAttributeList {
    private let tag: String
    private var attributes: [(name: String, value: String)]

    /// nil when the line has no attribute list or does not parse cleanly.
    init?(line: String) {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        tag = String(line[..<colon])
        var attributes: [(name: String, value: String)] = []
        var name = ""
        var value = ""
        var readingName = true
        var inQuotes = false
        for character in line[line.index(after: colon)...] {
            if readingName {
                if character == "=" {
                    guard !name.isEmpty else { return nil }
                    readingName = false
                } else if character == "," {
                    return nil
                } else {
                    name.append(character)
                }
            } else if character == "," && !inQuotes {
                attributes.append((name, value))
                name = ""
                value = ""
                readingName = true
            } else {
                if character == "\"" { inQuotes.toggle() }
                value.append(character)
            }
        }
        guard !inQuotes else { return nil }
        if !readingName {
            attributes.append((name, value))
        } else if !name.isEmpty {
            return nil
        }
        self.attributes = attributes
    }

    var line: String {
        tag + ":" + attributes.map { "\($0.name)=\($0.value)" }.joined(separator: ",")
    }

    /// An attribute's raw value (a quoted string keeps its quotes).
    func value(of name: String) -> String? {
        attributes.first(where: { $0.name == name })?.value
    }

    /// The value of a quoted-string attribute without its quotes.
    func quotedValue(of name: String) -> String? {
        guard let value = value(of: name),
              value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return nil
        }
        return String(value.dropFirst().dropLast())
    }

    mutating func setQuoted(_ name: String, to value: String) {
        set(name, to: "\"\(value)\"")
    }

    /// Replaces the attribute's raw value, or appends the attribute.
    mutating func set(_ name: String, to rawValue: String) {
        if let index = attributes.firstIndex(where: { $0.name == name }) {
            attributes[index].value = rawValue
        } else {
            attributes.append((name, rawValue))
        }
    }
}

/// Relabels a `hev1` HEVC sample entry as `hvc1` in a remux's init segment.
///
/// Plex's copy-remux keeps the source's `hev1` tag, and AVFoundation shows
/// no picture for it (audio plays, no error). Both entries carry the same
/// `hvcC`; `hev1` only allows parameter sets to live in-band as well. When
/// the `hvcC` already holds a VPS, SPS and PPS — what ffmpeg, x265 and
/// every common muxer write — the decoder has all it needs from the sample
/// entry, and in-band repeats stay harmless. Without them the entry is left
/// alone (the session then ends on the ladder's VLCKit direct play).
enum HEVCSampleEntryRetag {
    private static let containerHeaderPadding: [String: Int] = [
        "moov": 0, "trak": 0, "mdia": 0, "minf": 0, "stbl": 0,
        "stsd": 8,    // full box header + entry count
    ]

    /// VisualSampleEntry fields between the box header and its child boxes.
    private static let visualSampleEntryFieldsLength = 78

    /// The init segment with every eligible `hev1` entry renamed `hvc1`, or
    /// nil when there was nothing to retag or the data does not parse.
    static func patchedInitSegment(_ data: Data) -> Data? {
        var didPatch = false
        guard let patched = MP4BoxRewriter.rewrite(
            [UInt8](data),
            containerHeaderPadding: containerHeaderPadding,
            transform: { type, box in
                guard type == "hev1", carriesParameterSets(box) else { return nil }
                var renamed = box
                renamed.replaceSubrange(4..<8, with: Array("hvc1".utf8))
                didPatch = true
                return renamed
            }
        ), didPatch else {
            return nil
        }
        return Data(patched)
    }

    /// `CODECS="hev1.…"` → `hvc1.…` on a variant line, matching the
    /// retagged init segment (AVFoundation picks the decoder from it first).
    static func rewrittenStreamInfLine(_ line: String) -> String {
        guard var list = HLSAttributeList(line: line),
              let codecs = list.quotedValue(of: "CODECS") else { return line }
        let entries = codecs.split(separator: ",").map { entry -> String in
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            return trimmed.lowercased().hasPrefix("hev1") ? "hvc1" + trimmed.dropFirst(4) : trimmed
        }
        let rewritten = entries.joined(separator: ",")
        guard rewritten != codecs else { return line }
        list.setQuoted("CODECS", to: rewritten)
        return list.line
    }

    /// Whether the entry's `hvcC` holds at least one VPS (32), SPS (33)
    /// and PPS (34) NAL unit.
    static func carriesParameterSets(_ box: [UInt8]) -> Bool {
        let childrenStart = 8 + visualSampleEntryFieldsLength
        guard box.count > childrenStart else { return false }
        var offset = childrenStart
        while offset + 8 <= box.count {
            let size = Int(MP4BoxRewriter.readUInt32(box, at: offset))
            guard size >= 8, offset + size <= box.count else { return false }
            if String(decoding: box[(offset + 4)..<(offset + 8)], as: UTF8.self) == "hvcC" {
                return parameterSetTypes(inHVCC: Array(box[(offset + 8)..<(offset + size)]))
                    .isSuperset(of: [32, 33, 34])
            }
            offset += size
        }
        return false
    }

    /// NAL unit types with at least one entry in an `hvcC` payload.
    private static func parameterSetTypes(inHVCC payload: [UInt8]) -> Set<UInt8> {
        // 22 bytes of HEVCDecoderConfigurationRecord header, then numOfArrays.
        guard payload.count > 22 else { return [] }
        var types: Set<UInt8> = []
        var offset = 23
        for _ in 0..<Int(payload[22]) {
            guard offset + 3 <= payload.count else { return [] }
            let type = payload[offset] & 0x3F
            let count = Int(payload[offset + 1]) << 8 | Int(payload[offset + 2])
            offset += 3
            for _ in 0..<count {
                guard offset + 2 <= payload.count else { return [] }
                let length = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2 + length
                guard offset <= payload.count else { return [] }
            }
            if count > 0 { types.insert(type) }
        }
        return types
    }
}

/// Minimal ISO BMFF box walking for patching HLS init segments.
enum MP4BoxRewriter {
    /// Walks `bytes` as a run of boxes. `transform` may replace any box
    /// (return its new bytes); boxes it leaves alone are descended into when
    /// `containerHeaderPadding` names them (the value is the bytes between
    /// the box header and the first child), and resized after. Returns nil
    /// when the data is not a parseable box run.
    static func rewrite(
        _ bytes: [UInt8],
        containerHeaderPadding: [String: Int],
        transform: (String, [UInt8]) -> [UInt8]?
    ) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 64)
        var offset = 0

        while offset < bytes.count {
            guard let (type, size) = boxHeader(bytes, at: offset) else { return nil }
            var box = Array(bytes[offset..<(offset + size)])

            if let replaced = transform(type, box) {
                box = replaced
            } else if let padding = containerHeaderPadding[type] {
                let headerLength = 8 + padding
                guard headerLength <= box.count,
                      let children = rewrite(
                        Array(box[headerLength...]),
                        containerHeaderPadding: containerHeaderPadding,
                        transform: transform
                      ) else {
                    return nil
                }
                box = Array(box[..<headerLength]) + children
                writeUInt32(UInt32(box.count), into: &box, at: 0)
            }

            output += box
            offset += size
        }
        return output
    }

    /// The types of a run of sibling boxes, or nil when it does not parse.
    static func childTypes(_ bytes: [UInt8]) -> [String]? {
        var types: [String] = []
        var offset = 0
        while offset < bytes.count {
            guard let (type, size) = boxHeader(bytes, at: offset) else { return nil }
            types.append(type)
            offset += size
        }
        return types
    }

    /// size 0 ("to end of file") and 1 (64-bit size) never occur in an init
    /// segment's moov tree; treat them as unparseable.
    private static func boxHeader(_ bytes: [UInt8], at offset: Int) -> (type: String, size: Int)? {
        guard offset + 8 <= bytes.count else { return nil }
        let size = Int(readUInt32(bytes, at: offset))
        guard size >= 8, offset + size <= bytes.count else { return nil }
        return (String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self), size)
    }

    static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func writeUInt32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value >> 24)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
}

/// Resource-loader front for a Plex fMP4 HLS remux (Dolby Atmos and Dolby
/// Vision sessions).
///
/// Playlists and the init segment are requested through a private URL
/// scheme and fetched here; media segments are rewritten to absolute server
/// URLs so AVFoundation fetches them directly, and the init segment's Atmos
/// (`EAC3JOCSignaling`) and Dolby Vision (`DolbyVisionSignaling`) signaling is
/// restored on the way through. Anything unexpected is passed through
/// untouched.
///
/// With `repairsKeyframeTimestamps`, the video playlist's media segments go to
/// a `RemuxSegmentRelay` on loopback instead, which fixes the first keyframe
/// timestamp Plex misplaces in every segment of an open-GOP copy
/// (`RemuxKeyframeTimestampRepair`). If the relay cannot start they stay on
/// the server, as before.
final class RemuxHLSLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private static let schemePrefix = "dusk-remux-"

    let queue = DispatchQueue(label: "com.dusk-player.remux-hls-loader")
    private let session: URLSession
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    private let restoresDolbyAtmos: Bool
    private let dolbyVision: DolbyVisionConfiguration?
    private let retagsHEV1: Bool
    /// `CODECS` for a variant Plex lists without one (`RemuxVariantCodecs`).
    private let fallbackCodecs: String?
    private let repairsKeyframeTimestamps: Bool
    private let relayLock = NSLock()
    /// Created with the first fMP4 media playlist; guarded by `relayLock`.
    private var segmentRelay: RemuxSegmentRelay?

    init(
        session: URLSession = PlexTransportSecurity.session,
        restoresDolbyAtmos: Bool,
        dolbyVision: DolbyVisionConfiguration?,
        retagsHEV1: Bool = false,
        fallbackCodecs: String? = nil,
        repairsKeyframeTimestamps: Bool = false
    ) {
        self.session = session
        self.restoresDolbyAtmos = restoresDolbyAtmos
        self.dolbyVision = dolbyVision
        self.retagsHEV1 = retagsHEV1
        self.fallbackCodecs = fallbackCodecs
        self.repairsKeyframeTimestamps = repairsKeyframeTimestamps
    }

    deinit {
        relayLock.withLock { segmentRelay }?.stop()
    }

    /// The segment relay once a video playlist started it (tests, diagnostics).
    var activeSegmentRelay: RemuxSegmentRelay? {
        relayLock.withLock { segmentRelay }
    }

    /// The URL to hand AVFoundation in place of `url` (http/https only).
    static func loaderURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = schemePrefix + scheme
        return components.url
    }

    static func serverURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme.hasPrefix(schemePrefix),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = String(scheme.dropFirst(schemePrefix.count))
        return components.url
    }

    /// Builds an asset whose playlists/init segment flow through `loader`.
    /// The asset holds its resource loader's delegate weakly — keep `loader`
    /// alive for as long as the item plays.
    static func makeAsset(url: URL, loader: RemuxHLSLoader) -> AVURLAsset? {
        guard let loaderURL = loaderURL(for: url) else { return nil }
        let asset = AVURLAsset(url: loaderURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              let serverURL = Self.serverURL(for: requestURL) else {
            return false
        }

        let key = ObjectIdentifier(loadingRequest)
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            await self.load(loadingRequest, serverURL: serverURL)
            self.queue.async { self.tasks[key] = nil }
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    private func load(_ loadingRequest: AVAssetResourceLoadingRequest, serverURL: URL) async {
        var request = loadingRequest.request
        request.url = serverURL
        do {
            try PlexTransportSecurity.validate(request)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let relay = await startedSegmentRelay(forPlaylist: data, serverURL: serverURL)
            let body = transformedBody(data, response: response, serverURL: serverURL, segmentRelay: relay)
            queue.async {
                guard !loadingRequest.isCancelled else { return }
                Self.respond(to: loadingRequest, with: body.data, contentType: body.contentType)
            }
        } catch {
            queue.async {
                guard !loadingRequest.isCancelled else { return }
                loadingRequest.finishLoading(with: error)
            }
        }
    }

    /// The relay for a media playlist whose segments are fMP4 (`EXT-X-MAP`):
    /// the video. Nil for everything else (the master, WebVTT renditions,
    /// segments) and when the relay cannot come up.
    private func startedSegmentRelay(forPlaylist data: Data, serverURL: URL) async -> RemuxSegmentRelay? {
        guard repairsKeyframeTimestamps, Self.isPlaylist(data),
              data.range(of: Data("#EXT-X-MAP".utf8)) != nil,
              data.range(of: Data("#EXTINF".utf8)) != nil else {
            return nil
        }
        let relay = relayLock.withLock { () -> RemuxSegmentRelay in
            if let segmentRelay { return segmentRelay }
            let relay = RemuxSegmentRelay(origin: serverURL)
            segmentRelay = relay
            return relay
        }
        guard await relay.start() else {
            atmosSignalingLogger.error("Remux segment relay unavailable; segments load from the server unrepaired")
            return nil
        }
        return relay
    }

    private func transformedBody(
        _ data: Data,
        response: URLResponse,
        serverURL: URL,
        segmentRelay: RemuxSegmentRelay? = nil
    ) -> (data: Data, contentType: String) {
        if Self.isPlaylist(data) {
            let text = String(decoding: data, as: UTF8.self)
            let relayURL = segmentRelay.map { relay in { (url: URL) in relay.relayURL(for: url) } }
            return (Data(rewrittenPlaylist(text, baseURL: serverURL, segmentURL: relayURL).utf8), "public.m3u-playlist")
        }

        var segment = data
        if restoresDolbyAtmos, let patched = EAC3JOCSignaling.patchedInitSegment(segment) {
            atmosSignalingLogger.notice("Restored Dolby Atmos (E-AC-3 JOC) signaling in the HLS init segment")
            segment = patched
        }
        if let dolbyVision,
           let patched = DolbyVisionSignaling.patchedInitSegment(segment, configuration: dolbyVision) {
            atmosSignalingLogger.notice(
                "Restored Dolby Vision signaling (\(dolbyVision.supplementalCodecString ?? dolbyVision.codecString, privacy: .public)) in the HLS init segment"
            )
            segment = patched
        }
        if retagsHEV1, let patched = HEVCSampleEntryRetag.patchedInitSegment(segment) {
            atmosSignalingLogger.notice("Retagged the hev1 HEVC sample entry hvc1 in the HLS init segment")
            segment = patched
        }
        return (segment, "public.mpeg-4")
    }

    /// Sends playlists and the init segment back through the loader; media
    /// segments go straight to the server as absolute URLs, or to
    /// `segmentURL`'s answer (the segment relay) when it has one.
    func rewrittenPlaylist(
        _ playlist: String,
        baseURL: URL,
        segmentURL: ((URL) -> URL?)? = nil
    ) -> String {
        var routeNextURIThroughLoader = false
        var lines: [String] = []

        for rawLine in playlist.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                routeNextURIThroughLoader = true
                if let dolbyVision {
                    lines.append(DolbyVisionSignaling.rewrittenStreamInfLine(
                        line, configuration: dolbyVision, fallbackCodecs: fallbackCodecs
                    ))
                } else if retagsHEV1 {
                    lines.append(HEVCSampleEntryRetag.rewrittenStreamInfLine(line))
                } else {
                    lines.append(line)
                }
            } else if line.hasPrefix("#EXT-X-MAP") || line.hasPrefix("#EXT-X-MEDIA") {
                lines.append(rewritingURIAttribute(in: line, baseURL: baseURL))
            } else if line.isEmpty || line.hasPrefix("#") {
                lines.append(line)
            } else if let absolute = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                if routeNextURIThroughLoader, let loaderURL = Self.loaderURL(for: absolute) {
                    lines.append(loaderURL.absoluteString)
                } else if !routeNextURIThroughLoader, let relayed = segmentURL?(absolute) {
                    lines.append(relayed.absoluteString)
                } else {
                    lines.append(absolute.absoluteString)
                }
                routeNextURIThroughLoader = false
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func rewritingURIAttribute(in line: String, baseURL: URL) -> String {
        guard let start = line.range(of: "URI=\""),
              let end = line[start.upperBound...].firstIndex(of: "\"") else {
            return line
        }
        let uri = String(line[start.upperBound..<end])
        guard let absolute = URL(string: uri, relativeTo: baseURL)?.absoluteURL,
              let loaderURL = Self.loaderURL(for: absolute) else {
            return line
        }
        return line.replacingCharacters(in: start.upperBound..<end, with: loaderURL.absoluteString)
    }

    private static func isPlaylist(_ data: Data) -> Bool {
        data.prefix(7).elementsEqual("#EXTM3U".utf8)
    }

    private static func respond(
        to loadingRequest: AVAssetResourceLoadingRequest,
        with data: Data,
        contentType: String
    ) {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let dataRequest = loadingRequest.dataRequest {
            let start = Int(dataRequest.requestedOffset)
            let length = dataRequest.requestsAllDataToEndOfResource
                ? data.count - start
                : dataRequest.requestedLength
            let end = min(data.count, start + max(0, length))
            if start < end {
                dataRequest.respond(with: data.subdata(in: start..<end))
            }
        }
        loadingRequest.finishLoading()
    }
}

/// The way around tvOS refusing an HLS master for the display (see
/// `AVPlayerEngine.fallBackToMediaPlaylist(afterRefusal:)`): load the first
/// variant's media playlist directly. A media playlist has no `VIDEO-RANGE`,
/// `CODECS` or `SUPPLEMENTAL-CODECS` for AVFoundation to measure the display
/// against; the init segment (with any `dvvC`/`dec3` patch) is unchanged.
enum HLSMediaPlaylistFallback {
    /// `AVErrorNoCompatibleAlternatesForExternalDisplay`. Its underlying
    /// CoreMedia error is -17223, which Apple does not document.
    static let displayRefusalCode = -11868

    static func isDisplayRefusal(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == AVFoundationErrorDomain && error.code == displayRefusalCode
    }

    /// The first variant's media playlist, or nil when the master has
    /// separate renditions (`EXT-X-MEDIA` with a `URI`: a WebVTT subtitle,
    /// an audio group), which the media playlist alone would silently drop.
    static func mediaPlaylistURL(inMaster master: String, baseURL: URL) -> URL? {
        let lines = master.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { return nil }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("URI=") }) {
            return nil
        }
        guard let streamInf = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }),
              let uri = lines[(streamInf + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else {
            return nil
        }
        return URL(string: uri, relativeTo: baseURL)?.absoluteURL
    }

    /// Fetches the master again (Plex, or the Dolby Vision 7 proxy) and
    /// resolves its media playlist; nil on any failure.
    static func mediaPlaylistURL(forMaster masterURL: URL) async -> URL? {
        var request = URLRequest(url: masterURL, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 1 << 20 else {
            return nil
        }
        return mediaPlaylistURL(inMaster: String(decoding: data, as: UTF8.self), baseURL: http.url ?? masterURL)
    }
}
