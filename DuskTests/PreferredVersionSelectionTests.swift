import Foundation
import Testing
@testable import Dusk

@Suite("Preferred Version selection")
@MainActor
struct PreferredVersionSelectionTests {
    private let uhd = Self.version(id: 1, resolution: "4k", width: 3840, height: 2160, bitrate: 60_000, size: 60_000_000_000)
    private let fullHD = Self.version(id: 2, resolution: "1080", width: 1920, height: 1080, bitrate: 12_000, size: 12_000_000_000)
    private let hd = Self.version(id: 3, resolution: "720", width: 1280, height: 720, bitrate: 4_000, size: 3_000_000_000)

    private func pick(_ versions: [PlexMedia], _ preference: PreferredMediaVersion, max: MaxResolution = .tenEightyP) -> Int? {
        StreamResolver.selectMediaVersion(
            from: versions,
            preferredMaxResolution: max,
            preferredVersion: preference
        )?.id
    }

    @Test func automaticKeepsTheMaxResolutionTarget() {
        #expect(pick([uhd, fullHD, hd], .automatic) == 2)
        #expect(pick([uhd, fullHD, hd], .automatic, max: .sevenTwentyP) == 3)
        #expect(pick([uhd, fullHD, hd], .automatic, max: .fourK) == 1)
    }

    @Test func highestQualityIgnoresTheTarget() {
        #expect(pick([hd, fullHD, uhd], .highestQuality, max: .sevenTwentyP) == 1)
    }

    @Test func highestQualityBreaksHeightTiesOnBitrate() {
        let remux = Self.version(id: 4, resolution: "1080", width: 1920, height: 1080, bitrate: 30_000, size: nil)
        #expect(pick([fullHD, remux], .highestQuality) == 4)
    }

    @Test func fullHDPicksTheBest1080pVersion() {
        let remux = Self.version(id: 4, resolution: "1080", width: 1920, height: 1080, bitrate: 30_000, size: nil)
        #expect(pick([uhd, fullHD, remux, hd], .fullHD, max: .fourK) == 4)
    }

    @Test func fullHDCountsCroppedAndUnlabelledFrames() {
        let scope = Self.version(id: 5, resolution: nil, width: 1920, height: 800, bitrate: 9_000, size: nil)
        #expect(pick([uhd, scope], .fullHD, max: .fourK) == 5)
        let pillarboxed = Self.version(id: 6, resolution: nil, width: 1440, height: 1080, bitrate: 9_000, size: nil)
        #expect(pick([uhd, pillarboxed], .fullHD, max: .fourK) == 6)
    }

    @Test func fullHDFallsBackToAutomaticWithoutA1080pVersion() {
        #expect(pick([uhd, hd], .fullHD, max: .fourK) == 1)
        #expect(pick([uhd, hd], .fullHD, max: .sevenTwentyP) == 3)
    }

    @Test func smallestFileUsesPartSizes() {
        // Bitrate alone would pick the 720p version; the sizes say otherwise.
        let tinyFullHD = Self.version(id: 7, resolution: "1080", width: 1920, height: 1080, bitrate: 5_000, size: 1_000_000_000)
        #expect(pick([uhd, hd, tinyFullHD], .smallestFile, max: .fourK) == 7)
    }

    @Test func smallestFileSumsMultiPartVersions() {
        let split = PlexMedia(
            id: 8, container: "mkv", videoCodec: "h264", audioCodec: "aac", videoResolution: "720",
            videoProfile: nil, audioProfile: nil, audioChannels: 2, width: 1280, height: 720,
            bitrate: 1_000, duration: nil, optimizedForStreaming: nil,
            parts: [Self.part(id: 80, size: 2_000_000_000), Self.part(id: 81, size: 2_000_000_000)]
        )
        #expect(pick([split, hd], .smallestFile) == 3)
    }

    @Test func smallestFileFallsBackToBitrateThenAutomatic() {
        let a = Self.version(id: 9, resolution: "1080", width: 1920, height: 1080, bitrate: 8_000, size: nil)
        let b = Self.version(id: 10, resolution: "1080", width: 1920, height: 1080, bitrate: 6_000, size: nil)
        #expect(pick([a, b], .smallestFile) == 10)

        let c = Self.version(id: 11, resolution: "4k", width: 3840, height: 2160, bitrate: nil, size: nil)
        let d = Self.version(id: 12, resolution: "1080", width: 1920, height: 1080, bitrate: nil, size: nil)
        #expect(pick([c, d], .smallestFile) == 12)
    }

    @Test func preferenceOnlyChoosesAmongAvailableVersions() {
        let missing = Self.version(id: 13, resolution: "4k", width: 3840, height: 2160, bitrate: 80_000, size: 70_000_000_000, exists: false)
        #expect(pick([missing, fullHD, hd], .highestQuality) == 2)
    }

    @Test func singleVersionIsAlwaysChosen() {
        for preference in PreferredMediaVersion.allCases {
            #expect(pick([hd], preference, max: .fourK) == 3)
        }
    }

    // MARK: - Fixtures

    private static func version(
        id: Int,
        resolution: String?,
        width: Int?,
        height: Int?,
        bitrate: Int?,
        size: Int?,
        exists: Bool? = nil
    ) -> PlexMedia {
        PlexMedia(
            id: id, container: "mkv", videoCodec: "hevc", audioCodec: "eac3", videoResolution: resolution,
            videoProfile: nil, audioProfile: nil, audioChannels: 6, width: width, height: height,
            bitrate: bitrate, duration: 7_200_000, optimizedForStreaming: nil,
            parts: [part(id: id * 10, size: size, exists: exists)]
        )
    }

    private static func part(id: Int, size: Int?, exists: Bool? = nil) -> PlexMediaPart {
        PlexMediaPart(
            id: id, key: "/library/parts/\(id)/file.mkv", file: nil, size: size, container: "mkv",
            duration: nil, videoProfile: nil, audioProfile: nil, accessible: nil, exists: exists, streams: []
        )
    }
}
