import Foundation
import OSLog

private let plexMediaDTOLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexMedia"
)

// Plex's `Media` → `Part` → `Stream` wire shapes. This is also the shape Dusk
// has always persisted (`downloads.json`, the converted-media blob, the offline
// metadata cache), so these keys are wire format twice over: never rename one.
// `PlexMediaVersionMapper` turns them into `MediaVersion` / `MediaPart` /
// `MediaStream` and owns the domain types' persisted coding.

// MARK: - Media (file-level metadata)

/// One `Media` entry of a Plex item: a single version of the title.
struct PlexMediaVersionDTO: Decodable, Sendable {
    let id: String

    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let videoResolution: String?
    let videoProfile: String?
    let audioProfile: String?
    let audioChannels: Int?
    let width: Int?
    let height: Int?
    let bitrate: Int?
    let duration: Int?
    let optimizedForStreaming: Int?

    let parts: [PlexMediaPartDTO]

    enum CodingKeys: String, CodingKey {
        case id, container, videoCodec, audioCodec
        case videoResolution, videoProfile, audioProfile, audioChannels
        case width, height, bitrate, duration, optimizedForStreaming
        case parts = "Part"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeID(forKey: .id)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        videoCodec = try container.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try container.decodeIfPresent(String.self, forKey: .audioCodec)
        videoResolution = try container.decodeIfPresent(String.self, forKey: .videoResolution)
        videoProfile = try container.decodeIfPresent(String.self, forKey: .videoProfile)
        audioProfile = try container.decodeIfPresent(String.self, forKey: .audioProfile)
        audioChannels = try container.decodeIfPresent(Int.self, forKey: .audioChannels)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        optimizedForStreaming = try container.decodeIfPresent(Int.self, forKey: .optimizedForStreaming)
        parts = try container.decodeIfPresent([PlexMediaPartDTO].self, forKey: .parts) ?? []
    }
}

// MARK: - Part (individual file within a media version)

/// One `Part` entry: a single file of a version.
struct PlexMediaPartDTO: Decodable, Sendable {
    let id: String
    let key: String
    let file: String?
    let size: Int?
    let container: String?
    let duration: Int?
    let videoProfile: String?
    let audioProfile: String?
    /// Plex's file-presence flags; see `MediaPart.accessible`.
    let accessible: Bool?
    let exists: Bool?

    let streams: [PlexMediaStreamDTO]

    enum CodingKeys: String, CodingKey {
        case id, key, file, size, container, duration
        case videoProfile, audioProfile, accessible, exists
        case streams = "Stream"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeID(forKey: .id)
        key = try container.decode(String.self, forKey: .key)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        videoProfile = try container.decodeIfPresent(String.self, forKey: .videoProfile)
        audioProfile = try container.decodeIfPresent(String.self, forKey: .audioProfile)
        accessible = Self.decodeFlexibleBool(container, forKey: .accessible)
        exists = Self.decodeFlexibleBool(container, forKey: .exists)
        streams = try Self.decodeStreams(container)
    }

