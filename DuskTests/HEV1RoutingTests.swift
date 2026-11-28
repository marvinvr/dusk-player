import Foundation
import Testing
@testable import Dusk

/// HEVC tagged `hev1` in MP4: AVPlayer plays the audio and never shows a
/// picture, so the resolver sends it to the retagging Plex remux (VLCKit as
/// the last-resort direct play).
@Suite("hev1 HEVC routing")
struct HEV1RoutingTests {
    @Test func hev1MP4LeavesAVPlayerDirectPlay() throws {
        let media = try makeMedia(codecID: "hev1")
        let decision = StreamResolver.evaluate(media: media)
        #expect(decision.engine == .vlcKit)
        #expect(decision.requiresServerTranscode)
        #expect(StreamResolver.containsHEV1Video(media))
    }

    @Test func hev1DirectPlayFallbackOpensOnVLCKit() throws {
        let media = try makeMedia(codecID: "hev1")
        let decision = StreamResolver.evaluateForDirectPlayback(
            media: media,
            part: media.parts[0],
            enhancementMode: .disabled,
            selectedSubtitleStreamID: nil
        )
        #expect(decision.engine == .vlcKit)
    }

    @Test func hvc1MP4KeepsAVPlayer() throws {
        let decision = StreamResolver.evaluate(media: try makeMedia(codecID: "hvc1"))
        #expect(decision.engine == .avPlayer)
        #expect(!decision.requiresServerTranscode)
    }

    @Test func untaggedHEVCKeepsAVPlayer() throws {
        let decision = StreamResolver.evaluate(media: try makeMedia(codecID: nil))
        #expect(decision.engine == .avPlayer)
        #expect(!decision.requiresServerTranscode)
    }

    @Test func hev1MKVIsPlainVLCKit() throws {
        let media = try makeMedia(container: "mkv", codecID: "hev1")
        let decision = StreamResolver.evaluate(media: media)
        #expect(decision.engine == .vlcKit)
        #expect(!decision.requiresServerTranscode)
        #expect(!StreamResolver.containsHEV1Video(media))
    }

    @Test func forcedEnginesAreRespected() throws {
        let media = try makeMedia(codecID: "hev1")
        let avPlayer = StreamResolver.evaluate(media: media, forceAVPlayer: true)
        #expect(avPlayer.engine == .avPlayer)
        #expect(!avPlayer.requiresServerTranscode)
        let vlcKit = StreamResolver.evaluate(media: media, forceVLCKit: true)
        #expect(vlcKit.engine == .vlcKit)
        #expect(!vlcKit.requiresServerTranscode)
    }

    @Test func probeOnlyForUntaggedHEVCBoundForAVPlayer() throws {
        #expect(StreamResolver.needsHEVCSampleEntryProbe(media: try makeMedia(codecID: nil)))
        #expect(!StreamResolver.needsHEVCSampleEntryProbe(media: try makeMedia(codecID: "hvc1")))
        #expect(!StreamResolver.needsHEVCSampleEntryProbe(media: try makeMedia(codecID: "hev1")))
        #expect(!StreamResolver.needsHEVCSampleEntryProbe(media: try makeMedia(container: "mkv", codecID: nil)))
        #expect(!StreamResolver.needsHEVCSampleEntryProbe(media: try makeMedia(videoCodec: "h264", codecID: nil)))
        #expect(!StreamResolver.needsHEVCSampleEntryProbe(media: try makeMedia(audioCodec: "dca", codecID: nil)))
        #expect(!StreamResolver.needsHEVCSampleEntryProbe(media: try makeMedia(codecID: nil), forceAVPlayer: true))
        #expect(!StreamResolver.needsHEVCSampleEntryProbe(media: try makeMedia(codecID: nil), forceVLCKit: true))
    }

    @Test func stampedProbeResultReroutes() throws {
        let details = try makeDetails()
        #expect(StreamResolver.evaluate(media: details.media[0]).engine == .avPlayer)
        let stamped = details.stampingVideoSampleEntry("hev1", mediaID: "10", partID: "20")
        #expect(stamped.media[0].parts[0].streams[0].codecID == "hev1")
        #expect(stamped.media[0].parts[0].streams[1].codecID == nil)
        #expect(StreamResolver.evaluate(media: stamped.media[0]).requiresServerTranscode)
        let otherPart = details.stampingVideoSampleEntry("hev1", mediaID: "10", partID: "99")
        #expect(StreamResolver.evaluate(media: otherPart.media[0]).engine == .avPlayer)
    }

    @Test func remuxBlocker() throws {
        let media = try makeMedia(codecID: "hev1", subtitleCodec: "pgs")
        #expect(StreamResolver.hev1RemuxBlocker(media: media, subtitleStream: nil) == nil)
        let pgs = media.parts[0].streams.first { $0.streamType == .subtitle }
        #expect(StreamResolver.hev1RemuxBlocker(media: media, subtitleStream: pgs)?.contains("subtitle") == true)
        #expect(StreamResolver.hev1RemuxBlocker(media: try makeMedia(codecID: "hvc1"), subtitleStream: nil) != nil)
    }
}

@Suite("hev1 → hvc1 init segment retag")
struct HEVCSampleEntryRetagTests {
    @Test func retagsEntryWithParameterSets() throws {
        let patched = try #require(HEVCSampleEntryRetag.patchedInitSegment(Data(initSegment(arrays: [32, 33, 34]))))
        let bytes = [UInt8](patched)
        #expect(bytes.count == initSegment(arrays: [32, 33, 34]).count)
        #expect(contains(bytes, "hvc1"))
        #expect(!contains(bytes, "hev1"))
    }

