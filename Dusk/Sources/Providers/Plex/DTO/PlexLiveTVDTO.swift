import Foundation

// Plex Live TV wire shapes: lineup channels, guide programs and their
// airings, the media providers list, the DVR with its devices and the tune
// answer. `PlexLiveTVMapper` turns them into the `Live*` domain types.
//
// The decoders are lenient field by field on purpose (each comment says why
// where it matters); which fields throw on a type mismatch and which fall
// back to nil is behaviour, so keep it when editing.

/// A lineup channel (`/{provider}/lineups/dvr/channels`).
struct PlexLiveChannelDTO: Decodable, Sendable {
    let id: String?
    let gridKey: String?
    let vcn: String?
    let channelVcn: String?
    let identifier: String?
    let key: String?
    let isHD: Bool?
    let thumb: String?
    let title: String?
    let callSign: String?
    let language: String?

    private enum CodingKeys: String, CodingKey {
        case id, gridKey, vcn, isHD = "isHd", thumb, title, callSign, language
        case identifier, key, channelVcn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.liveTVString(forKey: .id)
        gridKey = container.liveTVString(forKey: .gridKey)
        vcn = container.liveTVString(forKey: .vcn)
        channelVcn = container.liveTVString(forKey: .channelVcn)
        identifier = container.liveTVString(forKey: .identifier)
        key = container.liveTVString(forKey: .key)
        isHD = container.liveTVBool(forKey: .isHD)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        callSign = try container.decodeIfPresent(String.self, forKey: .callSign)
        language = try container.decodeIfPresent(String.self, forKey: .language)
    }
}

/// A guide or watch-now program (`Metadata` of `{gridKey}` and
/// `{provider}/watchnow/all`).
struct PlexLiveProgramDTO: Decodable, Sendable {
    let ratingKey: String?
    let key: String?
    let guid: String?
    let title: String?
    let summary: String?
    let thumb: String?
    let art: String?
    let grandparentTitle: String?
    let parentTitle: String?
    let type: MediaKind?
    let duration: Int?
    /// `Media`: one entry per airing of the program.
    let airings: [PlexLiveAiringDTO]?

    private enum CodingKeys: String, CodingKey {
        case ratingKey, key, guid, title, summary, thumb, art, grandparentTitle, parentTitle
        case type, duration
        case airings = "Media"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        guid = try? container.decodeIfPresent(String.self, forKey: .guid)
        ratingKey = container.liveTVString(forKey: .ratingKey)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        type = try container.decodeIfPresent(MediaKind.self, forKey: .type)
        duration = container.liveTVNumericInt(forKey: .duration)
        airings = try container.decodeIfPresent([PlexLiveAiringDTO].self, forKey: .airings)
    }
}

/// One airing of a guide program (a program's `Media` entry).
struct PlexLiveAiringDTO: Decodable, Sendable {
    let id: Int?
    let beginsAt: TimeInterval?
    let endsAt: TimeInterval?
    let channelID: Int?
    let channelIdentifier: String?
    let channelThumb: String?
    let channelTitle: String?
    let channelVCN: String?
    let channelCallSign: String?
    let gridKey: String?
    let videoResolution: String?

    private enum CodingKeys: String, CodingKey {
        case id, beginsAt, endsAt, channelID, channelIdentifier, channelThumb
        case channelTitle, channelVCN = "channelVcn", channelCallSign, gridKey
        case videoResolution
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.liveTVNumericInt(forKey: .id)
        beginsAt = container.liveTVTime(forKey: .beginsAt)
        endsAt = container.liveTVTime(forKey: .endsAt)
        channelID = container.liveTVNumericInt(forKey: .channelID)
        channelIdentifier = container.liveTVString(forKey: .channelIdentifier)
        channelThumb = try container.decodeIfPresent(String.self, forKey: .channelThumb)
        channelTitle = try container.decodeIfPresent(String.self, forKey: .channelTitle)
        channelVCN = container.liveTVString(forKey: .channelVCN)
        channelCallSign = try container.decodeIfPresent(String.self, forKey: .channelCallSign)
        gridKey = container.liveTVString(forKey: .gridKey)
        videoResolution = try container.decodeIfPresent(String.self, forKey: .videoResolution)
    }
}

// MARK: - Response envelopes

