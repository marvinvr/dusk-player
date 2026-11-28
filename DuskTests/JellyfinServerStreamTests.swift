import Foundation
import Testing
@testable import Dusk

/// J-06 (docs/jellyfin/05-plan.md): server streams on Jellyfin. The
/// `PlaybackInfo` answers were recorded from jellyfin-demo 12.4 with the
/// profiles `JellyfinStreamProfile` builds (token and device id replaced),
/// and the copies they predict were confirmed there through
/// `GET /Sessions` → `TranscodingInfo`.
@MainActor
@Suite("Jellyfin server streams")
struct JellyfinServerStreamTests {
    private func answer(_ name: String) throws -> JellyfinPlaybackInfoResponseDTO {
        try JellyfinFixtures.decode(JellyfinPlaybackInfoResponseDTO.self, "playback-info-\(name)")
    }

    private func source(_ name: String) throws -> JellyfinMediaSourceDTO {
        try #require(try answer(name).mediaSources.first)
    }

    private func tracks(
        _ source: JellyfinMediaSourceDTO,
        audio: Int?,
        subtitle: Int? = nil,
        delivery: SubtitleDelivery = .inManifest
    ) -> JellyfinStreamProfile.Tracks {
        JellyfinStreamProfile.Tracks(
            audio: audio.flatMap { index in source.streams.first { $0.index == index } },
            subtitle: subtitle.flatMap { index in source.streams.first { $0.index == index } },
            subtitleDelivery: delivery
        )
    }

    private func request(
        _ intent: StreamIntent,
        audio: String? = nil,
        subtitle: SubtitleRequest = .none
    ) -> ServerStreamRequest {
        ServerStreamRequest(
            itemID: "980dffd6dfa0d8cfd69e5bd6b350e983", mediaIndex: 0, intent: intent,
            playbackSessionID: "player-1", streamSessionID: "stream-1",
            audioStreamID: audio, subtitle: subtitle
        )
    }

    private func ranges(_ body: JellyfinPlaybackInfoRequestDTO) -> [String] {
        (body.deviceProfile?.codecProfiles.first?.conditions.first { $0.property == "VideoRangeType" }?.value ?? "")
            .split(separator: "|").map(String.init)
    }

    // MARK: Request

    @Test("a lossless remux asks for exactly the source's codecs, no direct play, explicit indexes")
    func losslessRemuxRequest() throws {
        let knives = try source("knives-out-remux")
        let body = JellyfinStreamProfile.request(
            intent: .losslessRemux, source: knives, tracks: tracks(knives, audio: 1),
            dolbyVision: .native, av1HardwareDecode: false
        )
        let profile = try #require(body.deviceProfile)
        #expect(profile.directPlayProfiles.isEmpty)
        let transcoding = try #require(profile.transcodingProfiles.first)
        #expect(transcoding.protocol == "hls")
        #expect(transcoding.container == "mp4")
        #expect(transcoding.videoCodec == "hevc")
        #expect(transcoding.audioCodec == "eac3")
        #expect(body.mediaSourceID == "980dffd6dfa0d8cfd69e5bd6b350e983")
        #expect(body.audioStreamIndex == 1)
        #expect(body.subtitleStreamIndex == -1)
        #expect(body.maxStreamingBitrate == JellyfinStreamProfile.uncappedBitrate)
        #expect(profile.subtitleProfiles.isEmpty)
        #expect(ranges(body).contains("DOVIWithHDR10"))
        #expect(!ranges(body).contains("DOVIWithEL"))
    }

    @Test("Dolby Vision claims: none strips it, profile 7 conversion needs DOVI as well as DOVIWithEL")
    func dolbyVisionClaims() throws {
        let dune = try source("dune-converted-dv7")
        func claimed(_ dolbyVision: RemuxDolbyVision) -> [String] {
            ranges(JellyfinStreamProfile.request(
                intent: .convertedAudioRemux(target: .surroundEAC3), source: dune, tracks: tracks(dune, audio: 1),
                dolbyVision: dolbyVision, av1HardwareDecode: false
            ))
        }
        #expect(claimed(.none) == ["SDR", "HDR10", "HDR10Plus", "HLG"])
        // Measured: DOVIWithEL without DOVI comes back hvc1 with no dvcC.
        #expect(claimed(.profile7Conversion).contains("DOVI"))
        #expect(claimed(.profile7Conversion).contains("DOVIWithEL"))
        #expect(!claimed(.native).contains("DOVIWithEL"))
    }

