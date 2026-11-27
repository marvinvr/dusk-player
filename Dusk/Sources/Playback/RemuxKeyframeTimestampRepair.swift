import Foundation

/// Repairs the keyframe timestamp Plex's fMP4 remux gets wrong at the start of
/// every media segment of an open-GOP video copy.
///
/// UHD Blu-ray remuxes (HEVC, Dolby Vision 8.1 and 7 included) are open GOP:
/// each keyframe is followed in decode order by leading B-frames that are
/// shown *before* it. Plex's segmenter cuts every segment at a keyframe and
/// stamps that first sample's composition offset a frame past its decode
/// time, as if nothing were shown before it. Its presentation time lands on
/// its first leading frame's (a duplicate) and its own slot stays empty
/// (measured on Oppenheimer 4K, DV 8.1: source keyframe 10.344 s, remux
/// 10.260 s; every later frame exact, mid-segment keyframes exact; the same
/// with the audio copied). Decoded, the presentation times step backwards at
/// every cut (ffmpeg); on screen that is the keyframe two frames early, then
/// the two leading frames, then a hold over the hole: the reported "picture
/// jumps back" at a segment change (inferred, not captured on a device).
///
/// The repair only moves that first sample into the single hole its own GOP
/// leaves, and only when the fragment shows exactly that pattern: sample 0 is
/// a sync sample, a later sample of its GOP shares its presentation time
/// (within a quarter frame), and
/// the GOP's other presentation times have exactly one one-frame hole, just
/// after it. Anything else (closed GOP, the restart segment after a seek,
/// audio, a layout it cannot read) is left byte for byte. Only `trun`'s
/// sample-0 composition offset changes, so sizes and offsets stay valid.
enum RemuxKeyframeTimestampRepair {
    /// What the start of a segment holds so far.
    enum Prefix: Equatable {
        /// The first `moof` is not complete yet.
        case needsMoreBytes
        /// The first `moof` is complete and ends at this offset.
        case moofComplete(end: Int)
        /// No `moof` before media data, or a layout this does not read:
        /// relay the segment untouched.
        case passThrough
    }

    /// A `moof` past this offset is not looked for (Plex's is a few KB after
    /// two `sidx`).
    static let maximumPrefixBytes = 4 << 20

    /// Scans the top-level boxes at the start of a segment for its first `moof`.
    static func scanPrefix(_ data: Data) -> Prefix {
        var offset = 0
        let count = data.count
        while true {
            guard offset + 8 <= count else {
                return offset + 8 > maximumPrefixBytes ? .passThrough : .needsMoreBytes
            }
            var size = Int(read32(data, offset))
            let type = fourCC(data, offset + 4)
            var headerLength = 8
            if size == 1 {
                guard offset + 16 <= count else { return .needsMoreBytes }
                let large = read64(data, offset + 8)
                guard large <= UInt64(Int.max) else { return .passThrough }
                size = Int(large)
                headerLength = 16
            }
            guard size >= headerLength else { return .passThrough }
            let (end, overflow) = offset.addingReportingOverflow(size)
            guard !overflow else { return .passThrough }
            switch type {
            case "moof":
                guard end <= maximumPrefixBytes else { return .passThrough }
                return end <= count ? .moofComplete(end: end) : .needsMoreBytes
            case "mdat":
                return .passThrough
            default:
                guard end <= maximumPrefixBytes else { return .passThrough }
                offset = end
            }
        }
    }

    /// Repairs the first `moof` of `segment` in place (the bytes up to
    /// `moofEnd` from `scanPrefix`). Returns how many track fragments changed.
    @discardableResult
    static func repair(_ segment: inout Data, moofEnd: Int) -> Int {
        guard moofEnd <= segment.count,
              let moofStart = topLevelMoofStart(segment, end: moofEnd) else { return 0 }
        var repaired = 0
        for traf in childBoxes(segment, from: moofStart.payload, to: moofEnd) where traf.type == "traf" {
            if repairTrackFragment(&segment, traf: traf) { repaired += 1 }
        }
        return repaired
    }

