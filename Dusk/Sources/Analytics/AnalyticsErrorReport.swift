import Foundation

/// The complete vocabulary of error reports. Like `AnalyticsEventName`, a
/// report can only be one of these; it goes over the wire as a Rybbit `error`
/// event whose name is the raw value. See `docs/analytics.md` → Error reports.
enum AnalyticsErrorCategory: String, CaseIterable, Sendable {
    /// No server could start the item: the viewer saw the error screen.
    /// `reason`: `remote_refused` or `all_candidates_failed`; `count`: servers tried.
    case playbackStartFailed = "playback_start_failed"
    /// A running engine entered its error state (AVPlayer item failed, VLCKit
    /// error, a load that never validated). The ladder may still recover.
    case playbackEngineFailed = "playback_engine_failed"
    /// An AVPlayer error-log entry: a segment or playlist fetch AVPlayer
    /// rejected, usually an HTTP status or CoreMedia code.
    case playbackStreamError = "playback_stream_error"
    /// AVPlayer ran out of buffer while playing.
    case playbackStalled = "playback_stalled"
    /// Playback made no progress for 12 s and the player reloaded the item.
    /// `count`: recovery attempt (1 or 2).
    case playbackStallRecovery = "playback_stall_recovery"
    /// A decoder or converter could not run: `truehd` (VLCKit could not open
    /// it) or `dv7_conversion` (Dolby Vision 7 → 8.1 failed mid-stream).
    case decoderFailed = "decoder_failed"
    /// The engine dropped frames above the threshold
    /// (`DroppedFrameThreshold`). `count`: dropped frames, bucketed.
    case droppedFrames = "dropped_frames"
    /// The automatic delivery ladder moved a failed session to another rung.
    /// `reason` names the rung.
    case engineFallback = "engine_fallback"
    /// The ladder had nowhere left to go: the error screen stays up.
    case engineFallbackFailed = "engine_fallback_failed"
    /// Plex refused or failed a transcode/stream session. `reason` names which.
    case transcodeFailed = "transcode_failed"
    /// A download ended in the failed state. `reason`: the stage.
    case downloadFailed = "download_failed"
    /// Sign-in could not complete. `reason`: `pin_request` or `timeout`.
    case signInFailed = "sign_in_failed"
    /// A server had no usable connection. `reason`: `unreachable` or
    /// `unauthorized`; `count`: connection candidates tried.
    case connectionFailed = "connection_failed"

    /// Synthetic path, like the usage events: groups errors by area in Rybbit.
    var path: String {
        switch self {
        case .downloadFailed: "/downloads"
        case .signInFailed: "/sign-in"
        case .connectionFailed: "/connection"
        default: "/player"
        }
    }

    /// Playback categories carry the playing media's profile.
    var isPlayback: Bool {
        switch self {
        case .downloadFailed, .signInFailed, .connectionFailed: false
        default: true
        }
    }
}

/// Fixed sub-reasons. Never free text: only these spellings can be sent.
enum AnalyticsErrorReason: String, Sendable {
    // playback_start_failed
    case remoteRefused = "remote_refused"
    case allCandidatesFailed = "all_candidates_failed"
    // playback_engine_failed
    case itemFailed = "item_failed"
    case loadFailed = "load_failed"
    case engineError = "engine_error"
    // decoder_failed
    case trueHD = "truehd"
    case dolbyVision7Conversion = "dv7_conversion"
    // engine_fallback
    case av1ServerStream = "av1_server_stream"
    case dolbyVision7ConversionRetry = "dv7_conversion_retry"
    case hdrRemuxRecovery = "hdr_remux_recovery"
    case remuxToDirectPlay = "remux_to_direct_play"
    case directPlayToServerStream = "direct_play_to_server_stream"
    case liveTVTranscode = "live_tv_transcode"
    case remoteRefusalToLocal = "remote_refusal_to_local"
    // engine_fallback_failed / transcode_failed
    case serverStreamUnavailable = "server_stream_unavailable"
    case serverStreamRequestFailed = "server_stream_request_failed"
    case qualitySwitch = "quality_switch"
    case airPlay = "airplay"
    // download_failed
    case prepare
    case transfer
    case finalize
    case validate
    // sign_in_failed
    case pinRequest = "pin_request"
    case timeout
    // connection_failed
    case unreachable
    case unauthorized
}