    @Test("converted audio is E-AC-3 surround; a manual quality forbids copies and caps size and bitrate")
    func convertedAndQualityRequests() throws {
        let dune = try source("dune-converted-dv7")
        let converted = JellyfinStreamProfile.request(
            intent: .convertedAudioRemux(target: .surroundEAC3), source: dune, tracks: tracks(dune, audio: 1),
            dolbyVision: .none, av1HardwareDecode: false
        )
        #expect(converted.deviceProfile?.transcodingProfiles.first?.audioCodec == "eac3")
        #expect(converted.deviceProfile?.transcodingProfiles.first?.maxAudioChannels == "8")
        #expect(converted.allowVideoStreamCopy == true)

        let knives = try source("knives-out-remux")
        let quality = JellyfinStreamProfile.request(
            intent: .quality(.p720_4Mbps), source: knives, tracks: tracks(knives, audio: 1, delivery: .burnIn),
            dolbyVision: .native, av1HardwareDecode: false
        )
        #expect(quality.deviceProfile?.transcodingProfiles.first?.container == "ts")
        #expect(quality.allowVideoStreamCopy == false)
        #expect(quality.allowAudioStreamCopy == false)
        #expect(quality.maxStreamingBitrate == 4_000_000)
        #expect(ranges(quality) == ["SDR"])
        let conditions = quality.deviceProfile?.codecProfiles.first?.conditions ?? []
        #expect(conditions.contains { $0.property == "Width" && $0.value == "1280" })
        #expect(conditions.contains { $0.property == "Height" && $0.value == "720" })
    }

    @Test("the server-stream rung copies into fMP4, and burns a subtitle in as H.264 in MPEG-TS")
    func videoCopyFallbackRequests() throws {
        let knives = try source("knives-out-remux")
        let copy = JellyfinStreamProfile.request(
            intent: .videoCopyFallback, source: knives, tracks: tracks(knives, audio: 1, delivery: .burnIn),
            dolbyVision: .none, av1HardwareDecode: false
        )
        #expect(copy.deviceProfile?.transcodingProfiles.first?.container == "mp4")
        #expect(copy.deviceProfile?.transcodingProfiles.first?.videoCodec == "hevc,h264")
        #expect(copy.subtitleStreamIndex == -1)

        let burned = JellyfinStreamProfile.request(
            intent: .videoCopyFallback, source: knives, tracks: tracks(knives, audio: 1, subtitle: 4, delivery: .burnIn),
            dolbyVision: .none, av1HardwareDecode: false
        )
        #expect(burned.deviceProfile?.transcodingProfiles.first?.container == "ts")
        #expect(burned.deviceProfile?.transcodingProfiles.first?.videoCodec == "h264")
        #expect(burned.subtitleStreamIndex == 4)
        #expect(burned.deviceProfile?.subtitleProfiles.isEmpty == true)
    }

    @Test("a text subtitle rides the remux as an HLS rendition; a bitmap one gets no profile")
    func subtitleProfiles() throws {
        let knives = try source("knives-out-remux")
        let text = JellyfinStreamProfile.request(
            intent: .losslessRemux, source: knives, tracks: tracks(knives, audio: 1, subtitle: 15),
            dolbyVision: .native, av1HardwareDecode: false
        )
        #expect(text.subtitleStreamIndex == 15)
        #expect(text.deviceProfile?.subtitleProfiles == [JellyfinSubtitleProfileDTO(format: "vtt", method: .hls)])
        #expect(text.deviceProfile?.transcodingProfiles.first?.enableSubtitlesInManifest == true)

        let pgs = JellyfinStreamProfile.request(
            intent: .losslessRemux, source: knives, tracks: tracks(knives, audio: 1, subtitle: 4),
            dolbyVision: .native, av1HardwareDecode: false
        )
        #expect(pgs.deviceProfile?.subtitleProfiles.isEmpty == true)
    }

    @Test("track ids map to indexes; no audio id takes the server's default; a burned-in \"0\" is off")
    func trackMapping() throws {
        let knives = try source("knives-out-remux")
        let defaults = JellyfinPlayback.tracks(for: request(.videoCopyFallback), in: knives)
        #expect(defaults.audio?.index == knives.defaultAudioStreamIndex)
        #expect(defaults.subtitle == nil)

        let off = JellyfinPlayback.tracks(
            for: request(.av1Fallback, audio: "2", subtitle: .stream(id: "0", delivery: .burnIn)), in: knives
        )
        #expect(off.audio?.index == 2)
        #expect(off.subtitle == nil)

        let remux = JellyfinPlayback.tracks(
            for: request(.losslessRemux, audio: "1", subtitle: .stream(id: "15", delivery: .inManifest)), in: knives
        )
        #expect(remux.subtitle?.index == 15)
        #expect(remux.subtitleDelivery == .inManifest)
    }

    // MARK: Answer

