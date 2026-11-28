import Foundation

/// Jellyfin `MediaSource` / `MediaStream` / `MediaSegment` DTOs → the domain's
/// `MediaVersion` → `MediaPart` → `MediaStream` and `Marker`
/// (docs/jellyfin/02-jellyfin-api-mapping.md §9, §11; 04 §4.2).
///
/// - A `MediaSource` is one version with exactly one part; both carry the
///   source id.
/// - A stream's id is its Jellyfin `Index` as a string, the value server calls
///   (`AudioStreamIndex`, `SubtitleStreamIndex`) take. It is **not** a track
///   position: an external subtitle takes index 0 and shifts every embedded
///   stream (02 §9). Engines use the per-kind position instead, which is the
///   stream's place in `MediaPart.streams` among the embedded streams of its
///   kind (`JellyfinStreamPositions`). Streams are ordered so that position is
///   the container's order, with external subtitles after the embedded ones.
/// - `isServerSelected` is `Index == Default{Audio,Subtitle}StreamIndex`. The
///   server resolves those per user, so they are a tie-break after Dusk's own
///   rules, never "the" default. `IsDefault` is the file's flag and stays as
///   it is (every SRT on `Knives Out` has it).
/// - Units: bitrates bit/s → kbit/s, ticks → ms, `Level` → Int.
/// - No URL here carries a token: the part key and an external subtitle key
///   are server-relative paths; `PlaybackProviding` turns them into requests.
enum JellyfinMediaMapper {
    // MARK: Versions

    /// Every version of `itemID`, in server order.
    static func map(_ sources: [JellyfinMediaSourceDTO], itemID: String) -> [MediaVersion] {
        sources.map { map($0, itemID: itemID) }
    }

    static func map(_ source: JellyfinMediaSourceDTO, itemID: String) -> MediaVersion {
        let itemID = JellyfinID.normalized(itemID)
        let sourceID = JellyfinID.normalized(source.id)
        let container = JellyfinCodecAliases.container(source.container, path: source.path)
        let streams = mapStreams(source, itemID: itemID)
        let video = streams.first { $0.kind == .video }
        let audio = streams.first { $0.kind == .audio && $0.isServerSelected == true }
            ?? streams.first { $0.kind == .audio }
        let duration = source.runTimeTicks.map(\.milliseconds)

        let part = MediaPart(
            id: sourceID,
            key: directPlayPath(itemID: itemID, sourceID: sourceID),
            file: source.path,
            size: source.size.map { Int(clamping: $0) },
            container: container,
            duration: duration,
            videoProfile: video?.profile,
            audioProfile: audio?.profile,
            accessible: nil,
            exists: nil,
            streams: streams
        )
        return MediaVersion(
            id: sourceID,
            container: container,
            videoCodec: video?.codec,
            audioCodec: audio?.codec,
            videoResolution: videoResolution(width: video?.width, height: video?.height),
            videoProfile: video?.profile,
            audioProfile: audio?.profile,
            audioChannels: audio?.channels,
            width: video?.width,
            height: video?.height,
            bitrate: kilobits(source.bitrate),
            duration: duration,
            optimizedForStreaming: nil,
            parts: [part]
        )
    }

    /// `/Videos/{itemId}/stream?static=true&mediaSourceId={id}`: the direct-play
    /// path (`DirectStreamUrl` is empty on 12.4, 03 §5.1 item 2). Relative and
    /// token-free; the playback facet adds the base URL and `ApiKey`.
    static func directPlayPath(itemID: String, sourceID: String) -> String {
        "/Videos/\(JellyfinID.normalized(itemID))/stream?static=true&mediaSourceId=\(JellyfinID.normalized(sourceID))"
    }