/// `/media/providers`: the server's media providers; a Live TV one carries
/// the DVR and its guide grid.
struct PlexMediaProvidersResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let MediaProvider: [Provider]?
    }

    struct Provider: Decodable {
        let id: Int?
        let parentID: Int?
        let identifier: String?
        let providerIdentifier: String?
        let title: String?
        let protocols: String?
        let Feature: [Feature]?

        private enum CodingKeys: String, CodingKey {
            case id, parentID, identifier, providerIdentifier, title, protocols, Feature
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.liveTVNumericInt(forKey: .id)
            parentID = container.liveTVNumericInt(forKey: .parentID)
            identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            providerIdentifier = try container.decodeIfPresent(String.self, forKey: .providerIdentifier)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            protocols = try container.decodeIfPresent(String.self, forKey: .protocols)
            Feature = try container.decodeIfPresent(
                [PlexMediaProvidersResponse.Feature].self,
                forKey: .Feature
            )
        }
    }

    struct Feature: Decodable {
        // Optional so one odd feature can't fail the whole provider list, and
        // with it Live TV discovery.
        let type: String?
        let key: String?
    }
}

struct PlexLiveChannelsResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let Channel: [PlexLiveChannelDTO]?
    }
}

/// `/livetv/dvrs/{id}`: the DVR with its devices and their channel mappings.
struct PlexLiveTVDVRResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let Dvr: [Dvr]?
    }

    struct Dvr: Decodable {
        let Device: [Device]?
    }

    struct Device: Decodable {
        let key: String?
        let title: String?
        let make: String?
        let model: String?
        let ChannelMapping: [ChannelMapping]?

        private enum CodingKeys: String, CodingKey {
            case key, title, make, model, ChannelMapping
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = container.liveTVDeviceString(forKey: .key)
            title = container.liveTVDeviceString(forKey: .title)
            make = container.liveTVDeviceString(forKey: .make)
            model = container.liveTVDeviceString(forKey: .model)
            ChannelMapping = try? container.decodeIfPresent([PlexLiveTVDVRResponse.ChannelMapping].self, forKey: .ChannelMapping)
        }
    }

    struct ChannelMapping: Decodable {
        let channelKey: String?
        let enabled: Bool

        private enum CodingKeys: String, CodingKey {
            case channelKey, enabled
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            channelKey = container.liveTVDeviceString(forKey: .channelKey)
            enabled = container.liveTVDeviceString(forKey: .enabled) != "0"
        }
    }
}