    @Test func leavesEntryWithoutParameterSets() {
        #expect(HEVCSampleEntryRetag.patchedInitSegment(Data(initSegment(arrays: [32, 33]))) == nil)
        #expect(HEVCSampleEntryRetag.patchedInitSegment(Data(initSegment(arrays: []))) == nil)
    }

    @Test func leavesHVC1Alone() {
        #expect(HEVCSampleEntryRetag.patchedInitSegment(Data(initSegment(entryType: "hvc1", arrays: [32, 33, 34]))) == nil)
    }

    @Test func rewritesVariantCodecs() {
        let line = #"#EXT-X-STREAM-INF:BANDWIDTH=3200000,RESOLUTION=1920x960,CODECS="hev1.2.4.L120.90,mp4a.40.2""#
        #expect(HEVCSampleEntryRetag.rewrittenStreamInfLine(line)
            == #"#EXT-X-STREAM-INF:BANDWIDTH=3200000,RESOLUTION=1920x960,CODECS="hvc1.2.4.L120.90,mp4a.40.2""#)
        let hvc1 = #"#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="hvc1.2.4.L120.90,mp4a.40.2""#
        #expect(HEVCSampleEntryRetag.rewrittenStreamInfLine(hvc1) == hvc1)
    }

    @Test func loaderRetagsPlaylistOnlyWhenAsked() {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"hev1.2.4.L120.90,mp4a.40.2\"\nhls/idx.m3u8"
        let base = URL(string: "http://127.0.0.1:32400/video/:/transcode/universal/start.m3u8")!
        let retagging = RemuxHLSLoader(restoresDolbyAtmos: false, dolbyVision: nil, retagsHEV1: true)
        #expect(retagging.rewrittenPlaylist(master, baseURL: base).contains("CODECS=\"hvc1.2.4.L120.90"))
        let plain = RemuxHLSLoader(restoresDolbyAtmos: true, dolbyVision: nil)
        #expect(plain.rewrittenPlaylist(master, baseURL: base).contains("CODECS=\"hev1.2.4.L120.90"))
    }

    // MARK: - Helpers

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + payload.count)
        return [UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)]
            + Array(type.utf8) + payload
    }

    /// An `hvcC` payload: 22 header bytes, then one array (one 4-byte NAL)
    /// per type in `arrays`.
    private func hvcC(arrays: [UInt8]) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 22)
        payload[0] = 1
        payload.append(UInt8(arrays.count))
        for type in arrays {
            payload += [type, 0, 1, 0, 4, type << 1, 1, 0xAA, 0xBB]
        }
        return payload
    }

    private func initSegment(entryType: String = "hev1", arrays: [UInt8]) -> [UInt8] {
        let entry = box(entryType, [UInt8](repeating: 0, count: 78) + box("hvcC", hvcC(arrays: arrays)) + box("pasp", [0, 0, 0, 1, 0, 0, 0, 1]))
        let stsd = box("stsd", [0, 0, 0, 0, 0, 0, 0, 1] + entry)
        let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd)))))
        return box("ftyp", Array("isom".utf8) + [0, 0, 0, 0]) + moov
    }

    private func contains(_ bytes: [UInt8], _ type: String) -> Bool {
        let needle = Array(type.utf8)
        return bytes.indices.dropLast(3).contains { Array(bytes[$0..<($0 + 4)]) == needle }
    }
}

private func streamsJSON(
    container: String,
    videoCodec: String,
    audioCodec: String,
    codecID: String?,
    subtitleCodec: String?
) -> String {
    let codecIDField = codecID.map { #", "codecID": "\#($0)""# } ?? ""
    let subtitle = subtitleCodec.map { #", { "id": 3, "streamType": 3, "codec": "\#($0)" }"# } ?? ""
    return """
    {
        "id": 10,
        "container": "\(container)",
        "videoCodec": "\(videoCodec)",
        "Part": [{
            "id": 20,
            "key": "/library/parts/20/file.\(container)",
            "container": "\(container)",
            "Stream": [
                { "id": 1, "streamType": 1, "codec": "\(videoCodec)", "bitDepth": 10, "profile": "main 10",
                  "width": 1920, "height": 960, "frameRate": 24\(codecIDField) },
                { "id": 2, "streamType": 2, "codec": "\(audioCodec)", "channels": 6 }\(subtitle)
            ]
        }]
    }
    """
}

private func makeMedia(
    container: String = "mp4",
    videoCodec: String = "hevc",
    audioCodec: String = "aac",
    codecID: String?,
    subtitleCodec: String? = nil
) throws -> MediaVersion {
    let json = streamsJSON(
        container: container, videoCodec: videoCodec, audioCodec: audioCodec,
        codecID: codecID, subtitleCodec: subtitleCodec
    )
    return try JSONDecoder().decode(MediaVersion.self, from: Data(json.utf8))
}

private func makeDetails() throws -> MediaDetails {
    let media = streamsJSON(container: "mp4", videoCodec: "hevc", audioCodec: "aac", codecID: nil, subtitleCodec: nil)
    let json = #"{ "ratingKey": "1", "key": "/library/metadata/1", "type": "movie", "title": "T", "Media": [\#(media)] }"#
    return try JSONDecoder().decode(MediaDetails.self, from: Data(json.utf8))
}