    /// `/Videos/{itemId}/{sourceId}/Subtitles/{index}/0/Stream.{format}`, the
    /// sidecar path for an external subtitle. Token-free. The extension is the
    /// format the server answers in: text tracks in their own format, PGS as
    /// `sup`. VobSub has none (every extension is `400` on 12.4), so its path
    /// keeps the codec and `JellyfinPlayback` hands out no URL for it.
    static func externalSubtitlePath(itemID: String, sourceID: String, index: Int, codec: String?) -> String {
        let format = sidecarFormat(codec: codec)
        return "/Videos/\(JellyfinID.normalized(itemID))/\(JellyfinID.normalized(sourceID))/Subtitles/\(index)/0/Stream.\(format)"
    }

    /// The extensions `externalSubtitlePath` can name that the server serves.
    static let servableSidecarFormats: Set<String> = ["srt", "ass", "ssa", "vtt", "sup"]

    static func sidecarFormat(codec: String?) -> String {
        switch codec?.nilIfEmpty {
        case nil: "srt"
        case "pgs"?: "sup"
        case let codec?: codec
        }
    }

    /// Plex's resolution names (`4k`, `1080`, `720`, `480`, `sd`), which
    /// Preferred Version and the quality labels read. Cropped scope films
    /// (1920 × 800) count by width.
    static func videoResolution(width: Int?, height: Int?) -> String? {
        guard width != nil || height != nil else { return nil }
        let width = width ?? 0
        let height = height ?? 0
        if width >= 3200 || height >= 1800 { return "4k" }
        if width >= 1700 || height >= 1000 { return "1080" }
        if width >= 1200 || height >= 700 { return "720" }
        if width >= 700 || height >= 460 { return "480" }
        return "sd"
    }

    // MARK: Streams

    /// The source's video, audio and subtitle streams in engine order:
    /// embedded streams by `Index` (the container's order), then external
    /// subtitles. `EmbeddedImage` (cover art), `Data` and `Lyric` streams are
    /// dropped, as Plex never lists them.
    static func mapStreams(_ source: JellyfinMediaSourceDTO, itemID: String) -> [MediaStream] {
        let sourceID = JellyfinID.normalized(source.id)
        let playable = source.streams.filter { kind(of: $0.type) != nil }
        let embedded = playable.filter { $0.isExternal != true }.sorted { $0.index < $1.index }
        let external = playable.filter { $0.isExternal == true }.sorted { $0.index < $1.index }
        return (embedded + external).compactMap {
            map($0, itemID: itemID, sourceID: sourceID,
                defaultAudioIndex: source.defaultAudioStreamIndex,
                defaultSubtitleIndex: source.defaultSubtitleStreamIndex)
        }
    }

    static func kind(of type: JellyfinStreamType) -> StreamKind? {
        if type.matches(.video) { return .video }
        if type.matches(.audio) { return .audio }
        if type.matches(.subtitle) { return .subtitle }
        return nil
    }