    /// Convenience for a whole buffered segment (the Dolby Vision 7 proxy).
    @discardableResult
    static func repairSegment(_ segment: inout Data) -> Int {
        guard case let .moofComplete(end) = scanPrefix(segment) else { return 0 }
        return repair(&segment, moofEnd: end)
    }

    // MARK: - Track fragment

    private struct Box {
        let type: String
        let start: Int
        let payload: Int
        let end: Int
    }

    private struct Sample {
        var decodeTime: Int64
        var presentationTime: Int64
        var duration: Int64
        var isSync: Bool
    }

    private static func repairTrackFragment(_ data: inout Data, traf: Box) -> Bool {
        let children = childBoxes(data, from: traf.payload, to: traf.end)
        guard let tfhd = children.first(where: { $0.type == "tfhd" }),
              tfhd.payload + 8 <= tfhd.end,
              let trun = children.first(where: { $0.type == "trun" }) else { return false }

        // tfhd: version/flags, track id, then the optional fields in order.
        let tfhdFlags = read32(data, tfhd.payload) & 0x00FF_FFFF
        var cursor = tfhd.payload + 8
        if tfhdFlags & 0x01 != 0 { cursor += 8 }   // base data offset
        if tfhdFlags & 0x02 != 0 { cursor += 4 }   // sample description index
        var defaultDuration: UInt32?
        var defaultFlags: UInt32?
        if tfhdFlags & 0x08 != 0 {
            guard cursor + 4 <= tfhd.end else { return false }
            defaultDuration = read32(data, cursor)
            cursor += 4
        }
        if tfhdFlags & 0x10 != 0 { cursor += 4 }   // default sample size
        if tfhdFlags & 0x20 != 0 {
            guard cursor + 4 <= tfhd.end else { return false }
            defaultFlags = read32(data, cursor)
        }

        // trun: per-sample composition offsets are what is being repaired.
        guard trun.payload + 8 <= trun.end else { return false }
        let version = data[data.startIndex + trun.payload]
        let trunFlags = read32(data, trun.payload) & 0x00FF_FFFF
        let sampleCount = Int(read32(data, trun.payload + 4))
        let hasDuration = trunFlags & 0x100 != 0
        let hasSize = trunFlags & 0x200 != 0
        let hasFlags = trunFlags & 0x400 != 0
        let hasOffset = trunFlags & 0x800 != 0
        guard hasOffset, sampleCount >= 4, hasDuration || defaultDuration != nil else { return false }

        cursor = trun.payload + 8
        if trunFlags & 0x01 != 0 { cursor += 4 }   // data offset
        var firstSampleFlags: UInt32?
        if trunFlags & 0x04 != 0 {
            guard cursor + 4 <= trun.end else { return false }
            firstSampleFlags = read32(data, cursor)
            cursor += 4
        }
        guard hasFlags || firstSampleFlags != nil || defaultFlags != nil else { return false }
        let entryLength = 4 * ([hasDuration, hasSize, hasFlags, hasOffset].filter { $0 }.count)
        guard cursor + entryLength * sampleCount <= trun.end else { return false }

        var samples: [Sample] = []
        samples.reserveCapacity(sampleCount)
        var firstOffsetPosition = 0
        var decodeTime: Int64 = 0
        for index in 0..<sampleCount {
            var field = cursor + index * entryLength
            var duration = Int64(defaultDuration ?? 0)
            if hasDuration { duration = Int64(read32(data, field)); field += 4 }
            if hasSize { field += 4 }
            var flags = defaultFlags ?? 0
            if index == 0, let firstSampleFlags { flags = firstSampleFlags }
            if hasFlags { flags = read32(data, field); field += 4 }
            if index == 0 { firstOffsetPosition = field }
            let rawOffset = read32(data, field)
            let offset = version == 0 ? Int64(rawOffset) : Int64(Int32(bitPattern: rawOffset))
            // sample_is_non_sync_sample is bit 16 of the sample flags.
            samples.append(Sample(
                decodeTime: decodeTime,
                presentationTime: decodeTime + offset,
                duration: duration,
                isSync: flags & 0x0001_0000 == 0
            ))
            decodeTime += duration
        }

        guard let newPresentationTime = repairedKeyframePresentationTime(samples) else { return false }
        let newOffset = newPresentationTime - samples[0].decodeTime
        let stored: UInt32
        if version == 0 {
            guard newOffset >= 0, newOffset <= Int64(UInt32.max) else { return false }
            stored = UInt32(newOffset)
        } else {
            guard newOffset >= Int64(Int32.min), newOffset <= Int64(Int32.max) else { return false }
            stored = UInt32(bitPattern: Int32(newOffset))
        }
        write32(stored, into: &data, at: firstOffsetPosition)
        return true
    }

