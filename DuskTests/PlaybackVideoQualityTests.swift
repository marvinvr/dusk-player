import AVFoundation
import Foundation
import Testing
@testable import Dusk

@Suite("Currently playing video quality")
struct PlaybackVideoQualityTests {
    @Test func vlcDemuxRateConvertsARealReading() {
        // 0.5 bytes per microsecond is 4 Mbps.
        #expect(PlaybackVideoQuality.bitsPerSecond(fromVLCDemuxRate: 0.5) == 4_000_000)
    }

    /// These reach `Int()` otherwise, which traps. 0x6F123456 is the low half of
    /// an arm64 stack address read as a float, the kind of value left behind when
    /// `-[VLCMedia statistics]` returns uninitialized memory.
    @Test(arguments: [
        Float(bitPattern: 0x6F12_3456),
        Float(bitPattern: 0x5380_0000),
        Float.infinity,
        Float.nan,
        Float.greatestFiniteMagnitude,
        0,
        -1,
    ])
    func vlcDemuxRateRejectsImpossibleReadings(rate: Float) {
        #expect(PlaybackVideoQuality.bitsPerSecond(fromVLCDemuxRate: rate) == nil)
    }

    @Test func summaryNamesEveryKnownFactIncludingSDR() {
        let quality = PlaybackVideoQuality(
            width: 3840, height: 2160, frameRate: 23.976, codec: "HEVC",
            dynamicRange: PlaybackVideoQuality.hdr10Label, bitrate: 42_100_000
        )
        #expect(quality.summary == "3840×2160 (4K) · 23.976 fps · HEVC · HDR10 · 42.1 Mbps")

        let sdr = PlaybackVideoQuality(
            width: 640, height: 360, frameRate: 25, dynamicRange: PlaybackVideoQuality.sdrLabel, bitrate: 700_000
        )
        #expect(sdr.summary == "640×360 · 25 fps · SDR · 700 kbps")
        #expect(PlaybackVideoQuality(width: 640, height: 360).summary == "640×360")
        #expect(PlaybackVideoQuality().summary == nil)
    }

    @Test func scopeUHDStillReadsAs4K() {
        #expect(PlaybackVideoQuality(width: 3840, height: 1600).resolutionLabel == "3840×1600 (4K)")
    }

    @Test func measuredFrameRatesSnapToTheirStandardRate() {
        #expect(PlaybackVideoQuality.snappedFrameRate(23.98) == 23.976)
        #expect(PlaybackVideoQuality.snappedFrameRate(59.9) == 59.94)
        #expect(PlaybackVideoQuality.snappedFrameRate(33.2) == 33)
        #expect(PlaybackVideoQuality.snappedFrameRate(0) == nil)
    }

    @Test func everySpellingOfACodecGetsOneName() {
        for raw in ["hvc1", "hev1", "hevc", "HEVC", "dvh1"] {
            #expect(PlaybackVideoQuality.codecName(for: raw) == "HEVC")
        }
        #expect(PlaybackVideoQuality.codecName(for: "mp2v") == "MPEG-2")
        #expect(PlaybackVideoQuality.codecName(for: "") == nil)
    }

    @Test func estimatedBitrateHoldsUnderATenPercentMove() {
        let held = PlaybackVideoQuality(bitrate: 5_000_000, bitrateIsEstimate: true)
        let small = PlaybackVideoQuality(bitrate: 5_200_000, bitrateIsEstimate: true)
        let large = PlaybackVideoQuality(bitrate: 7_000_000, bitrateIsEstimate: true)
        #expect(small.holdingEstimatedBitrate(from: held).bitrate == 5_000_000)
        #expect(large.holdingEstimatedBitrate(from: held).bitrate == 7_000_000)
    }

    @Test func transcodeNeverShowsTheSourcesMetadata() throws {
        let info = try debugInfo(decision: .transcode(.p720_4Mbps), trc: "smpte2084")
        #expect(info.currentVideoQuality(live: nil).isEmpty)

        let live = PlaybackVideoQuality(width: 1280, height: 720, bitrate: 4_000_000)
        #expect(info.currentVideoQuality(live: live) == live)
    }

    @Test func directPlayFillsGapsButTrustsTheEngine() throws {
        let info = try debugInfo(decision: .directPlay, trc: nil)
        let empty = info.currentVideoQuality(live: nil)
        #expect(empty.width == 1920)
        #expect(empty.frameRate == 23.976)
        #expect(empty.codec == "HEVC")
        #expect(empty.bitrate == 8_000_000)

        let measured = info.currentVideoQuality(live: PlaybackVideoQuality(width: 1280, height: 720))
        #expect(measured.width == 1280)
    }

