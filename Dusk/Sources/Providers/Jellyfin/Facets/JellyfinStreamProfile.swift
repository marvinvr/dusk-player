import Foundation

/// The `PlaybackInfo` request for one server stream, and what the answer
/// predicts the server will do (docs/jellyfin/03-prior-art.md §5.4,
/// 04-architecture.md §12.2). Pure; `JellyfinPlayback` sends it.
///
/// The profile does not ask the server to decide: it describes exactly the
/// stream Dusk's ladder already chose. No direct-play entry (the ladder only
/// asks for a server stream when it wants one), one HLS fMP4 transcoding
/// profile, and a range-type list that is what this attempt may show.
///
/// Measured on jellyfin-demo 12.4:
/// - a remux profile whose codecs are exactly the source's copies both
///   (`TranscodingInfo.IsVideoDirect/IsAudioDirect`), Atmos `dec3` and the
///   8.1 `dvvC` intact;
/// - range types without the Dolby Vision ones strip Dolby Vision and still
///   copy: the HDR10/HLG base layer;
/// - profile 7 keeps its `dvcC` (for the on-device 8.1 conversion) only when
///   `DOVI` is claimed along with `DOVIWithEL`; `DOVIWithEL` alone gives the
///   base layer;
/// - `MediaSourceId`, `AudioStreamIndex` and `SubtitleStreamIndex` are always
///   sent: without them the server swaps the audio track or burns in a PGS
///   subtitle (02 §10);
/// - `AllowVideoStreamCopy`/`AllowAudioStreamCopy` false reach the stream URL
///   and force the re-encode a manual quality asks for.
enum JellyfinStreamProfile {
    /// Bits per second high enough that bitrate is never a transcode reason
    /// on the uncapped rungs.
    static let uncappedBitrate = 400_000_000

    static let baseRanges: [JellyfinVideoRangeType] = [.sdr, .hdr10, .hdr10Plus, .hlg]
    static let dolbyVisionRanges: [JellyfinVideoRangeType] = [.dovi, .doviWithHDR10, .doviWithHLG, .doviWithSDR]
    static let enhancementLayerRanges: [JellyfinVideoRangeType] = [.doviWithEL, .doviWithELHDR10Plus]

    /// The tracks a request names, as the source's stream indexes.
    struct Tracks: Equatable {
        /// nil: the source has no audio.
        var audio: JellyfinMediaStreamDTO?
        /// nil: subtitles off.
        var subtitle: JellyfinMediaStreamDTO?
        var subtitleDelivery: SubtitleDelivery
    }

    // MARK: Request

