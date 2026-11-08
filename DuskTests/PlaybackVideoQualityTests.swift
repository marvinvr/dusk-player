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

    @Test func summaryNamesEveryKnownFactAndLeavesOutSDR() {
        let quality = PlaybackVideoQuality(
            width: 3840, height: 2160, frameRate: 23.976, codec: "HEVC",
            dynamicRange: PlaybackVideoQuality.hdr10Label, bitrate: 42_100_000
        )
        #expect(quality.summary == "3840×2160 (4K) · 23.976 fps · HEVC · HDR10 · 42.1 Mbps")

        let sdr = PlaybackVideoQuality(
            width: 640, height: 360, frameRate: 25, dynamicRange: PlaybackVideoQuality.sdrLabel, bitrate: 700_000
        )
        #expect(sdr.summary == "640×360 · 25 fps · 700 kbps")
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

    @Test func avPlayerDolbyVisionGainsPlexsProfile() throws {
        let info = try debugInfo(decision: .spatialAudio, dolbyVision: (profile: 8, compat: 1))
        let live = PlaybackVideoQuality(dynamicRange: PlaybackVideoQuality.dolbyVisionLabel)
        #expect(info.currentVideoQuality(live: live).dynamicRange == "Dolby Vision 8.1")
    }

    @Test func aFailedDolbyVisionConversionReadsAsItsBaseLayer() throws {
        let info = try debugInfo(decision: .spatialAudio, dolbyVision: (profile: 7, compat: 6))
        let retry = PlaybackVideoQuality(dynamicRange: PlaybackVideoQuality.hdr10Label)
        #expect(info.currentVideoQuality(live: retry).dynamicRange == "HDR10")

        // The converted stream is real Dolby Vision, not the source's profile 7.
        let converted = PlaybackVideoQuality(dynamicRange: PlaybackVideoQuality.dolbyVisionLabel)
        #expect(info.currentVideoQuality(live: converted).dynamicRange == "Dolby Vision")
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
        let media = try JSONDecoder().decode(PlexMedia.self, from: Data(json.utf8))
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
