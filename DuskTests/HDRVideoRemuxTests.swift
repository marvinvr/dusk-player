import AVFoundation
import Foundation
import Testing
@testable import Dusk

@Suite("HDR / Dolby Vision remux routing")
struct HDRVideoRemuxRoutingTests {
    @Test func hdr10MKVWithCopyableAudioQualifies() throws {
        let media = try makeMedia(video: #""colorTrc": "smpte2084""#)
        #expect(blocker(for: media) == nil)
        #expect(StreamResolver.hdrVideoLabel(for: media) == "HDR10")
    }

    @Test func sdrDisplayKeepsVLCKit() throws {
        let media = try makeMedia(video: #""colorTrc": "smpte2084""#)
        #expect(blocker(for: media, displaySupportsHDR: false) != nil)
    }

    @Test func dtsCannotRideTheCopyRemux() throws {
        // The copy gate refuses DTS; picture first converts it instead
        // (`HDRPictureFirstRoutingTests`).
        let media = try makeMedia(video: #""colorTrc": "smpte2084""#, audioCodec: "dca")
        #expect(blocker(for: media)?.contains("conversion") == true)
    }

    @Test func bitmapSubtitleKeepsVLCKit() throws {
        let media = try makeMedia(video: #""colorTrc": "smpte2084""#, subtitleCodec: "pgs")
        #expect(blocker(for: media, subtitleID: "3")?.contains("subtitle") == true)
    }

    @Test func tenBitSDRIsNotHDR() throws {
        let media = try makeMedia(video: #""colorTrc": "bt709", "bitDepth": 10"#)
        #expect(blocker(for: media) == "video is not HDR")
    }

    @Test func avPlayerCompatibleFileNeedsNoRemux() throws {
        let media = try makeMedia(container: "mp4", video: #""colorTrc": "smpte2084""#)
        #expect(blocker(for: media) == "not a VLCKit direct-play file")
    }

    @Test func hlgQualifies() throws {
        let media = try makeMedia(video: #""colorTrc": "arib-std-b67""#)
        #expect(blocker(for: media) == nil)
        #expect(StreamResolver.hdrVideoLabel(for: media) == "HLG")
    }

    @Test func dolbyVisionProfile8IsSignalled() throws {
        let media = try makeMedia(video: dolbyVision(profile: 8, compat: 1, trc: nil))
        #expect(blocker(for: media) == nil)
        #expect(StreamResolver.dolbyVisionSignalingStream(in: media, includesProfile8: true) != nil)
        #expect(StreamResolver.dolbyVisionSignalingStream(in: media, includesProfile8: false) == nil)
        #expect(StreamResolver.hdrVideoLabel(for: media) == "Dolby Vision 8.1")
    }

    @Test func dolbyVisionProfile84UsesHLGBase() throws {
        let stream = try makeMedia(video: dolbyVision(profile: 8, compat: 4, trc: nil)).parts[0].streams[0]
        #expect(StreamResolver.hdrTransfer(of: stream) == .hlg)
        let configuration = try #require(DolbyVisionConfiguration(stream: stream))
        #expect(configuration.supplementalCodecString == "dvh1.08.06/db4h")
        #expect(configuration.hasHLGBaseLayer)
    }

    @Test func dolbyVisionProfile7PlaysItsHDR10Base() throws {
        let media = try makeMedia(video: dolbyVision(profile: 7, compat: 6, trc: "smpte2084"))
        #expect(blocker(for: media) == nil)
        #expect(StreamResolver.dolbyVisionSignalingStream(in: media, includesProfile8: true) == nil)
        #expect(StreamResolver.hdrVideoLabel(for: media) == "Dolby Vision 7 (HDR10 base layer)")
    }

    @Test func dolbyVisionProfile5KeepsItsOwnPath() throws {
        let media = try makeMedia(video: dolbyVision(profile: 5, compat: 0, trc: nil))
        #expect(!StreamResolver.isRemuxableHDRVideo(media.parts[0].streams[0]))
        #expect(StreamResolver.dolbyVisionSignalingStream(in: media, includesProfile8: false) != nil)
    }

    @Test func dolbyVisionProfile82HasNoHDRBase() throws {
        let media = try makeMedia(video: dolbyVision(profile: 8, compat: 2, trc: "bt709"))
        #expect(blocker(for: media) == "video is not HDR")
        #expect(StreamResolver.dolbyVisionSignalingStream(in: media, includesProfile8: true) == nil)
    }

    // MARK: - Helpers

    private func blocker(
        for media: MediaVersion,
        subtitleID: String? = nil,
        displaySupportsHDR: Bool = true
    ) -> String? {
        let streams = media.parts[0].streams
        return StreamResolver.hdrVideoRemuxBlocker(
            media: media,
            decision: StreamResolver.evaluate(media: media),
            audioStream: streams.first { $0.kind == .audio },
            subtitleStream: subtitleID.flatMap { id in streams.first { $0.id == id } },
            displaySupportsHDR: displaySupportsHDR
        )
    }

    private func dolbyVision(profile: Int, compat: Int, trc: String?) -> String {
        var fields = #""DOVIPresent": true, "DOVIProfile": \#(profile), "DOVILevel": 6, "DOVIBLCompatID": \#(compat)"#
        if let trc {
            fields += #", "colorTrc": "\#(trc)""#
        }
        return fields
    }
}

/// Startup routing matrix for "picture first": every HDR/DV source keeps its
/// picture on AVPlayer, Plex converting only TrueHD/DTS audio to E-AC-3;
/// SDR keeps local TrueHD/DTS decoding on VLCKit. `route` composes the
/// resolver gates in the order `requestSpatialAudioRemux` applies them
/// (spatial-audio preference off, HDR setting on, HDR display).
@Suite("HDR picture-first routing")
struct HDRPictureFirstRoutingTests {
    enum Route: Equatable {
        case avPlayerDirect
        case vlcKitDirect
        case copyRemux
        case convertedAudioRemux
    }

    enum Video: String, CaseIterable {
        case sdr, hdr10, hlg, dv5, dv81, dv84, dv7

        var json: String {
            switch self {
            case .sdr: #""colorTrc": "bt709""#
            case .hdr10: #""colorTrc": "smpte2084""#
            case .hlg: #""colorTrc": "arib-std-b67""#
            case .dv5: #""DOVIPresent": true, "DOVIProfile": 5, "DOVILevel": 6, "DOVIBLCompatID": 0"#
            case .dv81: #""DOVIPresent": true, "DOVIProfile": 8, "DOVILevel": 6, "DOVIBLCompatID": 1, "colorTrc": "smpte2084""#
            case .dv84: #""DOVIPresent": true, "DOVIProfile": 8, "DOVILevel": 6, "DOVIBLCompatID": 4, "colorTrc": "arib-std-b67""#
            case .dv7: #""DOVIPresent": true, "DOVIProfile": 7, "DOVILevel": 6, "DOVIBLCompatID": 6, "colorTrc": "smpte2084""#
            }
        }
    }

    enum Audio: String, CaseIterable {
        case aac, eac3, trueHD, mlp, dts, dtsHDMA, dtsX

        var json: String {
            switch self {
            case .aac: #""codec": "aac", "channels": 2"#
            case .eac3: #""codec": "eac3", "channels": 6"#
            case .trueHD: #""codec": "truehd", "channels": 8, "displayTitle": "English (TrueHD 7.1 Atmos)""#
            case .mlp: #""codec": "mlp", "channels": 6"#
            case .dts: #""codec": "dca", "channels": 6, "displayTitle": "English (DTS 5.1)""#
            case .dtsHDMA: #""codec": "dca", "profile": "ma", "channels": 6, "displayTitle": "English (DTS-HD MA 5.1)""#
            case .dtsX: #""codec": "dca", "profile": "dts:x", "channels": 8, "displayTitle": "English (DTS:X 7.1)""#
            }
        }

        var isCopyable: Bool { self == .aac || self == .eac3 }
    }

    @Test(arguments: Video.allCases, Audio.allCases)
    func matrix(video: Video, audio: Audio) throws {
        let media = try makeMatrixMedia(video: video.json, audio: audio.json)
        let expected: Route = switch (video, audio.isCopyable) {
        case (.sdr, _): .vlcKitDirect
        case (_, true): .copyRemux
        case (_, false): .convertedAudioRemux
        }
        #expect(route(for: media) == expected, "\(video.rawValue) × \(audio.rawValue)")
    }

    @Test(arguments: [Video.hdr10, .dv81, .dv7], [Audio.trueHD, .dts, .dtsHDMA])
    func sdrDisplayOrSettingOffKeepsVLCKit(video: Video, audio: Audio) throws {
        let media = try makeMatrixMedia(video: video.json, audio: audio.json)
        #expect(route(for: media, displaySupportsHDR: false) == .vlcKitDirect)
        #expect(route(for: media, hdrVideoRemuxEnabled: false) == .vlcKitDirect)
    }

    @Test(arguments: [Audio.trueHD, .dtsHDMA])
    func bitmapSubtitleStillVetoesTheRemux(audio: Audio) throws {
        // Subtitle routing is unchanged: a PGS pick at startup keeps VLCKit.
        let media = try makeMatrixMedia(video: Video.dv81.json, audio: audio.json, subtitleCodec: "pgs")
        #expect(route(for: media, subtitleID: "3") == .vlcKitDirect)
        let text = try makeMatrixMedia(video: Video.dv81.json, audio: audio.json, subtitleCodec: "srt")
        #expect(route(for: text, subtitleID: "3") == .convertedAudioRemux)
    }

    @Test func mp4HDRWithAACStaysDirectOnAVPlayer() throws {
        let media = try makeMatrixMedia(container: "mp4", video: Video.hdr10.json, audio: Audio.aac.json)
        #expect(route(for: media) == .avPlayerDirect)
    }

    @Test func otherLocalOnlyAudioOnHDRKeepsVLCKit() throws {
        // Scope of the product decision: TrueHD and DTS only.
        for codec in ["flac", "pcm", "opus"] {
            let media = try makeMatrixMedia(video: Video.hdr10.json, audio: #""codec": "\#(codec)", "channels": 6"#)
            #expect(route(for: media) == .vlcKitDirect, "\(codec)")
        }
    }

    @Test func dtsSpellingsAreConverted() throws {
        func stream(_ codec: String) throws -> MediaStream {
            try JSONDecoder().decode(
                MediaStream.self,
                from: Data(#"{ "id": 2, "streamType": 2, "codec": "\#(codec)" }"#.utf8)
            )
        }
        for codec in ["dca", "DCA", "dts", "dts-hd", "dca-ma", "truehd", "mlp"] {
            #expect(StreamResolver.convertsForHDRPicture(audio: try stream(codec)), "\(codec)")
        }
        for codec in ["eac3", "ac3", "aac", "flac", "opus"] {
            #expect(!StreamResolver.convertsForHDRPicture(audio: try stream(codec)), "\(codec)")
        }
    }

    // MARK: - Helpers

    private func route(
        for media: MediaVersion,
        subtitleID: String? = nil,
        displaySupportsHDR: Bool = true,
        hdrVideoRemuxEnabled: Bool = true
    ) -> Route {
        let streams = media.parts[0].streams
        let audio = streams.first { $0.kind == .audio }
        let subtitle = subtitleID.flatMap { id in streams.first { $0.id == id } }
        let decision = StreamResolver.evaluate(media: media)
        if StreamResolver.isDolbyVisionProfile5(media) {
            guard StreamResolver.dolbyVisionRemuxBlocker(
                media: media, subtitleStream: subtitle, displaySupportsHDR: displaySupportsHDR
            ) == nil else { return .vlcKitDirect }
            return audio.map(StreamResolver.canCopyIntoRemux(audio:)) == false ? .convertedAudioRemux : .copyRemux
        }
        if decision.engine == .avPlayer, !decision.requiresServerTranscode { return .avPlayerDirect }
        let convertsAudio = audio.map {
            StreamResolver.hdrAudioConversionRemuxBlocker(
                media: media, decision: decision, audioStream: $0, subtitleStream: subtitle,
                displaySupportsHDR: displaySupportsHDR, hdrVideoRemuxEnabled: hdrVideoRemuxEnabled
            ) == nil
        } ?? false
        if convertsAudio {
            // The coordinator admits a converting request through this gate.
            let admitted = StreamResolver.spatialAudioRemuxBlocker(
                media: media, decision: decision, audioStream: audio, subtitleStream: subtitle,
                displaySupportsHDR: displaySupportsHDR, convertsAudio: true
            ) == nil
            return admitted ? .convertedAudioRemux : .vlcKitDirect
        }
        guard hdrVideoRemuxEnabled else { return .vlcKitDirect }
        return StreamResolver.hdrVideoRemuxBlocker(
            media: media, decision: decision, audioStream: audio, subtitleStream: subtitle,
            displaySupportsHDR: displaySupportsHDR
        ) == nil ? .copyRemux : .vlcKitDirect
    }

    private func makeMatrixMedia(
        container: String = "mkv",
        video: String,
        audio: String,
        subtitleCodec: String? = nil
    ) throws -> MediaVersion {
        let subtitle = subtitleCodec.map { #", { "id": 3, "streamType": 3, "codec": "\#($0)" }"# } ?? ""
        let json = """
        {
            "id": 10,
            "container": "\(container)",
            "Part": [{
                "id": 20,
                "key": "/library/parts/20/file.\(container)",
                "container": "\(container)",
                "Stream": [
                    { "id": 1, "streamType": 1, "codec": "hevc", "bitDepth": 10, "frameRate": 23.976, \(video) },
                    { "id": 2, "streamType": 2, "languageCode": "eng", "default": true, \(audio) }\(subtitle)
                ]
            }]
        }
        """
        return try JSONDecoder().decode(MediaVersion.self, from: Data(json.utf8))
    }
}

/// Plex's fMP4 remux masters carry no `CODECS`; Dusk rebuilds it from the
/// metadata so Dolby Vision can be declared at playlist level.
@Suite("Remux variant CODECS from Plex metadata")
@MainActor
struct RemuxVariantCodecsTests {
    /// The line PMS serves for a 4K Dolby Vision remux (plex-demo, 2026-11).
    private let plexLine = "#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=64473000,RESOLUTION=3840x2160,FRAME-RATE=23.976000,VIDEO-RANGE=PQ"

    @Test(arguments: [
        (#""profile": "main 10", "level": 153"#, "hvc1.2.4.L153.b0"),
        (#""profile": "main 10", "level": 156, "codecID": "dvhe""#, "hev1.2.4.L156.b0"),
        (#""profile": "main 10", "level": 150, "codecID": "hvc1""#, "hvc1.2.4.L150.b0"),
        (#""profile": "main", "level": 120, "bitDepth": 8"#, "hvc1.1.6.L120.b0"),
        // No level: the lowest that fits 4K24 is 5.0, 4K60 needs 5.1.
        (#""profile": "main 10""#, "hvc1.2.4.L150.b0"),
        (#""profile": "main 10", "frameRate": 60.0"#, "hvc1.2.4.L153.b0"),
        (#""level": 153, "bitDepth": 10"#, "hvc1.2.4.L153.b0"),
    ])
    func hevcCodecFromMetadata(fields: String, expected: String) throws {
        #expect(RemuxVariantCodecs.hevcCodec(for: try video(fields)) == expected)
    }

    @Test func unsupportedVideoGetsNoCodecs() throws {
        #expect(RemuxVariantCodecs.hevcCodec(for: try video(#""profile": "rext", "level": 153"#)) == nil)
        #expect(RemuxVariantCodecs.hevcCodec(for: try video(#""profile": "high""#, codec: "h264")) == nil)
    }

    @Test func audioCodecStrings() throws {
        let stream = try video(#""profile": "main 10", "level": 153"#)
        #expect(RemuxVariantCodecs.codecs(video: stream, audioCodec: "eac3", hasAudio: true) == "hvc1.2.4.L153.b0,ec-3")
        #expect(RemuxVariantCodecs.codecs(video: stream, audioCodec: "AC3", hasAudio: true) == "hvc1.2.4.L153.b0,ac-3")
        #expect(RemuxVariantCodecs.codecs(video: stream, audioCodec: "aac", hasAudio: true) == "hvc1.2.4.L153.b0,mp4a.40.2")
        #expect(RemuxVariantCodecs.codecs(video: stream, audioCodec: nil, hasAudio: false) == "hvc1.2.4.L153.b0")
        // A partial declaration would hide the audio: none at all instead.
        #expect(RemuxVariantCodecs.codecs(video: stream, audioCodec: "truehd", hasAudio: true) == nil)
        #expect(RemuxVariantCodecs.codecs(video: stream, audioCodec: nil, hasAudio: true) == nil)
    }

    @Test func profile81IsDeclaredOnPlexsLine() throws {
        let line = DolbyVisionSignaling.rewrittenStreamInfLine(
            plexLine, configuration: try configuration(profile: 8, compat: 1),
            fallbackCodecs: "hvc1.2.4.L153.b0,ec-3"
        )
        #expect(line.contains(#"CODECS="hvc1.2.4.L153.b0,ec-3""#))
        #expect(line.contains(#"SUPPLEMENTAL-CODECS="dvh1.08.06/db1p""#))
        #expect(line.contains("VIDEO-RANGE=PQ"))
        #expect(line.components(separatedBy: "VIDEO-RANGE").count == 2)
    }

    @Test func profile84IsDeclaredHLG() throws {
        let line = DolbyVisionSignaling.rewrittenStreamInfLine(
            plexLine, configuration: try configuration(profile: 8, compat: 4),
            fallbackCodecs: "hvc1.2.4.L153.b0,ec-3"
        )
        #expect(line.contains(#"SUPPLEMENTAL-CODECS="dvh1.08.06/db4h""#))
        #expect(line.contains("VIDEO-RANGE=HLG"))
        #expect(!line.contains("VIDEO-RANGE=PQ"))
    }

    @Test func profile5ReplacesTheFallbackHEVCEntry() throws {
        let line = DolbyVisionSignaling.rewrittenStreamInfLine(
            plexLine, configuration: try configuration(profile: 5, compat: 0),
            fallbackCodecs: "hvc1.2.4.L153.b0,ec-3"
        )
        #expect(line.contains(#"CODECS="dvh1.05.06,ec-3""#))
        #expect(!line.contains("SUPPLEMENTAL-CODECS"))
    }

    @Test func plexsOwnCodecsWin() throws {
        let line = plexLine + #",CODECS="hvc1.2.4.L150.b0,ac-3""#
        let rewritten = DolbyVisionSignaling.rewrittenStreamInfLine(
            line, configuration: try configuration(profile: 8, compat: 1),
            fallbackCodecs: "hvc1.2.4.L156.b0,ec-3"
        )
        #expect(rewritten.contains(#"CODECS="hvc1.2.4.L150.b0,ac-3""#))
    }

    @Test func withoutFallbackTheLineIsUnchanged() throws {
        #expect(DolbyVisionSignaling.rewrittenStreamInfLine(
            plexLine, configuration: try configuration(profile: 8, compat: 1)
        ) == plexLine)
    }

    @Test func remuxLoaderDeclaresProfile81() throws {
        let loader = RemuxHLSLoader(
            restoresDolbyAtmos: false,
            dolbyVision: try configuration(profile: 8, compat: 1),
            fallbackCodecs: "hvc1.2.4.L153.b0,ec-3"
        )
        let master = plexLine + "\nsession/abc/base/index.m3u8\n"
        let rewritten = loader.rewrittenPlaylist(master, baseURL: URL(string: "https://plex.test:32400/video/:/transcode/universal/start.m3u8")!)
        #expect(rewritten.contains(#"SUPPLEMENTAL-CODECS="dvh1.08.06/db1p""#))
        #expect(rewritten.contains("dusk-remux-https://plex.test:32400/video/:/transcode/universal/session/abc/base/index.m3u8"))
    }

    @Test func coordinatorDeclaresTheRemuxAudio() throws {
        let part = try JSONDecoder().decode(MediaPart.self, from: Data("""
        { "id": 20, "key": "/library/parts/20/file.mkv", "Stream": [
            { "id": 1, "streamType": 1, "codec": "hevc", "profile": "main 10", "level": 153 },
            { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "selected": true },
            { "id": 3, "streamType": 2, "codec": "ac3", "channels": 6 }
        ] }
        """.utf8))
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.activeAudioStreamID = "2"
        playback.remuxAudioConversion = RemuxAudioConversion(audioStreamID: "2")
        #expect(playback.remuxVariantCodecs(in: part) == "hvc1.2.4.L153.b0,ec-3")
        playback.remuxAudioConversion = nil
        playback.activeAudioStreamID = "3"
        #expect(playback.remuxVariantCodecs(in: part) == "hvc1.2.4.L153.b0,ac-3")
        // A copied TrueHD stream is not a remux Plex accepts; no declaration.
        playback.activeAudioStreamID = "2"
        #expect(playback.remuxVariantCodecs(in: part) == nil)
    }

    private func video(_ fields: String, codec: String = "hevc") throws -> MediaStream {
        let frameRate = fields.contains("frameRate") ? "" : #""frameRate": 23.976, "#
        return try JSONDecoder().decode(MediaStream.self, from: Data("""
        { "id": 1, "streamType": 1, "codec": "\(codec)", "width": 3840, "height": 2160, \(frameRate)\(fields) }
        """.utf8))
    }

    private func configuration(profile: Int, compat: Int) throws -> DolbyVisionConfiguration {
        let stream = try JSONDecoder().decode(MediaStream.self, from: Data("""
        { "id": 1, "streamType": 1, "codec": "hevc", "DOVIPresent": true, "DOVIProfile": \(profile),
          "DOVILevel": 6, "DOVIBLCompatID": \(compat), "width": 3840, "height": 2160,
          "frameRate": 23.976, "bitrate": 20000 }
        """.utf8))
        return try #require(DolbyVisionConfiguration(stream: stream))
    }
}

@Suite("Dolby Vision HLS signaling")
struct DolbyVisionSignalingTests {
    private let streamInf = #"#EXT-X-STREAM-INF:BANDWIDTH=60000000,CODECS="hvc1.2.4.L156.b0,ec-3",RESOLUTION=3840x2160,VIDEO-RANGE=PQ"#

    @Test func profile81KeepsHEVCAndAddsSupplementalCodecs() throws {
        let configuration = try makeConfiguration(profile: 8, compat: 1)
        let line = DolbyVisionSignaling.rewrittenStreamInfLine(streamInf, configuration: configuration)
        #expect(line.contains(#"CODECS="hvc1.2.4.L153.b0,ec-3""#))
        #expect(line.contains(#"SUPPLEMENTAL-CODECS="dvh1.08.06/db1p""#))
        #expect(line.contains("VIDEO-RANGE=PQ"))
    }

    @Test func profile84DeclaresHLG() throws {
        let configuration = try makeConfiguration(profile: 8, compat: 4)
        let line = DolbyVisionSignaling.rewrittenStreamInfLine(streamInf, configuration: configuration)
        #expect(line.contains(#"SUPPLEMENTAL-CODECS="dvh1.08.06/db4h""#))
        #expect(line.contains("VIDEO-RANGE=HLG"))
        #expect(!line.contains("VIDEO-RANGE=PQ"))
    }

    @Test func profile5ReplacesTheHEVCCodec() throws {
        let configuration = try makeConfiguration(profile: 5, compat: 0)
        let line = DolbyVisionSignaling.rewrittenStreamInfLine(streamInf, configuration: configuration)
        #expect(line.contains(#"CODECS="dvh1.05.06,ec-3""#))
        #expect(!line.contains("SUPPLEMENTAL-CODECS"))
    }

    @Test func existingDolbyVisionSupplementalIsReplacedOthersKept() throws {
        let configuration = try makeConfiguration(profile: 8, compat: 1)
        let input = streamInf + #",SUPPLEMENTAL-CODECS="dvh1.08.07/db1p,hvc1.2.4.L150.b0/cdm4""#
        let line = DolbyVisionSignaling.rewrittenStreamInfLine(input, configuration: configuration)
        #expect(line.contains(#"SUPPLEMENTAL-CODECS="dvh1.08.06/db1p,hvc1.2.4.L150.b0/cdm4""#))
        #expect(line.components(separatedBy: "SUPPLEMENTAL-CODECS").count == 2)
    }

    @Test func supplementalCodecsBeforeCodecsIsParsedByName() throws {
        let configuration = try makeConfiguration(profile: 8, compat: 1)
        let input = #"#EXT-X-STREAM-INF:SUPPLEMENTAL-CODECS="hvc1.2.4.L150.b0/cdm4",BANDWIDTH=1,CODECS="hvc1.2.4.L150.b0,ec-3""#
        let line = DolbyVisionSignaling.rewrittenStreamInfLine(input, configuration: configuration)
        #expect(line == #"#EXT-X-STREAM-INF:SUPPLEMENTAL-CODECS="dvh1.08.06/db1p,hvc1.2.4.L150.b0/cdm4",BANDWIDTH=1,CODECS="hvc1.2.4.L150.b0,ec-3",VIDEO-RANGE=PQ"#)
    }

    @Test func profile81SetsPQWhenRangeIsMissingOrWrong() throws {
        let configuration = try makeConfiguration(profile: 8, compat: 1)
        let missing = #"#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="hvc1.2.4.L150.b0""#
        #expect(DolbyVisionSignaling.rewrittenStreamInfLine(missing, configuration: configuration).hasSuffix(",VIDEO-RANGE=PQ"))
        let wrong = #"#EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO-RANGE=SDR,CODECS="hvc1.2.4.L150.b0""#
        let line = DolbyVisionSignaling.rewrittenStreamInfLine(wrong, configuration: configuration)
        #expect(line.contains("VIDEO-RANGE=PQ"))
        #expect(!line.contains("SDR"))
    }

    @Test func profile8OnHev1IsLeftAlone() throws {
        let configuration = try makeConfiguration(profile: 8, compat: 1)
        let input = #"#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="hev1.2.4.L150.b0,ec-3",VIDEO-RANGE=PQ"#
        #expect(DolbyVisionSignaling.rewrittenStreamInfLine(input, configuration: configuration) == input)
        let original = initSegment(entryType: "hev1")
        #expect(DolbyVisionSignaling.patchedInitSegment(Data(original), configuration: configuration) == nil)
    }

    @Test func profile5OnHev1BecomesDvheInBothPlaces() throws {
        let configuration = try makeConfiguration(profile: 5, compat: 0)
        let input = #"#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="hev1.2.4.L153.b0,ec-3",VIDEO-RANGE=PQ"#
        #expect(DolbyVisionSignaling.rewrittenStreamInfLine(input, configuration: configuration).contains(#"CODECS="dvhe.05.06,ec-3""#))
        let patched = try #require(DolbyVisionSignaling.patchedInitSegment(Data(initSegment(entryType: "hev1")), configuration: configuration))
        #expect(try sampleEntry(in: [UInt8](patched)).type == "dvhe")
    }

    @Test func malformedLineIsLeftAlone() throws {
        let configuration = try makeConfiguration(profile: 8, compat: 1)
        let input = #"#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="hvc1.2.4.L150.b0"#
        #expect(DolbyVisionSignaling.rewrittenStreamInfLine(input, configuration: configuration) == input)
    }

    @Test func levelCapOnlyWhenContentFitsLevel51() throws {
        let fits = try makeConfiguration(profile: 8, compat: 1)
        #expect(DolbyVisionSignaling.cappingHEVCLevel("hvc1.2.4.L156.b0", configuration: fits) == "hvc1.2.4.L153.b0")
        #expect(DolbyVisionSignaling.cappingHEVCLevel("hvc1.2.4.L150.b0", configuration: fits) == "hvc1.2.4.L150.b0")
        #expect(DolbyVisionSignaling.cappingHEVCLevel("hvc1", configuration: fits) == "hvc1")

        // 4K120 genuinely needs 5.2.
        let fast = try makeConfiguration(profile: 8, compat: 1, frameRate: 119.88)
        #expect(DolbyVisionSignaling.cappingHEVCLevel("hvc1.2.4.L156.b0", configuration: fast) == "hvc1.2.4.L156.b0")

        // 50 Mbit/s exceeds Main tier 5.1 (40) but not High tier 5.1 (160).
        let heavy = try makeConfiguration(profile: 8, compat: 1, bitrate: 50_000)
        #expect(DolbyVisionSignaling.cappingHEVCLevel("hvc1.2.4.L156.b0", configuration: heavy) == "hvc1.2.4.L156.b0")
        #expect(DolbyVisionSignaling.cappingHEVCLevel("hvc1.2.4.H186.90", configuration: heavy) == "hvc1.2.4.H153.90")

        // Unknown bitrate: cannot prove it fits, so the declaration stays.
        let unknown = try makeConfiguration(profile: 8, compat: 1, bitrate: nil)
        #expect(DolbyVisionSignaling.cappingHEVCLevel("hvc1.2.4.L156.b0", configuration: unknown) == "hvc1.2.4.L156.b0")
    }

    @Test func profile81InitSegmentKeepsHvc1AndGainsDvvC() throws {
        let configuration = try makeConfiguration(profile: 8, compat: 1)
        let patched = try #require(DolbyVisionSignaling.patchedInitSegment(Data(initSegment()), configuration: configuration))
        let entry = try sampleEntry(in: [UInt8](patched))
        #expect(entry.type == "hvc1")
        #expect(entry.children == ["hvcC", "dvvC"])
        // profile 8, level 6, rpu + bl present; compatibility ID 1.
        #expect(Array(entry.configurationPayload.prefix(5)) == [1, 0, 0x10, 0x35, 0x10])
    }

    @Test func profile5InitSegmentIsRelabelled() throws {
        let configuration = try makeConfiguration(profile: 5, compat: 0)
        let patched = try #require(DolbyVisionSignaling.patchedInitSegment(Data(initSegment()), configuration: configuration))
        let entry = try sampleEntry(in: [UInt8](patched))
        #expect(entry.type == "dvh1")
        #expect(entry.children == ["hvcC", "dvcC"])
    }

    @Test func alreadySignalledProfile8InitIsLeftAlone() throws {
        let configuration = try makeConfiguration(profile: 8, compat: 1)
        let original = initSegment(extraChild: box("dvvC", [UInt8](repeating: 0, count: 24)))
        #expect(DolbyVisionSignaling.patchedInitSegment(Data(original), configuration: configuration) == nil)
    }

    // MARK: - Helpers

    private func makeConfiguration(
        profile: Int,
        compat: Int,
        frameRate: Double = 23.976,
        bitrate: Int? = 20_000
    ) throws -> DolbyVisionConfiguration {
        let bitrateField = bitrate.map { #", "bitrate": \#($0)"# } ?? ""
        let json = """
        { "id": 1, "streamType": 1, "codec": "hevc", "DOVIPresent": true,
          "DOVIProfile": \(profile), "DOVILevel": 6, "DOVIBLCompatID": \(compat),
          "width": 3840, "height": 2160, "frameRate": \(frameRate)\(bitrateField) }
        """
        let stream = try JSONDecoder().decode(MediaStream.self, from: Data(json.utf8))
        return try #require(DolbyVisionConfiguration(stream: stream))
    }

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + payload.count)
        return [UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)]
            + Array(type.utf8) + payload
    }

    /// ftyp + moov/trak/mdia/minf/stbl/stsd/hvc1(hvcC), as Plex's muxer
    /// writes the video track of a remux init segment.
    private func initSegment(entryType: String = "hvc1", extraChild: [UInt8] = []) -> [UInt8] {
        let hvc1 = box(entryType, [UInt8](repeating: 0, count: 78) + box("hvcC", [1, 2, 3, 4]) + extraChild)
        let stsd = box("stsd", [0, 0, 0, 0, 0, 0, 0, 1] + hvc1)
        let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd)))))
        return box("ftyp", Array("isom".utf8) + [0, 0, 0, 0]) + moov
    }

    private struct SampleEntry {
        let type: String
        let children: [String]
        let configurationPayload: [UInt8]
    }

    /// Walks the fixed test layout down to the stsd's single sample entry.
    private func sampleEntry(in bytes: [UInt8]) throws -> SampleEntry {
        func size(at offset: Int) -> Int {
            Int(MP4BoxRewriter.readUInt32(bytes, at: offset))
        }
        var offset = size(at: 0) + 8   // past ftyp, into moov
        for _ in 0..<5 { offset += 8 }  // trak, mdia, minf, stbl, stsd headers
        offset += 8                     // stsd full-box header + entry count
        let entrySize = size(at: offset)
        let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
        let childrenBytes = Array(bytes[(offset + 86)..<(offset + entrySize)])
        let children = try #require(MP4BoxRewriter.childTypes(childrenBytes))
        let hvcCSize = Int(MP4BoxRewriter.readUInt32(childrenBytes, at: 0))
        let configurationPayload = Array(childrenBytes[(hvcCSize + 8)...])
        return SampleEntry(type: type, children: children, configurationPayload: configurationPayload)
    }
}

private func makeMedia(
    container: String = "mkv",
    video: String,
    audioCodec: String = "eac3",
    subtitleCodec: String? = nil
) throws -> MediaVersion {
    let subtitle = subtitleCodec.map { #", { "id": 3, "streamType": 3, "codec": "\#($0)" }"# } ?? ""
    let json = """
    {
        "id": 10,
        "container": "\(container)",
        "Part": [{
            "id": 20,
            "key": "/library/parts/20/file.\(container)",
            "container": "\(container)",
            "Stream": [
                { "id": 1, "streamType": 1, "codec": "hevc", "bitDepth": 10, "frameRate": 23.976, \(video) },
                { "id": 2, "streamType": 2, "codec": "\(audioCodec)", "channels": 6 }\(subtitle)
            ]
        }]
    }
    """
    return try JSONDecoder().decode(MediaVersion.self, from: Data(json.utf8))
}

@Suite("HLS media playlist fallback after a display refusal")
struct HLSMediaPlaylistFallbackTests {
    private let masterURL = URL(string: "https://plex.example:32400/video/:/transcode/universal/start.m3u8?X-Plex-Token=tok")!

    @Test func resolvesTheFirstVariantAgainstTheMaster() {
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-STREAM-INF:BANDWIDTH=40000000,CODECS="hvc1.2.4.L153.b0,ec-3",RESOLUTION=3840x2160,SUPPLEMENTAL-CODECS="dvh1.08.06/db1p",VIDEO-RANGE=PQ
        session/abc/base/index.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,URI="iframes.m3u8"

        """
        let url = HLSMediaPlaylistFallback.mediaPlaylistURL(inMaster: master, baseURL: masterURL)
        #expect(url?.absoluteString == "https://plex.example:32400/video/:/transcode/universal/session/abc/base/index.m3u8")
        let crlf = master.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(HLSMediaPlaylistFallback.mediaPlaylistURL(inMaster: crlf, baseURL: masterURL) == url)
    }

    @Test func keepsTheLadderWhenARenditionWouldBeLost() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="session/abc/subs/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="hvc1.2.4.L153.b0,ec-3",SUBTITLES="subs",VIDEO-RANGE=PQ
        session/abc/base/index.m3u8
        """
        #expect(HLSMediaPlaylistFallback.mediaPlaylistURL(inMaster: master, baseURL: masterURL) == nil)
    }

    @Test func rejectsMediaPlaylistsAndGarbage() {
        let media = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\nseg0.m4s\n"
        #expect(HLSMediaPlaylistFallback.mediaPlaylistURL(inMaster: media, baseURL: masterURL) == nil)
        #expect(HLSMediaPlaylistFallback.mediaPlaylistURL(inMaster: "<html>", baseURL: masterURL) == nil)
    }

    @Test func onlyTheDisplayRefusalQualifies() {
        #expect(HLSMediaPlaylistFallback.isDisplayRefusal(NSError(domain: AVFoundationErrorDomain, code: -11868)))
        #expect(!HLSMediaPlaylistFallback.isDisplayRefusal(NSError(domain: AVFoundationErrorDomain, code: -11800)))
        #expect(!HLSMediaPlaylistFallback.isDisplayRefusal(NSError(domain: "CoreMediaErrorDomain", code: -11868)))
        #expect(!HLSMediaPlaylistFallback.isDisplayRefusal(nil))
    }
}