/// `POST /livetv/dvrs/{id}/channels/{channel}/tune`.
struct PlexLiveTuneResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let Metadata: [PlayableMetadata]
        let MediaSubscription: [MediaSubscription]
        let Video: [PlayableMetadata]
        let message: String?

        private enum CodingKeys: String, CodingKey {
            case Metadata, MediaSubscription, Video, message
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            Metadata = container.liveTVOneOrMany(PlayableMetadata.self, forKey: .Metadata)
            MediaSubscription = container.liveTVOneOrMany(
                PlexLiveTuneResponse.MediaSubscription.self,
                forKey: .MediaSubscription
            )
            Video = container.liveTVOneOrMany(PlayableMetadata.self, forKey: .Video)
            message = try container.decodeIfPresent(String.self, forKey: .message)
        }

        var tunedSession: TunedSession? {
            for subscription in MediaSubscription {
                for operation in subscription.MediaGrabOperation {
                    if let session = operation.Metadata.lazy.compactMap(\.tunedSession).first {
                        return session
                    }
                    if let session = operation.Video.lazy.compactMap(\.tunedSession).first {
                        return session
                    }
                }
            }

            return Metadata.lazy.compactMap(\.tunedSession).first
                ?? Video.lazy.compactMap(\.tunedSession).first
        }

        /// Why Plex refused the tune, for a response without a session. A
        /// tuner conflict (a one-tuner HDHomeRun/Threadfin device already on
        /// another channel; Plex keeps a closed channel's tuner for a few
        /// minutes) gets a message that says so instead of a parse error.
        var tuneFailureMessage: String? {
            let operations = MediaSubscription.flatMap(\.MediaGrabOperation)
            if operations.contains(where: \.hasConflicts)
                || operations.contains(where: { $0.error?.localizedCaseInsensitiveContains("conflict") == true }) {
                return String(
                    localized: "All tuners are in use. Stop another Live TV stream or recording, or try again in a few minutes."
                )
            }
            return operations.lazy.compactMap { $0.error?.nilIfEmpty }.first
                ?? message?.nilIfEmpty
        }
    }

    struct PlayableMetadata: Decodable {
        let key: String?
        let Media: [TuneMedia]

        private enum CodingKeys: String, CodingKey {
            case key, Media
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decodeIfPresent(String.self, forKey: .key)
            Media = container.liveTVOneOrMany(TuneMedia.self, forKey: .Media)
        }

        var tunedSession: TunedSession? {
            let media = Media.first
            guard let sessionPath = Self.liveSessionPath(from: key)
                    ?? media?.sessionPath else {
                return nil
            }
            return TunedSession(
                sessionPath: sessionPath,
                playbackPath: media?.playbackPath,
                media: media
            )
        }

        static func liveSessionPath(from value: String?) -> String? {
            guard let value,
                  let range = value.range(of: "/livetv/sessions/") else {
                return nil
            }
            let livePath = value[range.lowerBound...]
            let components = livePath
                .split(separator: "?", maxSplits: 1)
                .first?
                .split(separator: "/", omittingEmptySubsequences: true)
            guard let components, components.count >= 3 else { return nil }
            return "/" + components.prefix(3).joined(separator: "/")
        }
    }

    struct MediaSubscription: Decodable {
        let MediaGrabOperation: [MediaGrabOperation]

        private enum CodingKeys: String, CodingKey {
            case MediaGrabOperation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            MediaGrabOperation = container.liveTVOneOrMany(
                PlexLiveTuneResponse.MediaGrabOperation.self,
                forKey: .MediaGrabOperation
            )
        }
    }

    struct MediaGrabOperation: Decodable {
        let Metadata: [PlayableMetadata]
        let Video: [PlayableMetadata]
        /// "inprogress" for a tuned channel, "error" when the grab was refused.
        let status: String?
        /// Why a refused grab failed, e.g. "The recording conflicts with other
        /// recordings" when every tuner of the device is in use.
        let error: String?
        /// Present when the grab was refused for a tuner conflict.
        let hasConflicts: Bool

        private enum CodingKeys: String, CodingKey {
            case Metadata, Video, status, error, Conflicts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            Metadata = container.liveTVOneOrMany(PlayableMetadata.self, forKey: .Metadata)
            Video = container.liveTVOneOrMany(PlayableMetadata.self, forKey: .Video)
            status = container.liveTVString(forKey: .status)
            error = container.liveTVString(forKey: .error)
            hasConflicts = container.contains(.Conflicts)
        }
    }

    struct TunedSession {
        let sessionPath: String
        let playbackPath: String?
        let media: TuneMedia?

        var sessionID: String? {
            sessionPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .last
                .map(String.init)?
                .nilIfEmpty
        }
    }

    struct TuneMedia: Decodable {
        let id: Int?
        let uuid: String?
        let container: String?
        let videoCodec: String?
        let audioCodec: String?
        let videoResolution: String?
        let audioChannels: Int?
        let width: Int?
        let height: Int?
        let bitrate: Int?
        let duration: Int?
        let Part: [TunePart]?

        private enum CodingKeys: String, CodingKey {
            case id, uuid, container, videoCodec, audioCodec, videoResolution, audioChannels
            case width, height, bitrate, duration, Part
        }

        // The tune answer is not typed like library metadata: PMS 1.43 sends
        // `Media.id`, `Part.id` and `Stream.id` as strings ("222512"). One
        // strict `Int` threw away the whole Media, so the session fell back to
        // codec-less media, the resolver sent it to VLCKit as "unknown" video
        // and Plex Live TV only ever played (if at all) through libvlc's HLS.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.liveTVLenientInt(forKey: .id)
            uuid = container.liveTVString(forKey: .uuid)
            self.container = container.liveTVString(forKey: .container)
            videoCodec = container.liveTVString(forKey: .videoCodec)
            audioCodec = container.liveTVString(forKey: .audioCodec)
            videoResolution = container.liveTVString(forKey: .videoResolution)
            audioChannels = container.liveTVLenientInt(forKey: .audioChannels)
            width = container.liveTVLenientInt(forKey: .width)
            height = container.liveTVLenientInt(forKey: .height)
            bitrate = container.liveTVLenientInt(forKey: .bitrate)
            duration = container.liveTVLenientInt(forKey: .duration)
            let parts = container.liveTVOneOrMany(TunePart.self, forKey: .Part)
            Part = parts.isEmpty ? nil : parts
        }

        var sessionPath: String? {
            if let uuid = uuid?.nilIfEmpty {
                return "/livetv/sessions/\(uuid)"
            }
            return Part?.lazy
                .compactMap(\.key)
                .compactMap(PlayableMetadata.liveSessionPath)
                .first
        }

        var playbackPath: String? {
            Part?.lazy
                .compactMap(\.key)
                .first { $0.contains("/livetv/sessions/") }
        }

        /// Whether the live session's own HLS (the tuner stream as the
        /// grabber copies it, no re-encode) plays in AVPlayer as it is:
        /// MPEG-TS with progressive 8-bit H.264 and AAC/AC-3/E-AC-3/MP3
        /// audio. Anything else (MPEG-2 broadcast video, interlaced or 10-bit
        /// H.264, MP2 audio, unknown codecs) goes through the transcoder.
        var supportsLiveDirectPlay: Bool {
            let streams = (Part ?? []).flatMap { $0.Stream ?? [] }
            let video = streams.filter { $0.kind == StreamKind.video.rawValue }
            let audio = streams.filter { $0.kind == StreamKind.audio.rawValue }
            guard (container ?? "mpegts").lowercased() == "mpegts",
                  (videoCodec ?? video.first?.codec)?.lowercased() == "h264",
                  !video.contains(where: { $0.scanType?.lowercased() == "interlaced" }),
                  !video.contains(where: { ($0.bitDepth ?? 8) > 8 }) else {
                return false
            }
            let audioCodecs = audio.isEmpty
                ? [audioCodec].compactMap { $0?.lowercased() }
                : audio.map { $0.codec?.lowercased() ?? "" }
            return !audioCodecs.isEmpty
                && audioCodecs.allSatisfy { ["aac", "ac3", "eac3", "mp3"].contains($0) }
        }
    }

    struct TunePart: Decodable {
        let id: Int?
        let key: String?
        let container: String?
        let duration: Int?
        let Stream: [TuneStream]?

        private enum CodingKeys: String, CodingKey {
            case id, key, container, duration, Stream
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.liveTVLenientInt(forKey: .id)
            key = container.liveTVString(forKey: .key)
            self.container = container.liveTVString(forKey: .container)
            duration = container.liveTVLenientInt(forKey: .duration)
            let streams = container.liveTVOneOrMany(TuneStream.self, forKey: .Stream)
            Stream = streams.isEmpty ? nil : streams
        }
    }

    struct TuneStream: Decodable {
        let id: Int?
        let index: Int?
        let kind: Int?
        let codec: String?
        let width: Int?
        let height: Int?
        let bitrate: Int?
        let frameRate: Double?
        let bitDepth: Int?
        let profile: String?
        let level: Int?
        let channels: Int?
        let audioChannelLayout: String?
        let samplingRate: Int?
        let scanType: String?

        private enum CodingKeys: String, CodingKey {
            case id, index, kind = "streamType", codec, width, height, bitrate, frameRate, bitDepth
            case profile, level, channels, audioChannelLayout, samplingRate, scanType
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.liveTVLenientInt(forKey: .id)
            index = container.liveTVLenientInt(forKey: .index)
            kind = container.liveTVLenientInt(forKey: .kind)
            codec = container.liveTVString(forKey: .codec)
            width = container.liveTVLenientInt(forKey: .width)
            height = container.liveTVLenientInt(forKey: .height)
            bitrate = container.liveTVLenientInt(forKey: .bitrate)
            frameRate = container.liveTVDouble(forKey: .frameRate)
            bitDepth = container.liveTVLenientInt(forKey: .bitDepth)
            profile = container.liveTVString(forKey: .profile)
            level = container.liveTVLenientInt(forKey: .level)
            channels = container.liveTVLenientInt(forKey: .channels)
            audioChannelLayout = container.liveTVString(forKey: .audioChannelLayout)
            samplingRate = container.liveTVLenientInt(forKey: .samplingRate)
            scanType = container.liveTVString(forKey: .scanType)
        }
    }
}

