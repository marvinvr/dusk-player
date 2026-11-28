import Foundation
import Testing
@testable import Dusk

@Suite("Dolby Vision 7 playlist rewrite")
struct DolbyVision7PlaylistTests {
    private let masterURL = URL(string: "https://plex.example:32400/video/:/transcode/universal/start.m3u8?X-Plex-Token=secret&session=xyz")!
    private let mediaURL = URL(string: "https://plex.example:32400/video/:/transcode/universal/session/abc/base/index.m3u8?X-Plex-Token=tok")!
    private let subtitlesURL = URL(string: "https://plex.example:32400/video/:/transcode/universal/session/abc/subs/index.m3u8")!

    private let mapper = DolbyVision7PlaylistRewriter.URLMapper(
        playlist: { playlist, isVideo in proxied(isVideo ? "v" : "p", playlist) },
        initSegment: { proxied("i", $0) },
        mediaSegment: { segment, initSegment in initSegment.map { proxied("s", segment, initSegment: $0) } ?? segment }
    )

    /// 4K24 at 20 Mbit/s, so the HEVC level cap applies.
    private let target = DolbyVisionConfiguration(
        profile: 7, level: 6, blSignalCompatibilityID: 6,
        lumaSampleRate: 3840 * 2160 * 23.976, lumaPictureSize: 3840 * 2160, bitrateKbps: 20_000
    ).convertedToProfile81()

    @Test func masterVariantGainsProfile81SignalingAndIsMapped() throws {
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="session/abc/subs/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=60000000,CODECS="hvc1.2.4.L156.b0,ec-3",RESOLUTION=3840x2160,SUBTITLES="subs"
        session/abc/base/index.m3u8?X-Plex-Token=tok
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,CODECS="hvc1.2.4.L156.b0",URI="iframes.m3u8"

        """
        let expected = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="\(proxied("p", subtitlesURL).absoluteString)"
        #EXT-X-STREAM-INF:BANDWIDTH=60000000,CODECS="hvc1.2.4.L153.b0,ec-3",RESOLUTION=3840x2160,SUBTITLES="subs",SUPPLEMENTAL-CODECS="dvh1.08.06/db1p",VIDEO-RANGE=PQ
        \(proxied("v", mediaURL).absoluteString)

        """
        #expect(try rewrite(master, baseURL: masterURL) == expected)
        #expect(try rewrite(master.replacingOccurrences(of: "\n", with: "\r\n"), baseURL: masterURL) == expected)
    }

