import Foundation
import Testing
@testable import Dusk

/// Plex's fMP4 remux of an open-GOP copy stamps each segment's first keyframe
/// on its first leading frame's presentation time (measured on Oppenheimer
/// 4K, DV 8.1, 23.976 fps: keyframe 10.344 s in the MKV, 10.260 s in the
/// remux, every other frame exact). The fixtures rebuild that `moof` layout:
/// two `sidx`, a video `traf` (tfhd 0x20038, tfdt v1, trun v0 0xf01) and an
/// audio `traf` (trun 0x1 on tfhd defaults).
@Suite("Remux keyframe timestamp repair")
struct RemuxKeyframeTimestampRepairTests {
    private static let frame: Int64 = 1001   // 1/24000 timescale, 23.976 fps

    /// One sample in decode order: presentation time in frames from the
    /// fragment's first decode time.
    private struct Sample {
        var pts: Int64
        var sync = false
    }

    /// Open GOP in decode order: I, its two leading Bs, then P B B triplets;
    /// presentation slots relative to the first leading B. A second GOP
    /// follows so the first one has an end.
    private static func openGOP(keyframeSlot: Int64) -> [Sample] {
        var samples = [Sample(pts: keyframeSlot, sync: true), Sample(pts: 0), Sample(pts: 1)]
        var slot: Int64 = 2
        for _ in 0..<6 {
            samples += [Sample(pts: slot + 3), Sample(pts: slot + 1), Sample(pts: slot + 2)]
            slot += 3
        }
        let next = slot + 3
        samples += [Sample(pts: next, sync: true), Sample(pts: next - 2), Sample(pts: next - 1)]
        return samples
    }

    /// Correct stream: the keyframe after its two leading frames.
    private static let correctGOP = openGOP(keyframeSlot: 2)
    /// Plex: the keyframe on the first leading frame's slot, its own empty.
    private static let plexGOP = openGOP(keyframeSlot: 0)

    // MARK: - Repair

    @Test func movesTheMisplacedKeyframeIntoItsHole() throws {
        var segment = Self.segment(video: Self.plexGOP)
        let original = segment
        let end = try #require(Self.moofEnd(segment))

        #expect(RemuxKeyframeTimestampRepair.repair(&segment, moofEnd: end) == 1)

        let times = Self.videoPresentationTimes(segment)
        #expect(times == Self.videoPresentationTimes(Self.segment(video: Self.correctGOP)))
        #expect(times.first == 2 * Self.frame + Self.leadingOffset)
        // Only sample 0's composition offset (4 bytes) changed.
        #expect(segment.count == original.count)
        let changed = zip(segment, original).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(!changed.isEmpty && changed.count <= 4)
        #expect((changed.max() ?? 0) - (changed.min() ?? 0) < 4)
    }

    @Test func millisecondRoundedTimestampsStillRepair() throws {
        // Plex writes millisecond-rounded times at 1/24000: 984/1008 ticks.
        var segment = Self.segment(video: Self.plexGOP, millisecondRounded: true)
        let end = try #require(Self.moofEnd(segment))
        #expect(RemuxKeyframeTimestampRepair.repair(&segment, moofEnd: end) == 1)

        let times = Self.videoPresentationTimes(segment)
        let others = times.dropFirst().sorted()
        // The keyframe now sits inside the former hole, after both leading frames.
        let leading = others.prefix(2)
        #expect(times[0] > leading.max()!)
        #expect(times[0] < others[2])
        #expect(Set(times).count == times.count)
    }

    @Test func keyframeATickOffItsLeadingFrameStillRepairs() throws {
        // Seen after a transcoder restart: keyframe 984, leading frame 1008.
        var segment = Self.segment(video: Self.plexGOP, keyframeTickShift: -24)
        #expect(RemuxKeyframeTimestampRepair.repairSegment(&segment) == 1)
        #expect(Self.videoPresentationTimes(segment) == Self.videoPresentationTimes(Self.segment(video: Self.correctGOP)))
    }

    @Test func correctSegmentIsUntouched() throws {
        var segment = Self.segment(video: Self.correctGOP)
        let original = segment
        let end = try #require(Self.moofEnd(segment))
        #expect(RemuxKeyframeTimestampRepair.repair(&segment, moofEnd: end) == 0)
        #expect(segment == original)
    }

    @Test func closedGOPIsUntouched() throws {
        var samples = [Sample(pts: 0, sync: true)]
        var slot: Int64 = 0
        for _ in 0..<6 {
            samples += [Sample(pts: slot + 3), Sample(pts: slot + 1), Sample(pts: slot + 2)]
            slot += 3
        }
        samples.append(Sample(pts: slot + 1, sync: true))
        var segment = Self.segment(video: samples)
        let original = segment
        #expect(RemuxKeyframeTimestampRepair.repairSegment(&segment) == 0)
        #expect(segment == original)
    }