    static func request(
        intent: StreamIntent,
        source: JellyfinMediaSourceDTO,
        tracks: Tracks,
        dolbyVision: RemuxDolbyVision,
        av1HardwareDecode: Bool
    ) -> JellyfinPlaybackInfoRequestDTO {
        let video = source.streams.first { $0.type == .video }
        let sourceVideoCodec = JellyfinCodecAliases.codec(video?.codec)
        let sourceAudioCodec = JellyfinCodecAliases.codec(tracks.audio?.codec)

        let videoCodecs: String
        let audioCodecs: String
        var maxAudioChannels = "8"
        var container = "mp4"
        var ranges = baseRanges
        var copiesVideo = true
        var copiesAudio = true
        var maxBitrate = uncappedBitrate
        var sizeConditions: [JellyfinProfileConditionDTO] = []

        switch intent {
        case .losslessRemux:
            videoCodecs = sourceVideoCodec ?? "hevc"
            audioCodecs = sourceAudioCodec ?? "aac"
            ranges += claimedRanges(dolbyVision)
        case let .convertedAudioRemux(target):
            videoCodecs = sourceVideoCodec ?? "hevc"
            audioCodecs = target.codec
            maxAudioChannels = target.channels.map(String.init) ?? "8"
            ranges += claimedRanges(dolbyVision)
        case .videoCopyFallback where tracks.subtitle != nil && tracks.subtitleDelivery == .burnIn:
            // A burned-in subtitle re-encodes the video anyway: H.264 in
            // MPEG-TS, like a manual quality (the fMP4 init of that re-encode
            // is unreadable for a Dolby Vision MKV, measured on Knives Out).
            videoCodecs = "h264"
            audioCodecs = "eac3,ac3,aac"
            container = "ts"
            ranges = [.sdr]
        case .videoCopyFallback:
            videoCodecs = av1HardwareDecode ? "hevc,h264,av1" : "hevc,h264"
            audioCodecs = "eac3,ac3,aac"
            // Profile 5 has no base layer to fall back to: without the claim
            // the server would re-encode it.
            if video?.videoRangeType == .dovi { ranges += [.dovi] }
        case .av1Fallback:
            videoCodecs = "hevc,h264"
            audioCodecs = "eac3,ac3,aac"
            copiesVideo = false
        case let .quality(preset):
            // H.264 in MPEG-TS, Plex's quality target too. Measured: the
            // server's fMP4 init segment for an H.264 re-encode of Knives Out
            // (Dolby Vision 8.1 MKV) is unreadable (`stsd` of size 0, a
            // `dby1` brand); the same request as MPEG-TS plays.
            videoCodecs = "h264"
            audioCodecs = "eac3,ac3,aac"
            container = "ts"
            ranges = [.sdr]
            copiesVideo = false
            copiesAudio = false
            if let kbps = preset.videoBitrateKbps { maxBitrate = kbps * 1000 }
            sizeConditions = sizeLimits(preset.videoResolution)
        case .airPlay:
            // What any receiver plays: H.264 + stereo AAC in MPEG-TS, the
            // subtitle burned in (Plex's AirPlay target).
            videoCodecs = "h264"
            audioCodecs = "aac"
            maxAudioChannels = "2"
            container = "ts"
            ranges = [.sdr]
        case .live:
            // Live TV is J-09; never asked for a Jellyfin item.
            videoCodecs = "h264"
            audioCodecs = "aac"
        }

        let transcoding = JellyfinTranscodingProfileDTO(
            protocol: "hls",
            container: container,
            videoCodec: videoCodecs,
            audioCodec: audioCodecs,
            maxAudioChannels: maxAudioChannels,
            minSegments: 1,
            enableSubtitlesInManifest: tracks.subtitle != nil && tracks.subtitleDelivery == .inManifest
        )

        var codecProfiles = videoCodecs.split(separator: ",").map { codec in
            JellyfinCodecProfileDTO(
                codec: String(codec),
                conditions: [JellyfinProfileConditionDTO(
                    condition: "EqualsAny",
                    property: "VideoRangeType",
                    value: ranges.map(\.rawValue).joined(separator: "|")
                )]
            )
        }
        if !sizeConditions.isEmpty {
            codecProfiles = codecProfiles.map { profile in
                var profile = profile
                profile.conditions += sizeConditions
                return profile
            }
        }

        var profile = JellyfinDeviceProfileDTO(
            name: "Dusk",
            directPlayProfiles: [],
            transcodingProfiles: [transcoding],
            codecProfiles: codecProfiles,
            subtitleProfiles: subtitleProfiles(tracks)
        )
        profile.maxStreamingBitrate = maxBitrate

        var request = JellyfinPlaybackInfoRequestDTO(
            mediaSourceID: source.id,
            audioStreamIndex: tracks.audio?.index ?? -1,
            subtitleStreamIndex: tracks.subtitle?.index ?? -1,
            deviceProfile: profile
        )
        request.maxStreamingBitrate = maxBitrate
        request.enableDirectPlay = false
        request.allowVideoStreamCopy = copiesVideo
        request.allowAudioStreamCopy = copiesAudio
        return request
    }

    /// The range types a remux attempt adds to the base list.
    static func claimedRanges(_ dolbyVision: RemuxDolbyVision) -> [JellyfinVideoRangeType] {
        switch dolbyVision {
        case .none: []
        case .native: dolbyVisionRanges
        case .profile7Conversion: dolbyVisionRanges + enhancementLayerRanges
        }
    }

    /// A text subtitle rides the remux as a WebVTT rendition (`Hls`, the
    /// segments Plex's remux carries too); anything else is burned in, which
    /// the remux rungs refuse from the prediction. Off sends no profile.
    private static func subtitleProfiles(_ tracks: Tracks) -> [JellyfinSubtitleProfileDTO] {
        guard let subtitle = tracks.subtitle, tracks.subtitleDelivery == .inManifest,
              subtitle.isTextSubtitleStream == true else { return [] }
        return [JellyfinSubtitleProfileDTO(format: "vtt", method: .hls)]
    }

