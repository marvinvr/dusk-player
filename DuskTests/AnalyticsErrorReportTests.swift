import Foundation
import Testing
@testable import Dusk

@Suite("Error report sanitizing")
struct AnalyticsErrorSanitizingTests {
    @Test func frameworkAndTypeDomainsPass() {
        #expect(AnalyticsErrorSanitizer.domain("NSURLErrorDomain") == "NSURLErrorDomain")
        #expect(AnalyticsErrorSanitizer.domain("CoreMediaErrorDomain") == "CoreMediaErrorDomain")
        #expect(AnalyticsErrorSanitizer.domain("kCFErrorDomainCFNetwork") == "kCFErrorDomainCFNetwork")
        #expect(AnalyticsErrorSanitizer.domain("Dusk.PlexServiceError") == "Dusk.PlexServiceError")
    }

    @Test(arguments: [
        "plex.example.com",
        "192.168.1.20",
        "https://10.0.0.2:32400/library?X-Plex-Token=secret",
        "Marvins Plex Error",
        "user@example.com",
        "/var/mobile/Containers/Data/Movie.mkv",
        "",
        String(repeating: "A", count: 70) + "Error",
    ])
    func anythingElseBecomesOther(_ raw: String) {
        #expect(AnalyticsErrorSanitizer.domain(raw) == "other")
    }

    @Test func codecsAndContainersAreAllowlisted() {
        #expect(AnalyticsErrorSanitizer.container("MKV") == "mkv")
        #expect(AnalyticsErrorSanitizer.container("Some Movie (2020)") == "other")
        #expect(AnalyticsErrorSanitizer.container(nil) == nil)
        #expect(AnalyticsErrorSanitizer.videoCodec("hevc") == "hevc")
        #expect(AnalyticsErrorSanitizer.videoCodec("x-custom") == "other")
        #expect(AnalyticsErrorSanitizer.audioCodec("pcm_s24le") == "pcm")
        #expect(AnalyticsErrorSanitizer.audioCodec("truehd") == "truehd")
        #expect(AnalyticsErrorSanitizer.audioCodec("") == nil)
    }

    @Test func resolutionAndCountsAreBucketed() {
        #expect(AnalyticsErrorSanitizer.resolution(height: 480) == "sd")
        #expect(AnalyticsErrorSanitizer.resolution(height: 720) == "720p")
        #expect(AnalyticsErrorSanitizer.resolution(height: 1080) == "1080p")
        #expect(AnalyticsErrorSanitizer.resolution(height: 1608) == "4k")
        #expect(AnalyticsErrorSanitizer.resolution(height: 2160) == "4k")
        #expect(AnalyticsErrorSanitizer.resolution(height: nil) == nil)
        #expect(AnalyticsErrorSanitizer.bucket(7) == 7)
        #expect(AnalyticsErrorSanitizer.bucket(57) == 50)
        #expect(AnalyticsErrorSanitizer.bucket(1_234) == 1_000)
        #expect(AnalyticsErrorSanitizer.bucket(-3) == 0)
    }

    @Test func hdrFormatComesFromSignallingOnly() throws {
        func stream(_ json: String) throws -> PlexStream {
            try JSONDecoder().decode(PlexStream.self, from: Data(json.utf8))
        }
        #expect(AnalyticsErrorSanitizer.hdr(of: try stream(#"{"id":1,"streamType":1,"codec":"hevc","DOVIProfile":8,"DOVIBLCompatID":1}"#)) == "dv8.1")
        #expect(AnalyticsErrorSanitizer.hdr(of: try stream(#"{"id":1,"streamType":1,"codec":"hevc","DOVIProfile":5}"#)) == "dv5")
        #expect(AnalyticsErrorSanitizer.hdr(of: try stream(#"{"id":1,"streamType":1,"codec":"hevc","colorTrc":"smpte2084"}"#)) == "hdr10")
        #expect(AnalyticsErrorSanitizer.hdr(of: try stream(#"{"id":1,"streamType":1,"codec":"hevc","colorTrc":"arib-std-b67"}"#)) == "hlg")
        #expect(AnalyticsErrorSanitizer.hdr(of: try stream(#"{"id":1,"streamType":1,"codec":"h264","colorTrc":"bt709"}"#)) == "sdr")
    }

    /// The point of the whole design: nothing from `localizedDescription` or
    /// `userInfo` can reach the wire, even when it holds a URL and a token.
    @Test func capturedErrorsKeepOnlyDomainAndCode() {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12_938, userInfo: [
            NSLocalizedDescriptionKey: "plex.example.com refused /library/parts/1/file.mkv",
        ])
        let error = NSError(domain: AVFoundationErrorDomainForTests, code: -11_800, userInfo: [
            NSLocalizedDescriptionKey: "Failed https://10.0.0.2:32400/x?X-Plex-Token=secret",
            NSURLErrorFailingURLStringErrorKey: "https://10.0.0.2:32400/x?X-Plex-Token=secret",
            NSUnderlyingErrorKey: underlying,
        ])
        let report = AnalyticsErrorReport(.playbackEngineFailed, reason: .itemFailed, error: error)