/// The anonymous technical profile of what was playing. Every field is a
/// bucket or an allowlisted token, never a value read verbatim from Plex.
struct AnalyticsMediaProfile: Sendable, Equatable {
    var engine: String?
    var delivery: String?
    var network: String?
    var container: String?
    var videoCodec: String?
    var audioCodec: String?
    var hdr: String?
    var resolution: String?
}

/// One error report. Built only through typed fields; `properties` is the
/// complete list of what leaves the device besides the shared envelope
/// (`app_version`, `platform`, `os_version`, `device_model`, `language`).
struct AnalyticsErrorReport: Sendable, Equatable {
    let category: AnalyticsErrorCategory
    var reason: AnalyticsErrorReason?
    /// `PlaybackError` case, e.g. `network`, `source_unavailable`.
    var kind: String?
    var domain: String?
    var code: Int?
    var underlyingDomain: String?
    var underlyingCode: Int?
    var count: Int?
    var media = AnalyticsMediaProfile()

    init(
        _ category: AnalyticsErrorCategory,
        reason: AnalyticsErrorReason? = nil,
        error: (any Error)? = nil,
        count: Int? = nil
    ) {
        self.category = category
        self.reason = reason
        self.count = count
        if let error { capture(error) }
    }

    /// Takes the error's domain and code (and its underlying error's) and
    /// nothing else: `localizedDescription` and `userInfo` can carry URLs,
    /// hostnames, paths and file names, so they are never read.
    mutating func capture(_ error: any Error) {
        if let playbackError = error as? PlaybackError {
            kind = AnalyticsErrorSanitizer.kind(of: playbackError)
            return
        }
        let nsError = error as NSError
        domain = AnalyticsErrorSanitizer.domain(nsError.domain)
        code = nsError.code
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            underlyingDomain = AnalyticsErrorSanitizer.domain(underlying.domain)
            underlyingCode = underlying.code
        }
    }

    /// What makes two reports "the same error" for rate limiting. Media is
    /// left out on purpose: a loop on one file must collapse to one report.
    var signature: String {
        [
            category.rawValue, reason?.rawValue, kind, media.engine,
            domain, code.map(String.init), underlyingDomain, underlyingCode.map(String.init),
        ]
        .map { $0 ?? "-" }
        .joined(separator: "|")
    }

    /// Rybbit's error dashboard groups by event name and `message`, which it
    /// requires. Built from the sanitized fields only.
    var message: String {
        var parts = [reason?.rawValue ?? category.rawValue]
        if let kind { parts.append(kind) }
        if let domain { parts.append("\(domain) \(code.map(String.init) ?? "?")") }
        if let underlyingDomain {
            parts.append("← \(underlyingDomain) \(underlyingCode.map(String.init) ?? "?")")
        }
        return parts.joined(separator: " · ")
    }

    var properties: [String: AnalyticsValue] {
        var result: [String: AnalyticsValue] = ["message": .string(message)]
        func put(_ key: String, _ value: String?) {
            if let value { result[key] = .string(value) }
        }
        put("reason", reason?.rawValue)
        put("kind", kind)
        put("domain", domain)
        if let code { result["code"] = .int(code) }
        put("underlying_domain", underlyingDomain)
        if let underlyingCode { result["underlying_code"] = .int(underlyingCode) }
        if let count { result["count"] = .int(AnalyticsErrorSanitizer.bucket(count)) }
        put("engine", media.engine)
        put("delivery", media.delivery)
        put("network", media.network)
        put("container", media.container)
        put("video_codec", media.videoCodec)
        put("audio_codec", media.audioCodec)
        put("hdr", media.hdr)
        put("resolution", media.resolution)
        return result
    }
}

/// Allowlists and buckets. Anything that does not match comes out as
/// `other`, so an unexpected value can never carry identifying text.
enum AnalyticsErrorSanitizer {
    static let other = "other"

    private static let knownDomains: Set<String> = [
        "NSURLErrorDomain", "NSOSStatusErrorDomain", "NSPOSIXErrorDomain", "NSCocoaErrorDomain",
        "AVFoundationErrorDomain", "CoreMediaErrorDomain", "AVKitErrorDomain",
        "kCFErrorDomainCFNetwork", "NSMachErrorDomain", "SKErrorDomain",
    ]