    /// `"1280x720"` → `Width ≤ 1280`, `Height ≤ 720`.
    private static func sizeLimits(_ resolution: String?) -> [JellyfinProfileConditionDTO] {
        let parts = (resolution ?? "").split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return [] }
        return [
            JellyfinProfileConditionDTO(condition: "LessThanEqual", property: "Width", value: String(parts[0]), isRequired: true),
            JellyfinProfileConditionDTO(condition: "LessThanEqual", property: "Height", value: String(parts[1]), isRequired: true),
        ]
    }

    // MARK: Answer

    /// Video reasons that mean a re-encode. `VideoRangeTypeNotSupported` is
    /// one only for a source without an HDR10/HLG base layer to copy.
    private static let videoReasons: Set<String> = [
        "VideoCodecNotSupported", "VideoProfileNotSupported", "VideoLevelNotSupported",
        "VideoResolutionNotSupported", "VideoBitDepthNotSupported", "VideoFramerateNotSupported",
        "RefFramesNotSupported", "AnamorphicVideoNotSupported", "InterlacedVideoNotSupported",
        "VideoBitrateNotSupported", "ContainerBitrateExceedsLimit", "SubtitleCodecNotSupported",
        "VideoCodecTagNotSupported", "VideoRangeTypeNotSupported",
    ]

    private static let audioReasons: Set<String> = [
        "AudioCodecNotSupported", "AudioChannelsNotSupported", "AudioProfileNotSupported",
        "AudioSampleRateNotSupported", "AudioBitrateNotSupported", "AudioBitDepthNotSupported",
        "SecondaryAudioNotSupported", "UnknownAudioStreamInfo", "AudioIsExternal",
    ]

    /// Ranges whose base layer the server copies when Dolby Vision is not claimed.
    private static let rangesWithBaseLayer: Set<JellyfinVideoRangeType> = [
        .doviWithHDR10, .doviWithHLG, .doviWithSDR, .doviWithEL, .doviWithELHDR10Plus, .doviWithHDR10Plus, .hdr10Plus,
    ]

    /// What the server will do with each track, read from the transcoding
    /// URL it answered (codec lists, reasons, copy flags, subtitle method).
    /// A prediction: `JellyfinPlayback.confirm` checks it against the session
    /// once the stream plays.
    static func predictedDecisions(
        transcodingURL: String,
        source: JellyfinMediaSourceDTO,
        tracks: Tracks
    ) -> StreamDecisions {
        let query = URLComponents(string: transcodingURL)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        func list(_ name: String) -> [String] {
            (value(name) ?? "").split(separator: ",").compactMap { JellyfinCodecAliases.codec(String($0)) }
        }
        let reasons = Set(JellyfinTranscodeReason.list(value("TranscodeReasons")).map(\.rawValue))
        let video = source.streams.first { $0.type == .video }
        let sourceVideoCodec = JellyfinCodecAliases.codec(video?.codec)
        let videoCodecs = list("VideoCodec")
        let audioCodecs = list("AudioCodec")

        let subtitleMethod = value("SubtitleMethod")
        let burnsSubtitle = tracks.subtitle != nil
            && subtitleMethod?.caseInsensitiveCompare(JellyfinSubtitleDeliveryMethod.encode.rawValue) == .orderedSame

        var videoReasonsHit = reasons.intersection(videoReasons)
        if videoReasonsHit == ["VideoRangeTypeNotSupported"],
           let range = video?.videoRangeType, rangesWithBaseLayer.contains(range) {
            videoReasonsHit = []
        }
        let copiesVideo = value("AllowVideoStreamCopy")?.lowercased() != "false"
            && videoReasonsHit.isEmpty
            && !burnsSubtitle
            && sourceVideoCodec.map(videoCodecs.contains) == true

        var decisions = StreamDecisions(
            container: container(value("SegmentContainer")),
            video: copiesVideo ? .copy : .convert,
            videoCodec: copiesVideo ? sourceVideoCodec : videoCodecs.first,
            audio: nil,
            audioCodec: nil
        )

        if let audio = tracks.audio {
            let sourceAudioCodec = JellyfinCodecAliases.codec(audio.codec)
            let copiesAudio = value("AllowAudioStreamCopy")?.lowercased() != "false"
                && reasons.isDisjoint(with: audioReasons)
                && sourceAudioCodec.map(audioCodecs.contains) == true
            decisions.audio = copiesAudio ? .copy : .convert
            decisions.audioCodec = copiesAudio ? sourceAudioCodec : audioCodecs.first
            if copiesAudio {
                decisions.audioChannels = audio.channels
                decisions.audioProfile = audio.profile?.lowercased()
            } else {
                // ffmpeg's AC-3/E-AC-3 encoders stop at 5.1 (Dune's 7.1
                // TrueHD came back 6 channels); AAC follows the cap.
                let cap = Int(value("TranscodingMaxAudioChannels") ?? "") ?? 8
                let encoderCap = ["eac3", "ac3"].contains(decisions.audioCodec ?? "") ? 6 : cap
                decisions.audioChannels = audio.channels.map { min($0, cap, encoderCap) }
            }
        }

        if tracks.subtitle != nil {
            if subtitleMethod?.caseInsensitiveCompare(JellyfinSubtitleDeliveryMethod.hls.rawValue) == .orderedSame {
                decisions.subtitle = .textSegments
            } else {
                decisions.subtitle = .other(subtitleMethod?.lowercased() ?? "burn")
            }
        }
        return decisions
    }

    /// What the session says the server really does (`TranscodingInfo`).
    static func confirmedDecisions(_ info: JellyfinTranscodingInfoDTO, predicted: StreamDecisions) -> StreamDecisions {
        var decisions = StreamDecisions(
            container: container(info.container),
            video: info.isVideoDirect.map { $0 ? .copy : .convert },
            videoCodec: JellyfinCodecAliases.codec(info.videoCodec),
            audio: nil,
            audioCodec: nil
        )
        if predicted.audio != nil {
            decisions.audio = info.isAudioDirect.map { $0 ? .copy : .convert }
            decisions.audioCodec = JellyfinCodecAliases.codec(info.audioCodec)
            decisions.audioChannels = info.audioChannels
        }
        decisions.subtitle = predicted.subtitle
        return decisions
    }

    private static func container(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case nil: nil
        case "ts", "mpegts": "mpegts"
        case "fmp4": "mp4"
        case let value?: value
        }
    }
}