        #expect(report.domain == "AVFoundationErrorDomain")
        #expect(report.code == -11_800)
        #expect(report.underlyingDomain == "NSOSStatusErrorDomain")
        #expect(report.underlyingCode == -12_938)
        let text = Self.flatten(report.properties)
        for leak in ["secret", "10.0.0.2", "plex.example.com", "file.mkv", "X-Plex-Token", "/library"] {
            #expect(!text.contains(leak), "leaked \(leak)")
        }
    }

    @Test func playbackErrorsReportTheirCaseNotTheirText() {
        let error = PlaybackError.networkError("https://my-server.example:32400/?X-Plex-Token=secret")
        let report = AnalyticsErrorReport(.playbackEngineFailed, reason: .engineError, error: error)
        #expect(report.kind == "network")
        #expect(report.domain == nil)
        #expect(!Self.flatten(report.properties).contains("secret"))
        #expect(!Self.flatten(report.properties).contains("my-server"))
    }

    @Test func messageIsBuiltFromSanitizedFields() {
        var report = AnalyticsErrorReport(.playbackStreamError)
        report.domain = AnalyticsErrorSanitizer.domain("CoreMediaErrorDomain")
        report.code = 404
        #expect(report.message == "playback_stream_error · CoreMediaErrorDomain 404")
    }

    @Test func signatureIgnoresTheMediaProfile() {
        var first = AnalyticsErrorReport(.droppedFrames, count: 300)
        first.media.engine = "vlckit"
        first.media.container = "mkv"
        var second = AnalyticsErrorReport(.droppedFrames, count: 900)
        second.media.engine = "vlckit"
        second.media.container = "mp4"
        #expect(first.signature == second.signature)
        var otherEngine = second
        otherEngine.media.engine = "avplayer"
        #expect(otherEngine.signature != first.signature)
    }

    /// Rybbit's `error` type rejects the event unless `properties` is a JSON
    /// string under 4 KB with a string `message`; it also takes only flat
    /// strings and numbers.
    @MainActor
    @Test func encodedPropertiesMatchRybbitsErrorSchema() throws {
        var report = AnalyticsErrorReport(
            .playbackStartFailed,
            reason: .allCandidatesFailed,
            error: URLError(.timedOut),
            count: 3
        )
        report.media = AnalyticsMediaProfile(
            engine: "avplayer", delivery: "remux", network: "remote", container: "mkv",
            videoCodec: "hevc", audioCodec: "eac3", hdr: "dv8.1", resolution: "4k"
        )
        let encoded = try #require(AnalyticsClient.encodedErrorProperties(for: report))
        #expect(encoded.utf8.count <= 4096)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(object["message"] is String)
        #expect(object.values.allSatisfy { $0 is String || $0 is NSNumber })

        let allowed: Set<String> = [
            "message", "reason", "kind", "domain", "code", "underlying_domain", "underlying_code",
            "count", "engine", "delivery", "network", "container", "video_codec", "audio_codec",
            "hdr", "resolution", "app_version", "platform", "os_version", "device_model",
        ]
        #expect(Set(object.keys).isSubset(of: allowed))
        #expect(object["domain"] as? String == "NSURLErrorDomain")
        #expect(object["code"] as? Int == URLError.timedOut.rawValue)
    }

    private static func flatten(_ properties: [String: AnalyticsValue]) -> String {
        properties.map { key, value in
            switch value {
            case let .string(string): "\(key)=\(string)"
            case let .int(int): "\(key)=\(int)"
            }
        }
        .joined(separator: " ")
    }
}

private let AVFoundationErrorDomainForTests = "AVFoundationErrorDomain"

@Suite("Error report rate limit")
struct AnalyticsErrorRateLimiterTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func theSameErrorGoesOutOncePerInterval() {
        var limiter = AnalyticsErrorRateLimiter(repeatInterval: 600, window: 3600, maxPerWindow: 20)
        do { let allowed = limiter.allow("a", now: start); #expect(allowed) }
        do { let allowed = limiter.allow("a", now: start.addingTimeInterval(1)); #expect(!allowed) }
        do { let allowed = limiter.allow("a", now: start.addingTimeInterval(599)); #expect(!allowed) }
        do { let allowed = limiter.allow("a", now: start.addingTimeInterval(600)); #expect(allowed) }
    }

    @Test func differentErrorsAreIndependent() {
        var limiter = AnalyticsErrorRateLimiter()
        do { let allowed = limiter.allow("a", now: start); #expect(allowed) }
        do { let allowed = limiter.allow("b", now: start); #expect(allowed) }
        do { let allowed = limiter.allow("a", now: start); #expect(!allowed) }
    }

    /// A loop that varies its error (a new code per retry) still cannot flood.
    @Test func everythingTogetherIsCappedPerWindow() {
        var limiter = AnalyticsErrorRateLimiter(repeatInterval: 600, window: 3600, maxPerWindow: 20)
        let sent = (0..<500).filter { limiter.allow("loop-\($0)", now: start.addingTimeInterval(Double($0))) }
        #expect(sent.count == 20)
        do { let allowed = limiter.allow("fresh", now: start.addingTimeInterval(3599)); #expect(!allowed) }
        // The window slides: the first report has aged out an hour later.
        do { let allowed = limiter.allow("fresh", now: start.addingTimeInterval(3600)); #expect(allowed) }
    }
}

@Suite("Dropped frame threshold")
struct DroppedFrameThresholdTests {
    @Test func needsBothAbsoluteCountAndRatio() {
        #expect(!DroppedFrameThreshold.isExceeded(dropped: 100, displayed: 100))
        #expect(!DroppedFrameThreshold.isExceeded(dropped: 200, displayed: 10_000))
        #expect(DroppedFrameThreshold.isExceeded(dropped: 200, displayed: 1_000))
    }

    @Test func avPlayerEstimatesFromWatchedTime() {
        // 60 s at 24 fps ≈ 1440 frames; 150 dropped ≈ 10 %.
        #expect(DroppedFrameThreshold.isExceeded(dropped: 150, watchedSeconds: 60))
        // An hour with 150 dropped is noise.
        #expect(!DroppedFrameThreshold.isExceeded(dropped: 150, watchedSeconds: 3600))
        #expect(!DroppedFrameThreshold.isExceeded(dropped: 500, watchedSeconds: 0))
    }
}