    @Test func aMeasuredBitrateDefersToPlexButADeclaredOneDoesNot() throws {
        let info = try debugInfo(decision: .directPlay, trc: nil)
        let estimate = PlaybackVideoQuality(bitrate: 3_000_000, bitrateIsEstimate: true)
        #expect(info.currentVideoQuality(live: estimate).bitrate == 8_000_000)
        #expect(info.currentVideoQuality(live: estimate).bitrateIsEstimate == false)

        let declared = PlaybackVideoQuality(bitrate: 3_000_000)
        #expect(info.currentVideoQuality(live: declared).bitrate == 3_000_000)
    }

    @Test func vlcKitAdmitsItsHDROutputIsSDR() throws {
        let info = try debugInfo(decision: .directPlay, engine: .vlcKit, trc: "smpte2084")
        #expect(info.currentVideoQuality(live: nil).dynamicRange == "HDR10 (SDR output)")

        let hlg = try debugInfo(decision: .directPlay, engine: .vlcKit, trc: "arib-std-b67")
        #expect(hlg.currentVideoQuality(live: nil).dynamicRange == "HLG (SDR output)")
    }

    @Test func vlcKitSaysSDRForAnSDRSource() throws {
        let info = try debugInfo(decision: .directPlay, engine: .vlcKit)
        #expect(info.currentVideoQuality(live: nil).dynamicRange == "SDR")

        let stream = try debugInfo(decision: .serverStream, engine: .vlcKit)
        #expect(stream.currentVideoQuality(live: PlaybackVideoQuality(width: 1920, height: 1080)).dynamicRange == "SDR")
    }

    @Test func avPlayerNeverClaimsTheSourcesDolbyVisionUnmeasured() throws {
        let info = try debugInfo(decision: .spatialAudio, dolbyVision: (profile: 8, compat: 1))
        #expect(info.currentVideoQuality(live: nil).dynamicRange == nil)

        let measured = PlaybackVideoQuality(dynamicRange: PlaybackVideoQuality.hdr10Label)
        #expect(info.currentVideoQuality(live: measured).dynamicRange == "HDR10")
    }

    // MARK: AVPlayer dynamic range