    /// An error domain is a type name, never data, when it looks like one:
    /// identifier characters only and an `…Error`/`…ErrorDomain` suffix, or
    /// a known framework domain. A host name (`plex.example.com`) fails the
    /// suffix rule, anything with a space, slash, colon or `@` fails the
    /// character rule.
    static func domain(_ raw: String) -> String {
        guard !raw.isEmpty, raw.count <= 64,
              raw.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*$"#, options: .regularExpression) != nil else {
            return other
        }
        if knownDomains.contains(raw) { return raw }
        if raw.hasSuffix("ErrorDomain") || raw.hasSuffix("Error") { return raw }
        return other
    }

    private static let containers: Set<String> = [
        "mkv", "mp4", "mov", "m4v", "avi", "ts", "mpegts", "m2ts", "webm", "wmv", "asf",
        "flv", "ogg", "mpeg", "mpg", "vob", "hls", "mka", "m4a", "3gp",
    ]
    private static let videoCodecs: Set<String> = [
        "h264", "hevc", "h265", "av1", "vp9", "vp8", "mpeg2video", "mpeg4", "mpeg1video",
        "vc1", "wmv3", "wmv2", "msmpeg4v3", "h263", "mjpeg", "prores", "theora",
    ]
    private static let audioCodecs: Set<String> = [
        "aac", "ac3", "eac3", "dts", "dca", "truehd", "mlp", "flac", "mp3", "mp2", "opus",
        "vorbis", "pcm", "alac", "wmapro", "wmav2", "wmav1",
    ]

    static func container(_ raw: String?) -> String? { token(raw, allowed: containers) }
    static func videoCodec(_ raw: String?) -> String? { token(raw, allowed: videoCodecs) }

    static func audioCodec(_ raw: String?) -> String? {
        // Plex spells PCM per sample format (pcm_s16le, pcm_s24le, …).
        if let raw, raw.lowercased().hasPrefix("pcm") { return "pcm" }
        return token(raw, allowed: audioCodecs)
    }

    private static func token(_ raw: String?, allowed: Set<String>) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        return allowed.contains(raw) ? raw : other
    }

    /// `sd`, `720p`, `1080p`, `1440p`, `4k`, `8k` from the picture height.
    static func resolution(height: Int?) -> String? {
        guard let height, height > 0 else { return nil }
        switch height {
        case ...576: return "sd"
        case ...800: return "720p"
        case ...1200: return "1080p"
        case ...1600: return "1440p"
        case ...2400: return "4k"
        default: return "8k"
        }
    }

    /// `sdr`, `hdr10`, `hlg`, `hdr`, or `dv<profile>[.<compat>]` from the
    /// video stream's signalling. Profile and compatibility ID are small
    /// integers, so only those digits make it into the string.
    static func hdr(of stream: PlexStream?) -> String? {
        guard let stream else { return nil }
        if let profile = stream.doviProfile, (0...10).contains(profile) {
            if let compat = stream.doviBLCompatID, (0...10).contains(compat) {
                return "dv\(profile).\(compat)"
            }
            return "dv\(profile)"
        }
        switch StreamResolver.hdrTransfer(of: stream) {
        case .pq: return "hdr10"
        case .hlg: return "hlg"
        case nil: return stream.isHDRVideo ? "hdr" : "sdr"
        }
    }

    static func delivery(_ decision: PlaybackDecision) -> String {
        switch decision {
        case .directPlay: "direct_play"
        case .localDownload: "download"
        case .transcode: "transcode"
        case .serverStream: "server_stream"
        case .airPlay: "airplay"
        case .liveTV: "live_tv"
        case .spatialAudio: "remux"
        }
    }

    static func engine(_ type: PlaybackEngineType) -> String {
        switch type {
        case .avPlayer: "avplayer"
        case .vlcKit: "vlckit"
        }
    }

    static func network(_ locality: PlaybackSourceLocality) -> String {
        switch locality {
        case .localFile: "file"
        case .localNetwork: "lan"
        case .remoteNetwork: "remote"
        }
    }

    /// `PlaybackError`'s case, never its associated text.
    static func kind(of error: PlaybackError) -> String {
        switch error {
        case .unsupportedFormat: "unsupported_format"
        case .sourceUnavailable: "source_unavailable"
        case .networkError: "network"
        case .serverUnreachable: "server_unreachable"
        case .unauthorized: "unauthorized"
        case .unknown: "unknown"
        }
    }

    /// Counts are bucketed so they describe magnitude, not a fingerprint.
    static func bucket(_ count: Int) -> Int {
        switch count {
        case ..<0: 0
        case 0...10: count
        case ...100: (count / 10) * 10
        case ...1_000: (count / 100) * 100
        default: (count / 1_000) * 1_000
        }
    }

    /// The technical profile of a playing item, from Plex metadata only
    /// through the allowlists above.
    static func profile(
        engine: PlaybackEngineType?,
        decision: PlaybackDecision?,
        locality: PlaybackSourceLocality?,
        media: PlexMedia?,
        part: PlexMediaPart?
    ) -> AnalyticsMediaProfile {
        let video = part?.streams.first { $0.streamType == .video }
        return AnalyticsMediaProfile(
            engine: engine.map(Self.engine),
            delivery: decision.map(Self.delivery),
            network: locality.map(Self.network),
            container: container(media?.container),
            videoCodec: videoCodec(media?.videoCodec ?? video?.codec),
            audioCodec: audioCodec(media?.audioCodec),
            hdr: hdr(of: video),
            resolution: resolution(height: media?.height ?? video?.height)
        )
    }
}