    @Test func restartSegmentAfterASeekIsUntouched() throws {
        // The first segment of a restarted transcode: leading frames squashed
        // a tick apart before the keyframe, no duplicate time.
        var samples = Self.correctGOP
        samples[1].pts = 1
        samples[2].pts = 1
        var segment = Self.segment(video: samples, leadingTicks: [0, 24])
        let original = segment
        #expect(RemuxKeyframeTimestampRepair.repairSegment(&segment) == 0)
        #expect(segment == original)
    }

    @Test func twoHolesAreNotGuessedAt() throws {
        var samples = Self.plexGOP
        // A dropped frame deeper in the GOP makes a second hole.
        samples.remove(at: 7)
        var segment = Self.segment(video: samples)
        let original = segment
        #expect(RemuxKeyframeTimestampRepair.repairSegment(&segment) == 0)
        #expect(segment == original)
    }

    @Test func signedOffsetsRepairToo() throws {
        var segment = Self.segment(video: Self.plexGOP, trunVersion: 1, decodeShift: -3)
        #expect(RemuxKeyframeTimestampRepair.repairSegment(&segment) == 1)
        #expect(Self.videoPresentationTimes(segment) == Self.videoPresentationTimes(
            Self.segment(video: Self.correctGOP, trunVersion: 1, decodeShift: -3)
        ))
    }

    // MARK: - Prefix scan

    @Test func prefixScanWaitsForTheWholeMoof() throws {
        let segment = Self.segment(video: Self.plexGOP)
        let end = try #require(Self.moofEnd(segment))
        #expect(RemuxKeyframeTimestampRepair.scanPrefix(segment.prefix(4)) == .needsMoreBytes)
        #expect(RemuxKeyframeTimestampRepair.scanPrefix(segment.prefix(60)) == .needsMoreBytes)
        #expect(RemuxKeyframeTimestampRepair.scanPrefix(segment.prefix(end - 1)) == .needsMoreBytes)
        #expect(RemuxKeyframeTimestampRepair.scanPrefix(segment.prefix(end)) == .moofComplete(end: end))
        #expect(RemuxKeyframeTimestampRepair.scanPrefix(segment) == .moofComplete(end: end))
    }

    @Test func prefixScanPassesMediaDataFirstThrough() {
        var data = Self.box("mdat", Data(repeating: 0, count: 32))
        data.append(Self.box("moof", Data()))
        #expect(RemuxKeyframeTimestampRepair.scanPrefix(data) == .passThrough)
        #expect(RemuxKeyframeTimestampRepair.scanPrefix(Data([0, 0, 0, 4, 0x6D, 0x6F, 0x6F, 0x66])) == .passThrough)
    }

    @Test func repairOnAPrefixMatchesRepairOnTheWholeSegment() throws {
        let segment = Self.segment(video: Self.plexGOP)
        let end = try #require(Self.moofEnd(segment))
        var prefix = Data(segment.prefix(end))
        var whole = segment
        RemuxKeyframeTimestampRepair.repair(&prefix, moofEnd: end)
        RemuxKeyframeTimestampRepair.repairSegment(&whole)
        #expect(prefix + segment.dropFirst(end) == whole)
    }

    // MARK: - Playlist routing

    @Test func loaderRoutesOnlyMediaSegmentsThroughTheRelay() {
        let loader = RemuxHLSLoader(restoresDolbyAtmos: false, dolbyVision: nil, repairsKeyframeTimestamps: true)
        let base = URL(string: "http://plex.test:32400/video/:/transcode/universal/session/abc/base/index.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MAP:URI="header"
        #EXT-X-TARGETDURATION:10
        #EXTINF:10, nodesc
        00000.ts
        #EXTINF:3, nodesc
        00001.ts
        #EXT-X-ENDLIST
        """
        let rewritten = loader.rewrittenPlaylist(playlist, baseURL: base) { url in
            URL(string: "http://127.0.0.1:1/t/s/\(url.lastPathComponent).m4s")
        }
        #expect(rewritten.contains("http://127.0.0.1:1/t/s/00000.ts.m4s"))
        #expect(rewritten.contains("http://127.0.0.1:1/t/s/00001.ts.m4s"))
        #expect(rewritten.contains("#EXT-X-MAP:URI=\"dusk-remux-http://plex.test:32400/"))
        #expect(rewritten.contains("/base/header\""))
        // Without a relay, segments stay on the server.
        #expect(loader.rewrittenPlaylist(playlist, baseURL: base).contains("\nhttp://plex.test:32400/video/:/transcode/universal/session/abc/base/00000.ts"))
    }

    // MARK: - Fixture

    /// The Plex-layout segment with the misplaced keyframe (relay tests).
    static func plexSegment() -> Data {
        segment(video: plexGOP)
    }

    /// Composition offset of the first leading B in the fixtures: decode
    /// time 1 frame, shown at slot 0 = 1 frame (`trun` v0 cannot go
    /// negative, so slot 0 is decode time 1).
    private static let leadingOffset = frame

    /// Builds `sidx, sidx, moof, mdat` for `video` (presentation slots in
    /// frames; decode times one frame apart from 0, slot 0 shown at decode
    /// time 1 frame) plus a two-sample audio fragment.
    private static func segment(
        video: [Sample],
        millisecondRounded: Bool = false,
        trunVersion: UInt8 = 0,
        decodeShift: Int64 = 0,
        leadingTicks: [Int64]? = nil,
        keyframeTickShift: Int64 = 0
    ) -> Data {
        func ticks(_ frames: Int64) -> Int64 {
            guard millisecondRounded else { return frames * frame }
            let milliseconds = (Double(frames) * 1001.0 / 24.0).rounded()
            return Int64(milliseconds) * 24
        }
        let decodeTimes = video.indices.map { ticks(Int64($0) + decodeShift) }
        var presentationTimes = video.map { ticks($0.pts + 1) }
        presentationTimes[0] += keyframeTickShift
        if let leadingTicks {
            presentationTimes[1] = presentationTimes[0] - 48 + leadingTicks[0]
            presentationTimes[2] = presentationTimes[0] - 48 + leadingTicks[1]
        }

        var entries = Data()
        for index in video.indices {
            let duration = index + 1 < video.count ? decodeTimes[index + 1] - decodeTimes[index] : frame
            let offset = presentationTimes[index] - decodeTimes[index]
            entries.append(be32(UInt32(duration)))
            entries.append(be32(1000))   // size
            entries.append(be32(video[index].sync ? 0x0200_0000 : 0x0101_0000))
            entries.append(be32(UInt32(bitPattern: Int32(offset))))
        }
        var videoTrun = be32(UInt32(trunVersion) << 24 | 0xF01) + be32(UInt32(video.count)) + be32(0)
        videoTrun.append(entries)
        let videoTraf = box("traf",
            box("tfhd", be32(0x20038) + be32(1) + be32(1001) + be32(1000) + be32(0x0101_0000))
            + box("tfdt", be32(0x0100_0000) + be64(240_000))
            + box("trun", videoTrun)
        )
        let audioTraf = box("traf",
            box("tfhd", be32(0x20038) + be32(2) + be32(1536) + be32(700) + be32(0x0200_0000))
            + box("tfdt", be32(0x0100_0000) + be64(480_000))
            + box("trun", be32(0x1) + be32(2) + be32(0))
        )
        let moof = box("moof", box("mfhd", be32(0) + be32(1)) + videoTraf + audioTraf)
        let sidx = box("sidx", Data(repeating: 0, count: 44))
        return sidx + sidx + moof + box("mdat", Data(repeating: 0xAB, count: 64))
    }

    private static func moofEnd(_ segment: Data) -> Int? {
        if case let .moofComplete(end) = RemuxKeyframeTimestampRepair.scanPrefix(segment) { return end }
        return nil
    }

    /// The video `trun`'s presentation times relative to the fragment's
    /// first decode time, in decode order.
    private static func videoPresentationTimes(_ segment: Data) -> [Int64] {
        let bytes = [UInt8](segment)
        guard let trun = find("trun", in: bytes) else { return [] }
        let version = bytes[trun]
        let count = Int(read32(bytes, trun + 4))
        var cursor = trun + 12
        var decode: Int64 = 0
        var times: [Int64] = []
        for _ in 0..<count {
            let duration = Int64(read32(bytes, cursor))
            let raw = read32(bytes, cursor + 12)
            let offset = version == 0 ? Int64(raw) : Int64(Int32(bitPattern: raw))
            times.append(decode + offset)
            decode += duration
            cursor += 16
        }
        return times
    }

    /// Payload offset of the first box of `type` (the video `trun`).
    private static func find(_ type: String, in bytes: [UInt8]) -> Int? {
        let needle = Array(type.utf8)
        for index in 4..<(bytes.count - 4) where Array(bytes[index..<(index + 4)]) == needle {
            return index + 4
        }
        return nil
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func box(_ type: String, _ payload: Data) -> Data {
        be32(UInt32(8 + payload.count)) + Data(type.utf8) + payload
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func be64(_ value: UInt64) -> Data {
        be32(UInt32(value >> 32)) + be32(UInt32(value & 0xFFFF_FFFF))
    }
}