    static func map(
        _ dto: JellyfinMediaStreamDTO,
        itemID: String,
        sourceID: String,
        defaultAudioIndex: Int?,
        defaultSubtitleIndex: Int?
    ) -> MediaStream? {
        guard let kind = kind(of: dto.type) else { return nil }
        let codec = JellyfinCodecAliases.codec(dto.codec)
        let isVideo = kind == .video
        let isAudio = kind == .audio
        let language = JellyfinLanguage(code: dto.language)

        let selectedIndex: Int? = switch kind {
        case .audio: defaultAudioIndex
        case .subtitle: defaultSubtitleIndex
        case .video: nil
        }
        // Plex sends `selected` only on the chosen stream; nil elsewhere.
        let isServerSelected: Bool? = selectedIndex.map { $0 >= 0 && $0 == dto.index } == true ? true : nil

        let dolbyVision = isVideo ? dolbyVisionFields(dto) : (nil, nil, nil, nil)
        let profile = dto.profile?.lowercased().nilIfEmpty
        let isAtmos = isAudio && (dto.audioSpatialFormat?.matches(.dolbyAtmos) == true
            || profile?.contains("atmos") == true)
        let labels = JellyfinStreamLabels(
            kind: kind, codec: codec, profile: profile, language: language, title: dto.title?.nilIfEmpty,
            width: dto.width, height: dto.height, rangeType: dto.videoRangeType,
            channels: dto.channels, channelLayout: dto.channelLayout, isAtmos: isAtmos,
            isDTSX: isAudio && dto.audioSpatialFormat?.matches(.dtsX) == true,
            isForced: dto.isForced == true, isHearingImpaired: dto.isHearingImpaired == true,
            isExternal: dto.isExternal == true
        )

        return MediaStream(
            id: String(dto.index),
            kind: kind,
            codec: codec,
            displayTitle: labels.displayTitle,
            extendedDisplayTitle: labels.extendedDisplayTitle,
            language: language?.name,
            languageCode: language?.code,
            languageTag: language?.tag,
            isSelected: isServerSelected,
            isDefault: dto.isDefault,
            width: isVideo ? dto.width : nil,
            height: isVideo ? dto.height : nil,
            bitrate: kilobits(dto.bitRate),
            frameRate: isVideo ? (dto.realFrameRate ?? dto.averageFrameRate) : nil,
            bitDepth: isVideo ? dto.bitDepth : nil,
            colorSpace: isVideo ? dto.colorSpace?.lowercased().nilIfEmpty : nil,
            colorRange: nil,
            colorPrimaries: isVideo ? dto.colorPrimaries?.lowercased().nilIfEmpty : nil,
            colorTransfer: isVideo ? dto.colorTransfer?.lowercased().nilIfEmpty : nil,
            chromaSubsampling: isVideo ? chromaSubsampling(pixelFormat: dto.pixelFormat) : nil,
            profile: profile,
            level: isVideo ? dto.level.flatMap { $0 > 0 ? Int($0.rounded()) : nil } : nil,
            doviPresent: dolbyVision.0,
            doviProfile: dolbyVision.1,
            doviLevel: dolbyVision.2,
            doviBLCompatID: dolbyVision.3,
            channels: isAudio ? dto.channels : nil,
            channelLayout: isAudio ? dto.channelLayout?.nilIfEmpty : nil,
            samplingRate: isAudio ? dto.sampleRate : nil,
            isForced: dto.isForced,
            isHearingImpaired: dto.isHearingImpaired,
            key: dto.isExternal == true
                ? externalSubtitlePath(itemID: itemID, sourceID: sourceID, index: dto.index, codec: codec)
                : nil,
            codecID: isVideo ? dto.codecTag?.lowercased().nilIfEmpty : nil
        )
    }

    /// All nil unless the stream carries Dolby Vision, so an SDR or HDR10
    /// stream gets `dolbyVision == nil` exactly like a Plex one.
    private static func dolbyVisionFields(_ dto: JellyfinMediaStreamDTO) -> (Bool?, Int?, Int?, Int?) {
        let rangeSaysDoVi = dto.videoRangeType?.rawValue.uppercased().hasPrefix("DOVI") == true
            && dto.videoRangeType?.matches(.doviInvalid) != true
        let profile = dto.dvProfile.flatMap { $0 > 0 ? $0 : nil }
        guard rangeSaysDoVi || profile != nil else { return (nil, nil, nil, nil) }
        return (true, profile, dto.dvLevel.flatMap { $0 > 0 ? $0 : nil }, dto.dvBlSignalCompatibilityID)
    }

    /// `yuv420p10le` → `4:2:0`, as Plex reports it.
    static func chromaSubsampling(pixelFormat: String?) -> String? {
        guard let format = pixelFormat?.lowercased() else { return nil }
        for (marker, value) in [("420", "4:2:0"), ("422", "4:2:2"), ("444", "4:4:4"), ("411", "4:1:1")]
        where format.contains(marker) {
            return value
        }
        return nil
    }