/// Bounds how often errors can be sent, in memory only (no disk, like the
/// rest of reporting). The same signature goes out at most once per
/// `repeatInterval`; all errors together at most `maxPerWindow` per `window`.
struct AnalyticsErrorRateLimiter: Sendable {
    var repeatInterval: TimeInterval = 10 * 60
    var window: TimeInterval = 60 * 60
    var maxPerWindow = 20

    private var lastSent: [String: Date] = [:]
    private var recent: [Date] = []

    init(repeatInterval: TimeInterval = 10 * 60, window: TimeInterval = 60 * 60, maxPerWindow: Int = 20) {
        self.repeatInterval = repeatInterval
        self.window = window
        self.maxPerWindow = maxPerWindow
    }

    mutating func allow(_ signature: String, now: Date = .now) -> Bool {
        recent.removeAll { now.timeIntervalSince($0) >= window }
        lastSent = lastSent.filter { now.timeIntervalSince($0.value) < repeatInterval }

        if lastSent[signature] != nil { return false }
        guard recent.count < maxPerWindow else { return false }

        lastSent[signature] = now
        recent.append(now)
        return true
    }
}

/// When dropped frames count as a rendering problem rather than noise: at
/// least `minimumDropped` frames and at least `minimumRatio` of what should
/// have been shown. AVPlayer has no displayed-frame count, so its ratio is
/// estimated from watched time at 24 fps (the lowest common film rate, so
/// the estimate errs towards not reporting).
enum DroppedFrameThreshold {
    static let minimumDropped = 120
    static let minimumRatio = 0.05

    static func isExceeded(dropped: Int, displayed: Int) -> Bool {
        guard dropped >= minimumDropped else { return false }
        let total = dropped + max(0, displayed)
        return Double(dropped) / Double(total) >= minimumRatio
    }

    static func isExceeded(dropped: Int, watchedSeconds: Double) -> Bool {
        guard watchedSeconds > 0 else { return false }
        return isExceeded(dropped: dropped, displayed: Int(watchedSeconds * 24) - dropped)
    }
}

/// The one door error reports go through from code that has no environment
/// (engines, the coordinator, the download manager). Set up in `DuskApp.init`;
/// without it, every report is dropped silently.
@MainActor
enum ErrorReporter {
    static var client: AnalyticsClient?
    /// The technical profile of whatever is playing right now, read when a
    /// playback report is made. Supplied by the coordinator.
    static var playbackProfile: (@MainActor () -> AnalyticsMediaProfile?)?

    static func report(_ report: AnalyticsErrorReport) {
        guard let client else { return }
        var report = report
        if report.category.isPlayback, let profile = playbackProfile?() {
            let engine = report.media.engine
            report.media = profile
            // An engine reporting about itself knows best which one it is.
            if let engine { report.media.engine = engine }
        }
        client.recordError(report)
    }

    static func report(
        _ category: AnalyticsErrorCategory,
        reason: AnalyticsErrorReason? = nil,
        error: (any Error)? = nil,
        engine: PlaybackEngineType? = nil,
        count: Int? = nil
    ) {
        var report = AnalyticsErrorReport(category, reason: reason, error: error, count: count)
        report.media.engine = engine.map(AnalyticsErrorSanitizer.engine)
        self.report(report)
    }
}