    /// Decodes each `Stream` entry on its own and drops the ones that fail, so
    /// one odd track can't take the whole item down. Plex has been seen omitting
    /// `id` on a stream in the metadata JSON (likely embedded EIA-608 captions),
    /// and newer servers may add stream types we don't model. A dropped stream
    /// just isn't offered from Plex metadata; a made-up id could otherwise be
    /// sent back to Plex as a stream selection.
    private static func decodeStreams(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [PlexMediaStreamDTO] {
        guard let entries = try container.decodeIfPresent([LenientPlexStreamDTO].self, forKey: .streams) else {
            return []
        }
        return entries.enumerated().compactMap { index, entry in
            if let stream = entry.stream { return stream }
            plexMediaDTOLogger.error(
                "Dropping undecodable stream \(index, privacy: .public) (streamType \(entry.kind.map(String.init) ?? "?", privacy: .public), codec \(entry.codec ?? "?", privacy: .public)): \(entry.failure ?? "unknown error", privacy: .public)"
            )
            return nil
        }
    }

    /// Plex serializes these flags inconsistently across versions (bool, `1`/`0`,
    /// or `"1"`/`"0"`), so decode defensively and treat anything unexpected as
    /// "unknown" rather than failing the whole part.
    private static func decodeFlexibleBool(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return intValue != 0
        }
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
            switch stringValue.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

/// One `Stream` entry that never fails to decode: holds the stream when it is
/// valid, otherwise whatever is readable for logging.
private struct LenientPlexStreamDTO: Decodable {
    let stream: PlexMediaStreamDTO?
    let kind: Int?
    let codec: String?
    let failure: String?

    private enum ProbeKeys: String, CodingKey {
        case kind = "streamType", codec
    }

    init(from decoder: Decoder) throws {
        do {
            stream = try PlexMediaStreamDTO(from: decoder)
            kind = nil
            codec = nil
            failure = nil
        } catch {
            let probe = try? decoder.container(keyedBy: ProbeKeys.self)
            stream = nil
            kind = try? probe?.decodeIfPresent(Int.self, forKey: .kind)
            codec = try? probe?.decodeIfPresent(String.self, forKey: .codec)
            failure = String(describing: error)
        }
    }
}

// MARK: - Stream (individual track)

/// One `Stream` entry: an audio, video or subtitle track of a part. An
/// unknown `streamType` or a missing `id` fails the decode (the part drops it).
struct PlexMediaStreamDTO: Decodable, Sendable {
    let id: String
    let kind: StreamKind
    let codec: String?
    let displayTitle: String?
    let extendedDisplayTitle: String?
    let language: String?
    let languageCode: String?
    let languageTag: String?
    /// Plex's `selected`.
    let selected: Bool?
    /// Plex's `default`.
    let isDefault: Bool?

    // Video stream fields
    let width: Int?
    let height: Int?
    let bitrate: Int?
    let frameRate: Double?
    let bitDepth: Int?
    let colorSpace: String?
    let colorRange: String?
    let colorPrimaries: String?
    /// Plex's `colorTrc`.
    let colorTrc: String?
    let chromaSubsampling: String?
    let profile: String?
    let level: Int?
    let codecID: String?

    // Dolby Vision (video streams), each sent independently.
    let doviPresent: Bool?
    let doviProfile: Int?
    let doviLevel: Int?
    let doviBLCompatID: Int?

    // Audio stream fields
    let channels: Int?
    /// Plex's `audioChannelLayout` (older offline snapshots: `channelLayout`).
    let channelLayout: String?
    let samplingRate: Int?

    // Subtitle stream fields
    let forced: Bool?
    let hearingImpaired: Bool?
    /// Non-nil for external (sidecar) subtitle files.
    let key: String?

    enum CodingKeys: String, CodingKey {
        case id, kind = "streamType", codec
        case displayTitle, extendedDisplayTitle
        case language, languageCode, languageTag
        case selected = "selected"
        case isDefault = "default"
        case width, height, bitrate, frameRate, bitDepth
        case colorSpace, colorRange, colorPrimaries, colorTrc = "colorTrc"
        case chromaSubsampling, profile, level, codecID
        case doviPresent = "DOVIPresent"
        case doviProfile = "DOVIProfile"
        case doviLevel = "DOVILevel"
        case doviBLCompatID = "DOVIBLCompatID"
        case channels, samplingRate
        case channelLayout = "audioChannelLayout"
        case forced = "forced"
        case hearingImpaired = "hearingImpaired"
        case key
    }

    /// Older offline snapshots used Dusk's property name as the JSON key.
    private enum LegacyCodingKeys: String, CodingKey {
        case channelLayout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeID(forKey: .id)
        kind = try container.decode(StreamKind.self, forKey: .kind)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        extendedDisplayTitle = try container.decodeIfPresent(String.self, forKey: .extendedDisplayTitle)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        languageTag = try container.decodeIfPresent(String.self, forKey: .languageTag)

        // Plex returns Bool-ish fields as Int (0/1) or Bool depending on endpoint
        selected = try Self.decodeBoolish(container: container, key: .selected)
        isDefault = try Self.decodeBoolish(container: container, key: .isDefault)
        forced = try Self.decodeBoolish(container: container, key: .forced)
        hearingImpaired = try Self.decodeBoolish(container: container, key: .hearingImpaired)

        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        frameRate = try container.decodeIfPresent(Double.self, forKey: .frameRate)
        bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
        colorSpace = try container.decodeIfPresent(String.self, forKey: .colorSpace)
        colorRange = try container.decodeIfPresent(String.self, forKey: .colorRange)
        colorPrimaries = try container.decodeIfPresent(String.self, forKey: .colorPrimaries)
        colorTrc = try container.decodeIfPresent(String.self, forKey: .colorTrc)
        chromaSubsampling = try container.decodeIfPresent(String.self, forKey: .chromaSubsampling)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        codecID = try? container.decodeIfPresent(String.self, forKey: .codecID)
        doviPresent = try Self.decodeBoolish(container: container, key: .doviPresent)
        doviProfile = try container.decodeIfPresent(Int.self, forKey: .doviProfile)
        doviLevel = try container.decodeIfPresent(Int.self, forKey: .doviLevel)
        doviBLCompatID = try container.decodeIfPresent(Int.self, forKey: .doviBLCompatID)
        channels = try container.decodeIfPresent(Int.self, forKey: .channels)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        channelLayout = try container.decodeIfPresent(String.self, forKey: .channelLayout)
            ?? legacy.decodeIfPresent(String.self, forKey: .channelLayout)
        samplingRate = try container.decodeIfPresent(Int.self, forKey: .samplingRate)
        key = try container.decodeIfPresent(String.self, forKey: .key)
    }

    /// Plex sometimes sends Bool fields as Int (0/1) and sometimes as actual Bool.
    private static func decodeBoolish(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Bool? {
        if let boolVal = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return boolVal
        }
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: key) {
            return intVal != 0
        }
        return nil
    }
}
