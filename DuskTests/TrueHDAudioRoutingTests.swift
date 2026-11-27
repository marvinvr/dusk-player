import Foundation
import Testing
@testable import Dusk

@Suite("TrueHD routing with Dusk's VLCKit build")
@MainActor
struct TrueHDAudioRoutingTests {
    // MARK: - Decodability

    @Test func trueHDIsDecodableOnlyWithDusksBuild() {
        for codec in ["truehd", "TrueHD", "mlp"] {
            #expect(!PlayerViewModel.isLocallyUndecodableAudioCodec(codec, decodesTrueHD: true))
            #expect(PlayerViewModel.isLocallyUndecodableAudioCodec(codec, decodesTrueHD: false))
        }
        for codec in ["eac3", "ac3", "dca", "flac", nil] {
            #expect(!PlayerViewModel.isLocallyUndecodableAudioCodec(codec, decodesTrueHD: false))
        }
    }

    // MARK: - Direct-play preselection

    @Test func preselectionOpensOnTrueHDOnTVOS() throws {
        let part = try makePart(audio: bluRayAudio)
        let position = PlayerViewModel.preferredAudioStreamPosition(
            inPart: part,
            preferredLanguage: nil,
            decodesTrueHD: true
        )
        #if os(tvOS)
        // Lossless ranks top on tvOS: discrete 7.1 PCM over HDMI.
        #expect(position == 0)
        #else
        // iPhone/iPad downmix to stereo either way, so the lossy sibling wins.
        #expect(position == 1)
        #endif
    }

    @Test func stockBuildNeverPreselectsTrueHD() throws {
        let part = try makePart(audio: bluRayAudio)
        let position = PlayerViewModel.preferredAudioStreamPosition(
            inPart: part,
            preferredLanguage: nil,
            decodesTrueHD: false
        )
        #expect(position == 1)
    }

    // MARK: - Startup remux pick