    @Test func dolbyVision81FromTheTracksConfigurationBox() {
        // The remux keeps hvc1 and announces Dolby Vision through dvvC.
        let signals = trackSignals(transfer: .pq, record: record(profile: 8, level: 6, compat: 1))
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == "Dolby Vision 8.1")
    }

    @Test func dolbyVision84ReadsAsItsOwnProfile() {
        let signals = trackSignals(transfer: .hlg, record: record(profile: 8, level: 6, compat: 4))
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == "Dolby Vision 8.4")
    }

    @Test func dolbyVision5FromADvh1Track() {
        let signals = trackSignals(codec: "dvh1", transfer: .sdr, record: record(profile: 5, level: 6, compat: 0))
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == "Dolby Vision profile 5")

        // The sample entry alone still says Dolby Vision.
        let bare = trackSignals(codec: "dvh1", transfer: .sdr, record: nil)
        #expect(PlaybackVideoQuality.dynamicRange(for: bare) == "Dolby Vision")
    }

    @Test func convertedDolbyVision7NamesItsSource() {
        var signals = trackSignals(transfer: .pq, record: record(profile: 8, level: 6, compat: 1))
        signals.declaredDolbyVision = dolbyVision7.convertedToProfile81()
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == "Dolby Vision 8.1 (from profile 7)")
    }

    @Test func unconvertedDolbyVision7PlaysItsHDR10BaseLayer() {
        // The failed-conversion retry: the init keeps profile 7's dvcC.
        let signals = trackSignals(transfer: .pq, record: record(profile: 7, level: 6, compat: 6))
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == "HDR10")

        // Profile 8.2 / 8.6 have no Apple Dolby Vision form either.
        let p86 = trackSignals(transfer: .pq, record: record(profile: 8, level: 6, compat: 6))
        #expect(PlaybackVideoQuality.dynamicRange(for: p86) == "HDR10")
    }

    @Test func aTrackWithoutDolbyVisionOverridesTheDeclaredSignaling() {
        // A remux whose loader couldn't be installed plays the bare HDR10 item.
        var signals = trackSignals(transfer: .pq, record: nil)
        signals.declaredDolbyVision = dolbyVision81
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == "HDR10")
    }

    @Test func declaredSignalingStandsInUntilTheTrackLoads() {
        // SUPPLEMENTAL-CODECS leaves CODECS hvc1 and VIDEO-RANGE PQ.
        var signals = AVPlayerDynamicRangeSignals(variantCodecs: ["hvc1"], variantTransfer: .pq)
        signals.declaredDolbyVision = dolbyVision81
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == "Dolby Vision 8.1")

        // An SDR variant cannot be carrying it.
        signals.variantTransfer = .sdr
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == "SDR")
    }

    @Test func hdr10HlgAndSDRFromTheTransferFunction() {
        #expect(PlaybackVideoQuality.dynamicRange(for: trackSignals(transfer: .pq, record: nil)) == "HDR10")
        #expect(PlaybackVideoQuality.dynamicRange(for: trackSignals(transfer: .hlg, record: nil)) == "HLG")
        #expect(PlaybackVideoQuality.dynamicRange(for: trackSignals(transfer: .sdr, record: nil)) == "SDR")
        // The track's tags win over the playlist's VIDEO-RANGE.
        var signals = trackSignals(transfer: .pq, record: nil)
        signals.variantTransfer = .sdr
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == "HDR10")
    }

    @Test func hdrOnADisplayWithoutHDRSaysSDROutput() {
        var signals = trackSignals(transfer: .pq, record: record(profile: 8, level: 6, compat: 1))
        signals.displaySupportsHDR = false
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == "Dolby Vision 8.1 (SDR output)")

        var sdr = trackSignals(transfer: .sdr, record: nil)
        sdr.displaySupportsHDR = false
        #expect(PlaybackVideoQuality.dynamicRange(for: sdr) == "SDR")
    }

    @Test func nothingMeasuredYetIsUnknown() {
        var signals = AVPlayerDynamicRangeSignals()
        signals.declaredDolbyVision = dolbyVision81
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == nil)
    }

    @Test func configurationRecordParsesProfileLevelAndCompatibility() throws {
        let parsed = try #require(DolbyVisionRecord(data: record(profile: 8, level: 9, compat: 4)))
        #expect(parsed == DolbyVisionRecord(data: Data([1, 0, 0x10, 0x4D, 0x40])))
        #expect(parsed.profile == 8)
        #expect(parsed.level == 9)
        #expect(parsed.compatibilityID == 4)
        #expect(DolbyVisionRecord(data: Data([1, 0, 0x10])) == nil)
    }

    /// The headline case rests on CoreMedia handing the `dvvC` that
    /// `DolbyVisionSignaling` adds to an `hvc1` entry back in the format
    /// description: a real 64×64 HEVC PQ init segment, patched by the
    /// production code, read through the engine's own extraction.
    @MainActor
    @Test func coreMediaHandsBackTheRemuxsDvvC() async throws {
        let initSegment = try #require(Data(base64Encoded: Self.hevcPQInitSegment, options: .ignoreUnknownCharacters))
        let patched = try #require(DolbyVisionSignaling.patchedInitSegment(initSegment, configuration: dolbyVision81))

        let plain = try await formatDescription(of: initSegment)
        #expect(AVPlayerEngine.dolbyVisionRecord(of: plain) == nil)
        #expect(AVPlayerEngine.transfer(of: plain) == .pq)

        let signalled = try await formatDescription(of: patched)
        #expect(CMFormatDescriptionGetMediaSubType(signalled) == kCMVideoCodecType_HEVC)
        let record = try #require(AVPlayerEngine.dolbyVisionRecord(of: signalled).flatMap(DolbyVisionRecord.init(data:)))
        #expect(record.profile == 8)
        #expect(record.level == 6)
        #expect(record.compatibilityID == 1)

        var signals = trackSignals(transfer: AVPlayerEngine.transfer(of: signalled), record: AVPlayerEngine.dolbyVisionRecord(of: signalled))
        signals.declaredDolbyVision = dolbyVision81
        #expect(PlaybackVideoQuality.dynamicRange(for: signals) == "Dolby Vision 8.1")
    }

    private func formatDescription(of initSegment: Data) async throws -> CMFormatDescription {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dusk-dv-\(UUID().uuidString).mp4")
        try initSegment.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        return try #require(try await track.load(.formatDescriptions).first)
    }

    /// ffmpeg/libx265, one 64×64 frame, BT.2020 PQ, `-tag:v hvc1`, fMP4;
    /// only `ftyp` + `moov` kept (an HLS init segment).
    private static let hevcPQInitSegment = """
        AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAAAxhtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAAAABAAABAAAAAAAA
        AAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACP3Ry
        YWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA
        AAAAAAAAAEAAAAAAQAAAAEAAAAAAAdttZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAADAAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAA
        dmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAGGbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAA
        AAAAAAABAAAADHVybCAAAAABAAABRnN0YmwAAAD6c3RzZAAAAAAAAAABAAAA6mh2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAA
        QABAAEgAAABIAAAAAAAAAAEMTGF2YyBsaWJ4MjY1AAAAAAAAAAAAAAAAAAAAAAAAAAAY//8AAAB6aHZjQwECIAAAAJAAAAAAAB7w
        APz9+voAAA8DoAABABhAAQwB//8CIAAAAwCQAAADAAADAB6VmAmhAAEALUIBAQIgAAADAJAAAAMAAAMAHqAggQTZZWaSTK8BahIg
        EggAAAMACAAAAwDAQKIAAQAHRAHBcrQiQAAAAApmaWVsAQAAAAAQcGFzcAAAAAEAAAABAAAAEHN0dHMAAAAAAAAAAAAAABBzdHNj
        AAAAAAAAAAAAAAAUc3RzegAAAAAAAAAAAAAAAAAAABBzdGNvAAAAAAAAAAAAAAAobXZleAAAACB0cmV4AAAAAAAAAAEAAAABAAAA
        AAAAAAAAAAAAAAAAPXVkdGEAAAA1bWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAIaWxzdA==
        """

    private let dolbyVision81 = DolbyVisionConfiguration(
        profile: 8, level: 6, blSignalCompatibilityID: 1,
        lumaSampleRate: nil, lumaPictureSize: nil, bitrateKbps: nil
    )

    private let dolbyVision7 = DolbyVisionConfiguration(
        profile: 7, level: 6, blSignalCompatibilityID: 6,
        lumaSampleRate: nil, lumaPictureSize: nil, bitrateKbps: nil
    )

    private func trackSignals(
        codec: String = "hvc1",
        transfer: AVPlayerDynamicRangeSignals.Transfer,
        record: Data?
    ) -> AVPlayerDynamicRangeSignals {
        AVPlayerDynamicRangeSignals(
            variantCodecs: [codec],
            hasTrack: true,
            trackCodecs: [codec],
            trackTransfer: transfer,
            dolbyVisionRecord: record
        )
    }

    /// A `dvcC`/`dvvC` payload: version 1.0, RPU + BL present, no EL.
    private func record(profile: Int, level: Int, compat: Int) -> Data {
        let flags = 0b101
        return Data([
            1, 0,
            UInt8(profile << 1 | level >> 5),
            UInt8((level & 0x1F) << 3 | flags),
            UInt8(compat << 4),
        ])
    }

    private func debugInfo(
        decision: PlaybackDecision,
        engine: PlaybackEngineType = .avPlayer,
        trc: String? = nil,
        dolbyVision: (profile: Int, compat: Int)? = nil
    ) throws -> PlaybackDebugInfo {
        var videoFields = ""
        if let trc { videoFields += #", "colorTrc": "\#(trc)""# }
        if let dolbyVision {
            videoFields += #", "DOVIPresent": true, "DOVIProfile": \#(dolbyVision.profile), "DOVILevel": 6, "DOVIBLCompatID": \#(dolbyVision.compat)"#
        }
        let json = """
        {
            "id": 10,
            "container": "mkv",
            "bitrate": 8000,
            "width": 1920,
            "height": 1080,
            "videoCodec": "hevc",
            "Part": [{
                "id": 20,
                "key": "/library/parts/20/file.mkv",
                "container": "mkv",
                "Stream": [
                    { "id": 1, "streamType": 1, "codec": "hevc", "bitDepth": 10, "frameRate": 23.976,
                      "width": 1920, "height": 1080\(videoFields) },
                    { "id": 2, "streamType": 2, "codec": "eac3", "channels": 6 }
                ]
            }]
        }
        """
        let media = try JSONDecoder().decode(MediaVersion.self, from: Data(json.utf8))
        let part = try #require(media.parts.first)
        return PlaybackDebugInfo(
            title: "Test",
            engine: engine,
            decision: decision,
            media: media,
            part: part,
            attemptID: UUID(),
            resolverReason: "",
            sanitizedPlaybackURL: ""
        )
    }
}