    @Test("Knives Out remux predicts the lossless copy the coordinator accepts, Atmos kept")
    func knivesOutPrediction() throws {
        let answer = try answer("knives-out-remux")
        let knives = try #require(answer.mediaSources.first)
        let url = try #require(knives.transcodingURL)
        let decisions = JellyfinStreamProfile.predictedDecisions(
            transcodingURL: url, source: knives, tracks: tracks(knives, audio: 1)
        )
        #expect(decisions.isLosslessRemux)
        #expect(decisions.container == "mp4")
        #expect(decisions.videoCodec == "hevc")
        #expect(decisions.audioCodec == "eac3")
        #expect(decisions.audioChannels == 6)
        #expect(decisions.hasDolbyAtmosAudio)
        #expect(decisions.subtitle == nil)
    }

    @Test("Dune TrueHD converts to E-AC-3 5.1 with the video copied, no Atmos claimed")
    func dunePrediction() throws {
        let dune = try source("dune-converted-dv7")
        let url = try #require(dune.transcodingURL)
        let decisions = JellyfinStreamProfile.predictedDecisions(
            transcodingURL: url, source: dune, tracks: tracks(dune, audio: 1)
        )
        #expect(decisions.video == .copy)
        #expect(decisions.audio == .convert)
        #expect(decisions.audioChannels == 6)
        #expect(decisions.isConvertedAudioRemux(sourceChannels: 8))
        #expect(!decisions.isLosslessRemux)
        #expect(!decisions.hasDolbyAtmosAudio)
    }

    @Test("an HLS subtitle is text segments; a manual quality re-encodes")
    func subtitleAndQualityPrediction() throws {
        let srt = try source("knives-out-remux-srt")
        let srtDecisions = JellyfinStreamProfile.predictedDecisions(
            transcodingURL: try #require(srt.transcodingURL), source: srt, tracks: tracks(srt, audio: 1, subtitle: 15)
        )
        #expect(srtDecisions.subtitle == .textSegments)
        #expect(srtDecisions.isLosslessRemux)

        let quality = try source("knives-out-quality-720p")
        let qualityDecisions = JellyfinStreamProfile.predictedDecisions(
            transcodingURL: try #require(quality.transcodingURL), source: quality,
            tracks: tracks(quality, audio: 1, delivery: .burnIn)
        )
        #expect(qualityDecisions.video == .convert)
        #expect(qualityDecisions.videoCodec == "h264")
        #expect(qualityDecisions.audio == .convert)
    }

    @Test("the session's TranscodingInfo confirms copies")
    func confirmation() {
        let info = try? JellyfinJSON.decode(JellyfinTranscodingInfoDTO.self, from: Data("""
        {"IsVideoDirect": true, "IsAudioDirect": false, "VideoCodec": "hevc", "AudioCodec": "eac3",
         "Container": "mp4", "AudioChannels": 6, "TranscodeReasons": ["AudioCodecNotSupported", "DirectPlayError"]}
        """.utf8))
        let predicted = StreamDecisions(container: "mp4", video: .copy, videoCodec: "hevc", audio: .convert, audioCodec: "eac3")
        let confirmed = info.map { JellyfinStreamProfile.confirmedDecisions($0, predicted: predicted) }
        #expect(confirmed?.video == .copy)
        #expect(confirmed?.audio == .convert)
        #expect(confirmed?.audioChannels == 6)
    }

    @Test("a stream closed before its answer arrives is stopped, not remembered")
    func closeBeforeOpen() {
        let streams = JellyfinServerStreams()
        #expect(streams.close(streamSessionID: "early") == nil)
        #expect(!streams.register(streamSessionID: "early", playSessionID: "play-1"))
        #expect(streams.playSessionID(for: "early") == nil)

        #expect(streams.register(streamSessionID: "normal", playSessionID: "play-2"))
        #expect(streams.playSessionID(for: "normal") == "play-2")
        #expect(streams.close(streamSessionID: "normal") == "play-2")
        #expect(streams.playSessionID(for: "normal") == nil)
    }

    // MARK: Variant filter