    static func kilobits(_ bitsPerSecond: Int?) -> Int? {
        guard let bitsPerSecond, bitsPerSecond > 0 else { return nil }
        return Int((Double(bitsPerSecond) / 1000).rounded())
    }

    // MARK: Markers

    /// `MediaSegments` → skip markers, sorted by start. `Outro` is Plex's
    /// `credits`; unknown types are dropped.
    static func markers(_ segments: [JellyfinMediaSegmentDTO]) -> [Marker] {
        segments.compactMap { segment -> Marker? in
            guard let type = markerType(segment.type), segment.endTicks > segment.startTicks else { return nil }
            return Marker(
                id: JellyfinID.normalized(segment.id),
                type: type,
                startTimeOffset: segment.startTicks.milliseconds,
                endTimeOffset: segment.endTicks.milliseconds
            )
        }
        .sorted { $0.startTimeOffset < $1.startTimeOffset }
    }

    static func markerType(_ type: JellyfinMediaSegmentType) -> String? {
        if type.matches(.intro) { return "intro" }
        if type.matches(.outro) { return "credits" }
        if type.matches(.recap) { return "recap" }
        if type.matches(.preview) { return "preview" }
        if type.matches(.commercial) { return "commercial" }
        return nil
    }
}

// MARK: - Per-kind positions

/// Translates between a Jellyfin stream `Index` (what the server's
/// `AudioStreamIndex` / `SubtitleStreamIndex` and `Default*StreamIndex` mean)
/// and the stream's position among the part's **embedded** streams of its
/// kind (what VLCKit's and AVPlayer's own track lists are ordered by).
/// External subtitles have no embedded position: engines attach them by URL.
enum JellyfinStreamPositions {
    static func position(ofIndex index: Int, kind: StreamKind, in part: MediaPart) -> Int? {
        embedded(kind, in: part).firstIndex { $0.id == String(index) }
    }

    static func index(atPosition position: Int, kind: StreamKind, in part: MediaPart) -> Int? {
        let streams = embedded(kind, in: part)
        guard streams.indices.contains(position) else { return nil }
        return Int(streams[position].id)
    }

    private static func embedded(_ kind: StreamKind, in part: MediaPart) -> [MediaStream] {
        part.streams.filter { $0.kind == kind && $0.key == nil }
    }
}

// MARK: - Labels

/// A stream language from Jellyfin's ISO 639-2 `Language`, named the way Plex
/// names it: in the language itself (`Português`, `Čeština`), capitalised.
struct JellyfinLanguage: Sendable, Hashable {
    let code: String
    let tag: String?
    let name: String

    init?(code raw: String?) {
        guard let code = raw?.trimmingCharacters(in: .whitespaces).lowercased().nilIfEmpty,
              !["und", "unk", "zxx", "mis", "mul"].contains(code) else { return nil }
        let languageCode = Locale.Language(identifier: code).languageCode
        let tag = languageCode?.identifier(.alpha2)
        let identifier = tag ?? code
        let locale = Locale(identifier: identifier)
        let localized = locale.localizedString(forLanguageCode: identifier)
            ?? Locale(identifier: "en").localizedString(forLanguageCode: identifier)
        guard let localized, localized.caseInsensitiveCompare(identifier) != .orderedSame else {
            self.code = code
            self.tag = tag
            self.name = code.uppercased()
            return
        }
        self.code = code
        self.tag = tag
        self.name = localized.prefix(1).uppercased(with: locale) + localized.dropFirst()
    }
}