    /// The presentation time sample 0 should have, or nil when the fragment
    /// does not show the misplaced-keyframe pattern.
    private static func repairedKeyframePresentationTime(_ samples: [Sample]) -> Int64? {
        guard let keyframe = samples.first, keyframe.isSync else { return nil }
        let gopEnd = samples.dropFirst().firstIndex(where: \.isSync) ?? samples.count
        let gop = samples[1..<gopEnd]
        guard gop.count >= 3 else { return nil }

        // Frame duration: the GOP's median (Plex rounds to the millisecond,
        // so 23.976 fps alternates 984/1008 ticks at 1/24000).
        let durations = gop.map(\.duration).sorted()
        let frame = durations[durations.count / 2]
        guard frame > 0 else { return nil }

        // The keyframe sits on a leading frame's presentation time (within a
        // quarter frame: Plex's millisecond rounding can leave them a tick
        // apart, e.g. 984 vs 1008 after a transcoder restart)...
        guard gop.contains(where: { abs($0.presentationTime - keyframe.presentationTime) * 4 <= frame }) else {
            return nil
        }

        // ...and the rest of the GOP leaves exactly one one-frame hole, right
        // after it.
        let times = gop.map(\.presentationTime).sorted()
        guard Set(times).count == times.count else { return nil }
        var hole: (lower: Int64, upper: Int64)?
        for (lower, upper) in zip(times, times.dropFirst()) {
            let gap = upper - lower
            if gap * 2 > frame * 3 {   // more than 1.5 frames apart
                guard hole == nil, gap * 2 < frame * 5 else { return nil }   // one hole, under 2.5 frames
                hole = (lower, upper)
            }
        }
        guard let hole,
              hole.lower >= keyframe.presentationTime,
              hole.lower - keyframe.presentationTime <= frame * 4 else { return nil }
        let repaired = hole.lower + (hole.upper - hole.lower) / 2
        // A presentation time before its own decode time is not representable
        // in a version 0 `trun`, and never what the source had.
        guard repaired >= keyframe.decodeTime else { return nil }
        return repaired
    }

    // MARK: - Bytes

    private static func topLevelMoofStart(_ data: Data, end: Int) -> Box? {
        childBoxes(data, from: 0, to: end).first { $0.type == "moof" && $0.end == end }
    }

    private static func childBoxes(_ data: Data, from start: Int, to end: Int) -> [Box] {
        var boxes: [Box] = []
        var offset = start
        while offset + 8 <= end {
            var size = Int(read32(data, offset))
            var headerLength = 8
            if size == 1 {
                guard offset + 16 <= end else { break }
                let large = read64(data, offset + 8)
                guard large <= UInt64(end - offset) else { break }
                size = Int(large)
                headerLength = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= headerLength, offset + size <= end else { break }
            boxes.append(Box(type: fourCC(data, offset + 4), start: offset, payload: offset + headerLength, end: offset + size))
            offset += size
        }
        return boxes
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    private static func read64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(read32(data, offset)) << 32 | UInt64(read32(data, offset + 4))
    }

    private static func write32(_ value: UInt32, into data: inout Data, at offset: Int) {
        let base = data.startIndex + offset
        data[base] = UInt8(value >> 24)
        data[base + 1] = UInt8((value >> 16) & 0xFF)
        data[base + 2] = UInt8((value >> 8) & 0xFF)
        data[base + 3] = UInt8(value & 0xFF)
    }

    private static func fourCC(_ data: Data, _ offset: Int) -> String {
        let base = data.startIndex + offset
        return String(decoding: data[base..<(base + 4)], as: UTF8.self)
    }
}
