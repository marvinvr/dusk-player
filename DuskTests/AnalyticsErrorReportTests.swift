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
        func stream(_ json: String) throws -> MediaStream {
            try JSONDecoder().decode(MediaStream.self, from: Data(json.utf8))
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
            "http_status", "outcome", "server_version", "tried", "failed",
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

@Suite("Error report causes and new fields")
@MainActor
struct AnalyticsErrorCauseTests {
    private func value(_ report: AnalyticsErrorReport, _ key: String) -> String? {
        switch report.properties[key] {
        case let .string(string): string
        case let .int(int): String(int)
        case nil: nil
        }
    }

    @Test func loadFailuresKeepTheirCauseNextToThePlaybackError() {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSURLErrorFailingURLStringErrorKey: "https://10.0.0.2:32400/library/parts/1/file.mkv?X-Plex-Token=secret",
        ])
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSUnderlyingErrorKey: underlying,
            NSLocalizedDescriptionKey: "Couldn't open Movie (2020).mkv",
        ])
        let report = AnalyticsErrorReport(
            .playbackEngineFailed, reason: .loadFailed,
            playbackError: .unknown("Couldn't open Movie (2020).mkv"),
            cause: AnalyticsErrorCause(error: error)
        )
        #expect(report.domain == "AVFoundationErrorDomain")
        #expect(report.code == -11800)
        #expect(report.underlyingDomain == NSURLErrorDomain)
        #expect(report.underlyingCode == NSURLErrorTimedOut)
        // -11800 says nothing; the underlying timeout does.
        #expect(report.kind == "timeout")
        let encoded = AnalyticsClient.encodedErrorProperties(for: report) ?? ""
        #expect(!encoded.contains("Movie"))
        #expect(!encoded.contains("10.0.0.2"))
        #expect(!encoded.contains("secret"))
    }

    @Test func anHTTPStatusRefinesAnUnknownKind() {
        let report = AnalyticsErrorReport(
            .playbackEngineFailed, reason: .loadFailed,
            playbackError: .unknown("<html>Service Unavailable on plex.example.com</html>"),
            cause: .http(503)
        )
        #expect(report.kind == "http_5xx")
        #expect(report.httpStatus == 503)
        #expect(value(report, "http_status") == "503")
        #expect(report.message == "load_failed · http_5xx · HTTP 503")
        #expect(AnalyticsErrorSanitizer.kind(of: .http(404)) == .http4xx)
        #expect(AnalyticsErrorSanitizer.kind(of: .http(302)) == .httpOther)
    }

    @Test func aKnownPlaybackErrorCaseIsNotOverridden() {
        let report = AnalyticsErrorReport(
            .playbackEngineFailed, reason: .loadFailed,
            playbackError: .sourceUnavailable, cause: .http(404)
        )
        #expect(report.kind == "source_unavailable")
        #expect(report.httpStatus == 404)
    }

    @Test func thePathsOwnKindWins() {
        let keyError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let report = AnalyticsErrorReport(
            .playbackEngineFailed, reason: .loadFailed,
            playbackError: .unknown("FairPlay license server said no"),
            cause: AnalyticsErrorCause(error: keyError, kind: .drm)
        )
        #expect(report.kind == "drm")
        #expect(report.domain == NSURLErrorDomain)
    }

    @Test func wellKnownCodesMapToKinds() {
        func kind(_ domain: String, _ code: Int) -> AnalyticsErrorKind? {
            AnalyticsErrorSanitizer.kind(of: AnalyticsErrorCause(domain: domain, code: code))
        }
        #expect(kind(NSURLErrorDomain, NSURLErrorServerCertificateUntrusted) == .tls)
        #expect(kind(NSURLErrorDomain, NSURLErrorAppTransportSecurityRequiresSecureConnection) == .transportPolicy)
        #expect(kind(NSURLErrorDomain, NSURLErrorCannotConnectToHost) == .network)
        #expect(kind("AVFoundationErrorDomain", -11821) == .decode)
        #expect(kind("AVFoundationErrorDomain", -11828) == .unsupportedMedia)
        #expect(kind("AVFoundationErrorDomain", -11819) == .mediaServicesReset)
        #expect(kind("AVFoundationErrorDomain", -11800) == nil)
        #expect(kind("CoreMediaErrorDomain", -12938) == nil)
    }

    @Test func aCauseSanitizesItsDomains() {
        let cause = AnalyticsErrorCause(domain: "plex.example.com", code: 1, underlyingDomain: "192.168.1.2", underlyingCode: 2)
        #expect(cause.domain == "other")
        #expect(cause.underlyingDomain == "other")
        #expect(AnalyticsErrorCause(error: PlaybackError.unknown("x")).domain == nil)
    }

    @Test(arguments: [
        ("1.43.0.10162-a1b2c3d4e", "1.43.0"),
        ("1.41.9.9961-46083195d", "1.41.9"),
        ("1.32.5", "1.32.5"),
        ("01.040.003.1", "1.40.3"),
    ])
    func serverVersionKeepsMajorMinorPatchOnly(_ raw: String, _ expected: String) {
        #expect(AnalyticsErrorSanitizer.serverVersion(raw) == expected)
    }

    @Test func anythingElseIsNotAServerVersion() {
        #expect(AnalyticsErrorSanitizer.serverVersion(nil) == nil)
        #expect(AnalyticsErrorSanitizer.serverVersion("  ") == nil)
        #expect(AnalyticsErrorSanitizer.serverVersion("Marvins Server 1.43.0") == "other")
        #expect(AnalyticsErrorSanitizer.serverVersion("1.43") == "other")
        #expect(AnalyticsErrorSanitizer.serverVersion("1.43.0abc") == "other")
        #expect(AnalyticsErrorSanitizer.serverVersion("1234.1.1") == "other")
    }

    @Test func streamOutcomeDecision() {
        #expect(AnalyticsStreamOutcome.evaluate(failed: true, advanced: 30, wantsToPlay: true) == .fatal)
        #expect(AnalyticsStreamOutcome.evaluate(failed: false, advanced: 9.5, wantsToPlay: true) == .recovered)
        #expect(AnalyticsStreamOutcome.evaluate(failed: false, advanced: 0.2, wantsToPlay: true) == .stalled)
        #expect(AnalyticsStreamOutcome.evaluate(failed: false, advanced: 0, wantsToPlay: false) == .paused)
    }

    @Test func streamOutcomeIsSentAndPartOfTheSignature() {
        var recovered = AnalyticsErrorReport(.playbackStreamError)
        recovered.domain = "CoreMediaErrorDomain"
        recovered.code = -12938
        var fatal = recovered
        recovered.outcome = .recovered
        fatal.outcome = .fatal
        #expect(value(recovered, "outcome") == "recovered")
        #expect(recovered.signature != fatal.signature)
        #expect(fatal.message == "playback_stream_error · CoreMediaErrorDomain -12938 · fatal")
    }

    @Test func connectionClassesAreBucketsOnly() {
        #expect(AnalyticsErrorSanitizer.connectionClass(locality: .local, isSecure: true, host: "192-168-1-2.abcdef.plex.direct") == "lan_plex_direct_https")
        #expect(AnalyticsErrorSanitizer.connectionClass(locality: .tailnet, isSecure: false, host: "storage") == "tailscale_http")
        #expect(AnalyticsErrorSanitizer.connectionClass(locality: .remote, isSecure: true, host: "plex.example.com") == "remote_https")
        #expect(AnalyticsErrorSanitizer.connectionClass(locality: .relay, isSecure: true, host: nil) == "relay_https")
        #expect(AnalyticsErrorSanitizer.connectionClasses(["remote_https", "lan_http", "remote_https"]) == "lan_http,remote_https")
        #expect(AnalyticsErrorSanitizer.connectionClasses([]) == nil)
    }

    @Test func connectionFailedReportsClassesAndTheBestRankedFailure() throws {
        func entry(_ id: Int, _ url: String, _ locality: ConnectionLocality, _ outcome: ConnectionProbeOutcome) throws -> ConnectionReport.Entry {
            let url = try #require(URL(string: url))
            return ConnectionReport.Entry(
                id: id, url: url, locality: locality, isSecure: url.scheme == "https",
                source: .plex, outcome: outcome, isChosen: false
            )
        }
        let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let selection = ConnectionReport(
            serverID: "abcdef0123456789", serverName: "Marvins Plex", trigger: "Connect",
            startedAt: .now, duration: 1,
            entries: [
                try entry(0, "https://82-1-2-3.abcdef.plex.direct:32400", .remote, .failed("Timed out", cause: AnalyticsErrorCause(error: timedOut))),
                try entry(1, "https://192-168-1-2.abcdef.plex.direct:32400", .local, .failed("Connection refused", cause: AnalyticsErrorCause(error: refused))),
                try entry(2, "http://192.168.1.2:32400", .local, .failed("HTTP 503", cause: .http(503))),
                try entry(3, "https://relay.abcdef.plex.direct:8443", .relay, .wrongServer(nil)),
            ],
            chosenURL: nil, result: "Nothing reachable"
        )
        let report = selection.errorReport(reason: .unreachable, serverVersion: "1.43.0.10162-a1b2c3d4e")
        #expect(report.count == 4)
        #expect(report.triedConnections == "lan_http,lan_plex_direct_https,relay_plex_direct_https,remote_plex_direct_https")
        #expect(report.failedConnections == report.triedConnections)
        // LAN https outranks LAN http, remote and the relay.
        #expect(report.domain == NSURLErrorDomain)
        #expect(report.code == NSURLErrorCannotConnectToHost)
        #expect(report.kind == "network")
        #expect(report.serverVersion == "1.43.0")

        let encoded = try #require(AnalyticsClient.encodedErrorProperties(for: report))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(object.values.allSatisfy { $0 is String || $0 is NSNumber })
        #expect(object["tried"] as? String == report.triedConnections)
        #expect(object["server_version"] as? String == "1.43.0")
        #expect(!encoded.contains("192"))
        #expect(!encoded.contains("abcdef"))
        #expect(!encoded.contains("Marvins"))
        #expect(!encoded.contains("10162"))
    }

    @Test func aConnectionWhoseOnlyFailuresAreHTTPReportsTheStatus() throws {
        let url = try #require(URL(string: "https://plex.example.com"))
        let selection = ConnectionReport(
            serverID: "x", serverName: "x", trigger: "Connect", startedAt: .now, duration: 1,
            entries: [ConnectionReport.Entry(
                id: 0, url: url, locality: .remote, isSecure: true, source: .plex,
                outcome: .failed("HTTP 502", cause: .http(502)), isChosen: false
            )],
            chosenURL: nil, result: "Nothing reachable"
        )
        let report = selection.errorReport(reason: .unreachable, serverVersion: nil)
        #expect(report.httpStatus == 502)
        #expect(report.kind == "http_5xx")
        #expect(report.domain == nil)
        #expect(report.serverVersion == nil)
        #expect(report.failedConnections == "remote_https")
    }
}