    @Test func remuxDecisionKeepsTheCopyableSibling() throws {
        let part = try makePart(audio: bluRayAudio)
        let stream = PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil)
        #expect(stream?.id == 3)
    }

    @Test func remuxDecisionPrefersEAC3AtmosOverTrueHDAtmos() throws {
        let part = try makePart(audio: """
            { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1 Atmos)" },
            { "id": 3, "streamType": 2, "codec": "eac3", "channels": 8, "languageCode": "eng", "profile": "dolby digital plus + dolby atmos", "displayTitle": "English (EAC3 7.1 Atmos)" }
            """)
        let stream = try #require(PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil))
        #expect(stream.id == 3)
        #expect(StreamResolver.isSpatialAudioCandidate(stream))
    }

    @Test func remuxDecisionFallsBackToTrueHDWhenItIsTheOnlyTrack() throws {
        let part = try makePart(audio: trueHDOnlyAudio)
        let stream = PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil)
        #expect(stream?.id == 2)
        #expect(PlayerViewModel.isTrueHDAudioCodec(stream?.codec))
    }

    @Test func hdrRemuxStillQualifiesForTrueHDPlusAC3() throws {
        let media = try makeMedia(video: #""colorTrc": "smpte2084""#, audio: bluRayAudio)
        let part = media.parts[0]
        let remuxAudio = PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil)
        let blocker = StreamResolver.hdrVideoRemuxBlocker(
            media: media,
            decision: StreamResolver.evaluate(media: media),
            audioStream: remuxAudio,
            subtitleStream: nil,
            displaySupportsHDR: true
        )
        #expect(blocker == nil)
    }

    // MARK: - Converted TrueHD remux gate

    @Test(arguments: [6, 8], ["truehd", "mlp"])
    func dv7TrueHDStartsWithConvertedAudio(channels: Int, codec: String) throws {
        // The HDR10 Atmos demo has 8 channels; the HDR10+ sibling has 6
        // and a forced SRT. HDR10+ is not distinguished in Plex metadata.
        let media = try makeMedia(
            video: dv7Video,
            audio: #"{ "id": 2, "streamType": 2, "codec": "\#(codec)", "channels": \#(channels), "default": true }"#,
            subtitleCodec: channels == 6 ? "srt" : nil
        )
        let streams = media.parts[0].streams
        let decision = StreamResolver.evaluate(media: media)
        let audio = PlayerViewModel.preferredRemuxAudioStream(inPart: media.parts[0], preferredLanguage: nil)
        let subtitle = streams.first { $0.streamType == .subtitle }
        #expect(decision.engine == .vlcKit)
        #expect(!decision.requiresServerTranscode)
        #expect(StreamResolver.hdrVideoRemuxBlocker(
            media: media, decision: decision, audioStream: audio,
            subtitleStream: subtitle, displaySupportsHDR: true
        ) != nil)
        #expect(StreamResolver.spatialAudioRemuxBlocker(
            media: media, decision: decision, audioStream: audio,
            subtitleStream: subtitle, displaySupportsHDR: true
        ) != nil)
        #expect(convertedBlocker(for: media, subtitleID: subtitle?.id) == nil)
        #expect(StreamResolver.spatialAudioRemuxBlocker(
            media: media, decision: decision, audioStream: audio,
            subtitleStream: subtitle, displaySupportsHDR: true, convertsAudio: true
        ) == nil)
        let target = try #require(StreamResolver.dolbyVision7ConversionTarget(in: media))
        #expect(target.profile == 8)
        #expect(target.blSignalCompatibilityID == 1)
        #expect(target.convertedFromProfile == 7)
    }

    @Test func dv7WithCopyableAudioKeepsConversion() throws {
        for audio in [bluRayAudio, #"{ "id": 2, "streamType": 2, "codec": "eac3", "channels": 6 }"#] {
            let media = try makeMedia(video: dv7Video, audio: audio)
            let stream = PlayerViewModel.preferredRemuxAudioStream(inPart: media.parts[0], preferredLanguage: nil)
            #expect(StreamResolver.hdrVideoRemuxBlocker(
                media: media, decision: StreamResolver.evaluate(media: media),
                audioStream: stream, subtitleStream: nil, displaySupportsHDR: true
            ) == nil)
            #expect(StreamResolver.dolbyVision7ConversionTarget(in: media) != nil)
        }
    }

    @Test func dv8TrueHDStartsWithConvertedAudio() throws {
        // Picture first: DV 8.1 keeps Dolby Vision on AVPlayer.
        let media = try makeMedia(
            video: #""DOVIPresent": true, "DOVIProfile": 8, "DOVIBLCompatID": 1, "colorTrc": "smpte2084""#,
            audio: trueHDOnlyAudio
        )
        #expect(convertedBlocker(for: media) == nil)
        #expect(StreamResolver.dolbyVision7ConversionTarget(in: media) == nil)
    }

    @Test func hdrTrueHDOnlyFileStartsWithConvertedAudio() throws {
        let media = try makeMedia(video: #""colorTrc": "smpte2084""#, audio: trueHDOnlyAudio)
        #expect(convertedBlocker(for: media) == nil)
        // Direct play (no HDR display, setting off) still opens on TrueHD.
        #expect(PlayerViewModel.preferredLocalAudioStream(
            inPart: media.parts[0], preferredLanguage: nil, decodesTrueHD: true
        )?.id == 2)
    }

    @Test func hdrGateHonoursDisplayAndSetting() throws {
        let media = try makeMedia(video: dv7Video, audio: trueHDOnlyAudio)
        #expect(convertedBlocker(for: media, displaySupportsHDR: false) != nil)
        #expect(convertedBlocker(for: media, hdrVideoRemuxEnabled: false) != nil)
    }

    @Test func sdrTrueHDOnlyFileDecodesLocally() throws {
        let media = try makeMedia(video: #""colorTrc": "bt709""#, audio: trueHDOnlyAudio)
        #expect(convertedBlocker(for: media) != nil)
    }

    @Test func bitmapSubtitleKeepsTrueHDLocal() throws {
        let media = try makeMedia(
            video: dv7Video,
            audio: trueHDOnlyAudio,
            subtitleCodec: "pgs"
        )
        #expect(convertedBlocker(for: media, subtitleID: 9) != nil)
    }

    @Test func convertedRequestCopiesVideoAndRequiresDDPlus() {
        let service = PlexService()
        let items = service.transcodeQueryItems(
            ratingKey: "1", mediaIndex: 0, sourcePath: nil,
            mode: .spatialAudioRemux(convertsAudio: true),
            sessionIdentifier: "session", transcodeSessionID: "transcode",
            audioStreamID: 2, subtitleStreamID: 9, token: nil
        )
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["directPlay"] == "0")
        #expect(query["directStream"] == "1")
        #expect(query["directStreamAudio"] == "0")
        #expect(query["audioStreamID"] == "2")
        #expect(query["subtitles"] == "auto")
        #expect(query["maxVideoBitrate"] == nil)
        let profile = query["X-Plex-Client-Profile-Extra"] ?? ""
        #expect(profile.contains("container=mp4&videoCodec=hevc,h264&audioCodec=eac3)"))
        #expect(profile.contains("scopeName=eac3&type=upperBound&name=audio.channels&value=8"))
        #expect(!profile.contains("audioCodec=ac3"))
        #expect(!profile.contains("audioCodec=aac"))
        #expect(!profile.contains("container=mpegts"))
    }

    @Test(arguments: [6, 8])
    func convertedDecisionRequiresCompatibleSurround(channels: Int) {
        var decision = PlexService.TranscodeStreamDecisions(
            container: "mp4", videoDecision: "copy", videoCodec: "hevc",
            audioDecision: "transcode", audioCodec: "eac3", audioChannels: channels
        )
        #expect(decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.audioCodec = "truehd"
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.audioCodec = "aac"
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.audioCodec = "eac3"
        decision.audioDecision = "copy"
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.audioDecision = "transcode"
        decision.container = "mpegts"
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.container = "mp4"
        decision.audioChannels = 2
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.audioChannels = channels
        decision.videoDecision = "transcode"
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
    }

    @Test func ignoredSubtitleDoesNotInvalidateVideoCopyRemux() {
        // PMS can retain the previously selected embedded SRT in its Off
        // decision as ignore/embedded. It is not being burned into the video.
        var decision = PlexService.TranscodeStreamDecisions(
            container: "mp4", videoDecision: "copy", videoCodec: "hevc",
            audioDecision: "copy", audioCodec: "eac3",
            subtitleDecision: "ignore", subtitleLocation: "embedded"
        )
        #expect(decision.isLosslessRemux)
        decision.audioDecision = "transcode"
        decision.audioChannels = 6
        #expect(decision.isConvertedAudioRemux(sourceChannels: 6))
        decision.subtitleDecision = "burn"
        #expect(!decision.isVideoCopyRemux)
        decision.subtitleDecision = "transcode"
        #expect(!decision.isVideoCopyRemux)
        decision.subtitleLocation = "segments-subs"
        #expect(decision.isVideoCopyRemux)
    }

    @Test func convertedAudioRestoresOnlyConfirmedJOC() throws {
        var decision = PlexService.TranscodeStreamDecisions(
            container: "mp4", videoDecision: "copy", videoCodec: "hevc",
            audioDecision: "transcode", audioCodec: "eac3", audioChannels: 6
        )
        let media = try makeMedia(video: dv7Video, audio: trueHDOnlyAudio)
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.activeAudioStreamID = 2
        for (profile, expectsAtmos) in [
            (nil, false), ("dolby digital plus", false),
            ("dolby truehd + dolby atmos", false),
            ("dolby digital plus + dolby atmos", true), ("joc", true),
        ] as [(String?, Bool)] {
            decision.audioProfile = profile
            #expect(decision.hasDolbyAtmosAudio == expectsAtmos)
            playback.remuxAudioConversion = RemuxAudioConversion(
                audioStreamID: 2, restoresDolbyAtmos: decision.hasDolbyAtmosAudio
            )
            #expect(playback.activeAudioStreamIsDolbyAtmos(in: media.parts[0]) == expectsAtmos)
        }
    }

    // MARK: - Helpers

    private let dv7Video = #""DOVIPresent": true, "DOVIProfile": 7, "DOVILevel": 6, "DOVIBLCompatID": 6, "colorTrc": "smpte2084""#

    private let bluRayAudio = """
        { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1)" },
        { "id": 3, "streamType": 2, "codec": "ac3", "channels": 6, "languageCode": "eng", "displayTitle": "English (AC3 5.1)" }
        """

    private let trueHDOnlyAudio = """
        { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1 Atmos)" }
        """

    private func convertedBlocker(
        for media: PlexMedia,
        subtitleID: Int? = nil,
        displaySupportsHDR: Bool = true,
        hdrVideoRemuxEnabled: Bool = true
    ) -> String? {
        let streams = media.parts[0].streams
        guard let audio = streams.first(where: { $0.streamType == .audio }) else {
            return "no audio"
        }
        return StreamResolver.hdrAudioConversionRemuxBlocker(
            media: media,
            decision: StreamResolver.evaluate(media: media),
            audioStream: audio,
            subtitleStream: subtitleID.flatMap { id in streams.first { $0.id == id } },
            displaySupportsHDR: displaySupportsHDR,
            hdrVideoRemuxEnabled: hdrVideoRemuxEnabled
        )
    }

    private func makePart(audio: String) throws -> PlexMediaPart {
        try makeMedia(video: #""colorTrc": "bt709""#, audio: audio).parts[0]
    }

    private func makeMedia(
        video: String,
        audio: String,
        subtitleCodec: String? = nil
    ) throws -> PlexMedia {
        let subtitle = subtitleCodec.map { #", { "id": 9, "streamType": 3, "codec": "\#($0)" }"# } ?? ""
        let json = """
        {
            "id": 10,
            "container": "mkv",
            "Part": [{
                "id": 20,
                "key": "/library/parts/20/file.mkv",
                "container": "mkv",
                "Stream": [
                    { "id": 1, "streamType": 1, "codec": "hevc", "bitDepth": 10, "frameRate": 23.976, \(video) },
                    \(audio)\(subtitle)
                ]
            }]
        }
        """
        return try JSONDecoder().decode(PlexMedia.self, from: Data(json.utf8))
    }
}