    static let knivesMaster = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Arabic - Default - SUBRIP",DEFAULT=NO,FORCED=NO,AUTOSELECT=YES,URI="980d/Subtitles/7/subtitles.m3u8?SegmentLength=30",LANGUAGE="ara"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Spanish - Default - SUBRIP",DEFAULT=YES,FORCED=NO,AUTOSELECT=YES,URI="980d/Subtitles/15/subtitles.m3u8?SegmentLength=30",LANGUAGE="spa"
    #EXT-X-STREAM-INF:BANDWIDTH=8926092,AVERAGE-BANDWIDTH=8926092,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L153.B0,ec-3",SUPPLEMENTAL-CODECS="dvh1.08.10/db1p",RESOLUTION=1920x1038,FRAME-RATE=23.976,SUBTITLES="subs"
    main.m3u8?VideoCodec=hevc&AudioCodec=copy
    #EXT-X-STREAM-INF:BANDWIDTH=8926092,AVERAGE-BANDWIDTH=8926092,VIDEO-RANGE=SDR,CODECS="avc1.424029,ec-3",RESOLUTION=1920x1038,FRAME-RATE=23.976,SUBTITLES="subs"
    main.m3u8?VideoCodec=h264&AudioCodec=copy&AllowVideoStreamCopy=false
    #EXT-X-IMAGE-STREAM-INF:BANDWIDTH=9681,RESOLUTION=320x172,CODECS="jpeg",URI="Trickplay/320/tiles.m3u8"
    """

    @Test("the master keeps the first variant, the requested subtitle and Dolby Vision when claimed")
    func variantFilter() {
        let filtered = HLSVariantFilter.firstVariantOnly(Self.knivesMaster, keepsDolbyVision: true)
        let lines = filtered.components(separatedBy: "\n")
        #expect(lines.filter { $0.hasPrefix("#EXT-X-STREAM-INF") }.count == 1)
        #expect(lines.contains("main.m3u8?VideoCodec=hevc&AudioCodec=copy"))
        #expect(!filtered.contains("AllowVideoStreamCopy=false"))
        #expect(!filtered.contains("IMAGE-STREAM-INF"))
        #expect(lines.filter { $0.hasPrefix("#EXT-X-MEDIA") }.count == 1)
        #expect(filtered.contains("NAME=\"Spanish"))
        #expect(filtered.contains("SUBTITLES=\"subs\""))
        #expect(filtered.contains("SUPPLEMENTAL-CODECS=\"dvh1.08.10/db1p\""))
    }

    @Test("without a claim the stale Dolby Vision supplemental goes; Off drops the subtitle group")
    func variantFilterWithoutDolbyVisionOrSubtitles() {
        let off = Self.knivesMaster.replacingOccurrences(of: "DEFAULT=YES", with: "DEFAULT=NO")
        let filtered = HLSVariantFilter.firstVariantOnly(off, keepsDolbyVision: false)
        #expect(!filtered.contains("SUPPLEMENTAL-CODECS"))
        #expect(!filtered.contains("#EXT-X-MEDIA"))
        #expect(!filtered.contains("SUBTITLES="))
        #expect(filtered.contains("VIDEO-RANGE=PQ"))

        let hdr10Plus = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L150.B0,ec-3",SUPPLEMENTAL-CODECS="hvc1.2.4.L150.B0/cdm4",RESOLUTION=3840x2160
        main.m3u8?a
        #EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO-RANGE=SDR,CODECS="avc1.424029,ec-3",RESOLUTION=3840x2160
        main.m3u8?b
        """
        let kept = HLSVariantFilter.firstVariantOnly(hdr10Plus, keepsDolbyVision: false)
        #expect(kept.contains("SUPPLEMENTAL-CODECS=\"hvc1.2.4.L150.B0/cdm4\""))
        #expect(!kept.contains("main.m3u8?b"))
    }

    @Test("Dolby Vision 5's three variants come down to the dvh1 one; media playlists pass")
    func profile5AndMediaPlaylists() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO-RANGE=PQ,CODECS="dvh1.05.09",RESOLUTION=3840x2160
        main.m3u8?dv
        #EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L153.B0",RESOLUTION=3840x2160
        main.m3u8?hevc
        #EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO-RANGE=SDR,CODECS="avc1.424029",RESOLUTION=3840x2160
        main.m3u8?sdr
        """
        let filtered = HLSVariantFilter.firstVariantOnly(master, keepsDolbyVision: true)
        #expect(filtered.contains("main.m3u8?dv"))
        #expect(!filtered.contains("main.m3u8?hevc"))
        #expect(!filtered.contains("main.m3u8?sdr"))

        let media = "#EXTM3U\n#EXT-X-MAP:URI=\"hls1/main/-1.mp4\"\n#EXTINF:6.006,\nhls1/main/0.mp4"
        #expect(HLSVariantFilter.firstVariantOnly(media, keepsDolbyVision: false) == media)
    }

    @Test("Plex's traits never filter variants")
    func plexTraitsUntouched() {
        #expect(PlaybackTraits.plex.remuxNeedsVariantFilter == false)
    }

    @Test("log URLs redact Jellyfin's ApiKey and leave Plex's redaction as it was")
    func redaction() {
        let jellyfin = "http://jf/videos/x/master.m3u8?MediaSourceId=1&ApiKey=secret-token&PlaySessionId=2"
        #expect(!PlaybackURLRedaction.redacted(jellyfin).contains("secret-token"))
        let plex = "http://plex/video/:/transcode/universal/start.m3u8?path=%2Flibrary&X-Plex-Token=%3Credacted%3E"
        #expect(PlaybackURLRedaction.redacted(plex) == plex)
    }
}