// MARK: - Lenient field decoding

private extension KeyedDecodingContainer {
    func liveTVOneOrMany<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) -> [T] {
        if let values = try? decode([T].self, forKey: key) {
            return values
        }
        if let value = try? decode(T.self, forKey: key) {
            return [value]
        }
        return []
    }

    /// A string, or an integer sent as a JSON number.
    func liveTVString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    /// An integer, or a string `Int(_:)` reads as one. Guide and provider
    /// fields; the tune answer needs the wider `liveTVLenientInt`.
    func liveTVNumericInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    /// Numbers the tune answer may send as JSON numbers or as strings.
    func liveTVLenientInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int(value)
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return Int(trimmed) ?? Double(trimmed).flatMap { $0.isFinite ? Int($0) : nil }
        }
        return nil
    }

    func liveTVDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Double(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Epoch seconds as a number (integer or not) or a string.
    func liveTVTime(forKey key: Key) -> TimeInterval? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return TimeInterval(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return TimeInterval(value)
        }
        return nil
    }

    /// `true`/`false`, `0`/`1`, or "1"/"true"/"yes" as a string.
    func liveTVBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return nil
    }

    /// DVR device fields: a string, an integer or a boolean ("1"/"0").
    func liveTVDeviceString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? "1" : "0" }
        return nil
    }
}