    @Test func mediaSegmentsCarryTheInitSegmentInEffect() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="header"
        #EXTINF:6.006,
        0.m4s
        #EXTINF:6.006,
        1.m4s?extra=1
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="header2"
        #EXTINF:2.002,
        2.m4s
        #EXT-X-ENDLIST
        """
        let base = "https://plex.example:32400/video/:/transcode/universal/session/abc/base/"
        let header = URL(string: base + "header")!
        let header2 = URL(string: base + "header2")!
        let expected = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="\(proxied("i", header).absoluteString)"
        #EXTINF:6.006,
        \(proxied("s", URL(string: base + "0.m4s")!, initSegment: header).absoluteString)
        #EXTINF:6.006,
        \(proxied("s", URL(string: base + "1.m4s?extra=1")!, initSegment: header).absoluteString)
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="\(proxied("i", header2).absoluteString)"
        #EXTINF:2.002,
        \(proxied("s", URL(string: base + "2.m4s")!, initSegment: header2).absoluteString)
        #EXT-X-ENDLIST

        """
        #expect(try rewrite(playlist, baseURL: mediaURL) == expected)
    }

    @Test func segmentsWithoutInitSegmentGetNone() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:6.0,
        sub0.vtt
        #EXT-X-ENDLIST
        """
        let output = try rewrite(playlist, baseURL: subtitlesURL)
        #expect(output.contains("\nhttps://plex.example:32400/video/:/transcode/universal/session/abc/subs/sub0.vtt\n"))
        #expect(output.contains("#EXT-X-KEY:METHOD=NONE"))
    }

    @Test func videoPlaylistSegmentsNeedAnInitSegment() throws {
        // A segment ahead of the first EXT-X-MAP of an fMP4 playlist.
        let beforeMap = "#EXTM3U\n#EXTINF:6.0,\nlead.m4s\n#EXT-X-MAP:URI=\"header\"\n#EXTINF:6.0,\n0.m4s\n"
        #expect(isUnsupportedPlaylist { try rewrite(beforeMap, baseURL: mediaURL) })

        // A video variant without any EXT-X-MAP (MPEG-TS) never converts.
        let transportStream = "#EXTM3U\n#EXTINF:6.0,\n0.ts\n#EXT-X-ENDLIST\n"
        #expect(isUnsupportedPlaylist {
            try DolbyVision7PlaylistRewriter.rewrite(
                transportStream, baseURL: mediaURL, target: target, requiresInitSegment: true, mapper: mapper)
        })
        // The same playlist as a rendition (no conversion) is passed on.
        #expect(try rewrite(transportStream, baseURL: subtitlesURL).contains("/subs/0.ts\n"))
    }

    @Test func mapperFailuresAbortTheRewrite() {
        let refusing = DolbyVision7PlaylistRewriter.URLMapper(
            playlist: { playlist, _ in playlist },
            initSegment: { _ in throw DolbyVision7ConversionError.unsupportedPlaylist("off origin") },
            mediaSegment: { segment, _ in segment }
        )
        let playlist = "#EXTM3U\n#EXT-X-MAP:URI=\"header\"\n#EXTINF:6.0,\n0.m4s\n"
        #expect(isUnsupportedPlaylist {
            try DolbyVision7PlaylistRewriter.rewrite(playlist, baseURL: mediaURL, target: target, mapper: refusing)
        })
    }

    @Test func videoRenditionsAreMappedAsVideo() throws {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="v",NAME="Main",URI="alt/index.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="session/abc/subs/index.m3u8"
        """
        let output = try rewrite(master, baseURL: masterURL)
        #expect(output.contains(proxied("v", URL(string: "https://plex.example:32400/video/:/transcode/universal/alt/index.m3u8")!).absoluteString))
        #expect(output.contains(proxied("p", subtitlesURL).absoluteString))
    }

    @Test func byteRangesAndEncryptionThrow() {
        let byteRange = "#EXTM3U\n#EXT-X-MAP:URI=\"header\"\n#EXTINF:6.0,\n#EXT-X-BYTERANGE:1000@0\n0.m4s\n"
        let mapByteRange = "#EXTM3U\n#EXT-X-MAP:URI=\"header\",BYTERANGE=\"1000@0\"\n#EXTINF:6.0,\n0.m4s\n"
        let encrypted = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-MAP:URI=\"header\"\n#EXTINF:6.0,\n0.m4s\n"
        let lowLatencyPart = "#EXTM3U\n#EXT-X-MAP:URI=\"header\"\n#EXT-X-PART:DURATION=1.0,URI=\"0.1.m4s\"\n#EXTINF:6.0,\n0.m4s\n"
        for playlist in [byteRange, mapByteRange, encrypted, lowLatencyPart] {
            #expect(isUnsupportedPlaylist { try rewrite(playlist, baseURL: mediaURL) })
        }
    }

    @Test func variantsThatCannotCarryProfile81Throw() {
        let hev1 = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"hev1.2.4.L153.b0,ec-3\"\nindex.m3u8\n"
        let profile7Codec = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"dvh1.07.06,ec-3\"\nindex.m3u8\n"
        let noCodecs = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nindex.m3u8\n"
        for playlist in [hev1, profile7Codec, noCodecs] {
            #expect(isUnsupportedPlaylist { try rewrite(playlist, baseURL: masterURL) })
        }
    }

    @Test func profile7ConvertsToProfile81() {
        #expect(target.profile == 8)
        #expect(target.blSignalCompatibilityID == 1)
        #expect(target.level == 6)
        #expect(target.convertedFromProfile == 7)
        #expect(target.supplementalCodecString == "dvh1.08.06/db1p")
        #expect(target.displayName == "Dolby Vision 8.1 (from profile 7)")
        // `lumaPictureSize` is `Double?`. Comparing it with the `Int`
        // `3840 * 2160` is false under Swift Testing even when both are 8294400.
        #expect(target.lumaPictureSize == Double?(Double(3840 * 2160)))
        #expect(target.bitrateKbps == 20_000)
    }

    @Test func masterWithoutCodecsTakesTheFallbackAndConverts() throws {
        // What PMS actually serves for a remux: no CODECS attribute at all.
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=64473000,RESOLUTION=3840x2160,FRAME-RATE=23.976000,VIDEO-RANGE=PQ
        session/abc/base/index.m3u8?X-Plex-Token=tok

        """
        #expect(isUnsupportedPlaylist { try rewrite(master, baseURL: masterURL) })
        let rewritten = try DolbyVision7PlaylistRewriter.rewrite(
            master, baseURL: masterURL, target: target,
            fallbackCodecs: "hvc1.2.4.L156.b0,ec-3", mapper: mapper
        )
        let line = try #require(rewritten.components(separatedBy: "\n").first { $0.hasPrefix("#EXT-X-STREAM-INF") })
        #expect(line.contains(#"CODECS="hvc1.2.4.L153.b0,ec-3""#))
        #expect(line.contains(#"SUPPLEMENTAL-CODECS="dvh1.08.06/db1p""#))
        #expect(line.contains("VIDEO-RANGE=PQ"))
    }

    @Test func hev1FallbackStillRefusesConversion() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=64473000,RESOLUTION=3840x2160,VIDEO-RANGE=PQ
        session/abc/base/index.m3u8

        """
        #expect(isUnsupportedPlaylist {
            try DolbyVision7PlaylistRewriter.rewrite(
                master, baseURL: masterURL, target: target,
                fallbackCodecs: "hev1.2.4.L153.b0,ec-3", mapper: mapper
            )
        })
    }

    @Test func plexReportedConfigurationIsNotConverted() throws {
        let json = """
        { "id": 1, "streamType": 1, "codec": "hevc", "DOVIPresent": true,
          "DOVIProfile": 8, "DOVILevel": 6, "DOVIBLCompatID": 1 }
        """
        let stream = try JSONDecoder().decode(MediaStream.self, from: Data(json.utf8))
        let configuration = try #require(DolbyVisionConfiguration(stream: stream))
        #expect(configuration.convertedFromProfile == nil)
        #expect(configuration.displayName == "Dolby Vision 8.1")
    }

    // MARK: - Helpers

    private func rewrite(_ text: String, baseURL: URL) throws -> String {
        try DolbyVision7PlaylistRewriter.rewrite(text, baseURL: baseURL, target: target, mapper: mapper)
    }

    private func isUnsupportedPlaylist(_ body: () throws -> String) -> Bool {
        do {
            _ = try body()
            return false
        } catch DolbyVision7ConversionError.unsupportedPlaylist {
            return true
        } catch {
            return false
        }
    }
}

/// A stand-in proxy URL that spells out what was mapped.
private func proxied(_ kind: String, _ url: URL, initSegment: URL? = nil) -> URL {
    var components = URLComponents(string: "http://127.0.0.1:8080/token/\(kind)")!
    components.queryItems = [URLQueryItem(name: "u", value: url.absoluteString)]
        + (initSegment.map { [URLQueryItem(name: "init", value: $0.absoluteString)] } ?? [])
    return components.url!
}