/// Track labels in Plex's shape, so a Jellyfin track reads like a Plex one in
/// the pickers (`English (EAC3 5.1 + Atmos)`, `Commentary (English AC3
/// Stereo)`, `Português Forced`, `English (SRT)`). Jellyfin's own
/// `DisplayTitle` (`Surround - English - Dolby Digital Plus … - Default`) is
/// not used (02 §9).
struct JellyfinStreamLabels {
    let kind: StreamKind
    let codec: String?
    let profile: String?
    let language: JellyfinLanguage?
    let title: String?
    let width: Int?
    let height: Int?
    let rangeType: JellyfinVideoRangeType?
    let channels: Int?
    let channelLayout: String?
    let isAtmos: Bool
    let isDTSX: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isExternal: Bool

    var displayTitle: String? {
        switch kind {
        case .video:
            return [videoResolutionLabel, rangeLabel].compactMap { $0 }.joined(separator: " ").nilIfEmpty
                ?? codecLabel
        case .audio:
            let details = [codecLabel, layoutLabel].compactMap { $0 }.joined(separator: " ")
            return "\(languageName) (\(details))"
        case .subtitle:
            var label = languageName
            if isForced { label += " Forced" }
            if isHearingImpaired { label += " SDH" }
            return label
        }
    }

    var extendedDisplayTitle: String? {
        switch kind {
        case .video:
            let details = [codecLabel, profile.map(Self.capitalizedWords)].compactMap { $0 }.joined(separator: " ")
            guard let displayTitle, !details.isEmpty, displayTitle != details else { return displayTitle }
            return "\(displayTitle) (\(details))"
        case .audio:
            guard let title else { return displayTitle }
            // Plex leaves the layout out when the title already says it ("Stereo").
            let layout = layoutLabel.flatMap { title.localizedCaseInsensitiveContains($0) ? nil : $0 }
            let details = [languageName, codecLabel, layout].compactMap { $0 }.joined(separator: " ")
            return "\(title) (\(details))"
        case .subtitle:
            let format = [codecLabel, isExternal ? "External" : nil].compactMap { $0 }.joined(separator: " ")
            guard let title else { return "\(languageName) (\(format))" }
            if title.localizedCaseInsensitiveContains(languageName) { return "\(title) (\(format))" }
            return "\(title) (\(languageName) \(format))"
        }
    }

    private var languageName: String { language?.name ?? "Unknown" }

    private var codecLabel: String? {
        guard let codec else { return nil }
        if codec == "dts" {
            if isDTSX { return "DTS:X" }
            let profile = profile ?? ""
            if profile.contains("ma") { return "DTS-HD MA" }
            if profile.contains("hra") || profile.contains("hd") { return "DTS-HD" }
            return "DTS"
        }
        return codec.uppercased()
    }

    private var layoutLabel: String? {
        var label: String?
        switch channels {
        case 1?: label = "Mono"
        case 2?: label = "Stereo"
        case 6?: label = "5.1"
        case 8?: label = "7.1"
        default: label = channelLayout?.nilIfEmpty
        }
        if isAtmos { label = [label, "+ Atmos"].compactMap { $0 }.joined(separator: " ") }
        return label
    }

    private var videoResolutionLabel: String? {
        switch JellyfinMediaMapper.videoResolution(width: width, height: height) {
        case "4k"?: "4K"
        case "sd"?: "SD"
        case let value?: "\(value)p"
        case nil: nil
        }
    }

    private var rangeLabel: String? {
        guard let rangeType else { return nil }
        let table: [(JellyfinVideoRangeType, String)] = [
            (.dovi, "DoVi"), (.doviWithHDR10, "DoVi/HDR10"), (.doviWithHLG, "DoVi/HLG"),
            (.doviWithSDR, "DoVi/SDR"), (.doviWithEL, "DoVi/HDR10"), (.doviWithHDR10Plus, "DoVi/HDR10"),
            (.doviWithELHDR10Plus, "DoVi/HDR10"), (.hdr10, "HDR10"), (.hdr10Plus, "HDR10"), (.hlg, "HLG"),
        ]
        return table.first { rangeType.matches($0.0) }?.1
    }

    private static func capitalizedWords(_ value: String) -> String {
        value.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
