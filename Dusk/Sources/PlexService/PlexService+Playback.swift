import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

private let plexPlaybackLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexPlayback"
)

extension PlexService {
    enum TranscodeDecisionOutcome: Sendable {
        case transcodeAvailable
        case directPlayOnly
        case failed(String?)
    }

    /// How the server should deliver an HLS session.
    enum TranscodeDeliveryMode: Sendable {
        /// User-selected quality preset: full server transcode with hard
        /// bitrate/resolution caps (directPlay=0, directStream=0).
        case manualTranscode(PlaybackQualityPreset)
        /// Automatic delivery-ladder rung below direct play: the server copies
        /// the original tracks into HLS when the profile allows
        /// (directStream=1, directStreamAudio=1) and only re-encodes what it
        /// must. No bitrate/resolution caps are applied.
        case directStreamFallback
        /// User-selected AirPlay route: package the original as HLS for native
        /// AVPlayer external playback. Plex may copy compatible tracks, but the
        /// H.264/AAC target lets it convert receiver-incompatible containers,
        /// video, audio, and burned subtitles without imposing a quality cap.
        case airPlay

        var logLabel: String {
            switch self {
            case let .manualTranscode(preset): "manual transcode (\(preset.displayName))"
            case .directStreamFallback: "server direct-stream"
            case .airPlay: "AirPlay stream"
            }
        }
    }

    func reportTimeline(
        ratingKey: String,
        key: String? = nil,
        state: PlaybackState,
        timeMs: Int,
        durationMs: Int,
        sessionIdentifier: String? = nil
    ) async {
        try? await submitTimeline(
            ratingKey: ratingKey,
            key: key,
            state: state,
            timeMs: timeMs,
            durationMs: durationMs,
            sessionIdentifier: sessionIdentifier
        )
    }

    func submitTimeline(
        ratingKey: String,
        key: String? = nil,
        state: PlaybackState,
        timeMs: Int,
        durationMs: Int,
        sessionIdentifier: String? = nil
    ) async throws {
        let stateString: String
        switch state {
        case .playing:
            stateString = "playing"
        case .paused:
            stateString = "paused"
        case .loading:
            // The engine is opening or refilling its buffer. Plex expects
            // "buffering" here so the server keeps the session (and any
            // transcoder) alive instead of timing it out.
            stateString = "buffering"
        default:
            stateString = "stopped"
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: key ?? "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: stateString),
            URLQueryItem(name: "time", value: String(timeMs)),
            URLQueryItem(name: "duration", value: String(durationMs)),
        ]
        if let sessionIdentifier {
            queryItems.append(URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier))
        }

        _ = try await rawServerRequest(
            path: "/:/timeline",
            queryItems: queryItems
        )
    }

    func scrobble(ratingKey: String) async throws {
        _ = try await rawServerRequest(
            path: "/:/scrobble",
            queryItems: [
                URLQueryItem(name: "key", value: ratingKey),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            ]
        )
    }

    func unscrobble(ratingKey: String) async throws {
        _ = try await rawServerRequest(
            path: "/:/unscrobble",
            queryItems: [
                URLQueryItem(name: "key", value: ratingKey),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            ]
        )
    }

    func setWatched(_ watched: Bool, ratingKey: String) async throws {
        if watched {
            try await scrobble(ratingKey: ratingKey)
        } else {
            try await unscrobble(ratingKey: ratingKey)
        }
    }

    /// Hides an item from the server-wide "Continue Watching" hub without
    /// changing its watch state, mirroring Plex's "Remove from Continue
    /// Watching" action.
    func removeFromContinueWatching(ratingKey: String) async throws {
        _ = try await rawServerRequest(
            method: "PUT",
            path: "/actions/removeFromContinueWatching",
            queryItems: [
                URLQueryItem(name: "ratingKey", value: ratingKey),
            ]
        )
    }

    func directPlayURL(for part: PlexMediaPart) -> URL? {
        guard let baseURL = serverBaseURL else {
            plexPlaybackLogger.error(
                "Failed to build direct play URL for part \(part.id, privacy: .public): missing server base URL"
            )
            return nil
        }
        let urlString = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast()) + part.key
            : baseURL.absoluteString + part.key
        guard var components = URLComponents(string: urlString) else {
            plexPlaybackLogger.error(
                "Failed to build direct play URL for part \(part.id, privacy: .public): invalid URL string \(urlString, privacy: .private(mask: .hash))"
            )
            return nil
        }
        var items = components.queryItems ?? []
        if let token = preferredServerToken {
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else {
            plexPlaybackLogger.error(
                "Failed to finalize direct play URL for part \(part.id, privacy: .public)"
            )
            return nil
        }

        plexPlaybackLogger.debug(
            "Constructed direct play URL for part \(part.id, privacy: .public): \(Self.sanitizedPlaybackURLString(for: url), privacy: .public)"
        )
        return url
    }

    func transcodeURL(
        ratingKey: String,
        mediaIndex: Int,
        preset: PlaybackQualityPreset,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: Int? = nil,
        subtitleStreamID: Int? = nil
    ) async throws -> (url: URL, outcome: TranscodeDecisionOutcome) {
        guard !preset.isOriginal else {
            throw PlexServiceError.invalidURL
        }

        return try await transcodeLadderURL(
            ratingKey: ratingKey,
            mediaIndex: mediaIndex,
            mode: .manualTranscode(preset),
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID
        )
    }

    /// Server-stream ladder rung: asks Plex for an HLS session with
    /// direct-stream enabled, so the server remuxes (copies) the original
    /// video/audio into HLS whenever the profile allows and only re-encodes
    /// what it must. Used when direct play fails or is known to be
    /// unrenderable locally; no bitrate or resolution caps are applied.
    func serverStreamURL(
        ratingKey: String,
        mediaIndex: Int,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: Int? = nil,
        subtitleStreamID: Int? = nil
    ) async throws -> (url: URL, outcome: TranscodeDecisionOutcome) {
        try await transcodeLadderURL(
            ratingKey: ratingKey,
            mediaIndex: mediaIndex,
            mode: .directStreamFallback,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID
        )
    }

    /// Prepares an AirPlay-safe Plex HLS stream. This is an intentional output
    /// route decision rather than an automatic quality default: local playback
    /// remains direct-play first, while an explicitly selected AirPlay receiver
    /// gets an AVPlayer-compatible stream with no bitrate or resolution cap.
    func airPlayStreamURL(
        ratingKey: String,
        mediaIndex: Int,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: Int? = nil,
        subtitleStreamID: Int? = nil
    ) async throws -> (url: URL, outcome: TranscodeDecisionOutcome) {
        try await transcodeLadderURL(
            ratingKey: ratingKey,
            mediaIndex: mediaIndex,
            mode: .airPlay,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID
        )
    }

    /// Starts a Plex HLS consumer for an already-tuned Live TV session.
    /// Live session paths are virtual resources, so they must go through the
    /// universal endpoint rather than direct-play URL validation for files.
    func liveTVStreamURL(
        sessionPath: String,
        sessionIdentifier: String,
        transcodeSessionID: String
    ) async throws -> (url: URL, outcome: TranscodeDecisionOutcome) {
        try await transcodeLadderURL(
            ratingKey: sessionPath,
            mediaIndex: 0,
            sourcePath: sessionPath,
            mode: .directStreamFallback,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: nil,
            subtitleStreamID: nil
        )
    }

    /// Plex session hygiene: tells the server to reap the transcoder for a
    /// finished session so it stops burning CPU/disk on the server. Errors are
    /// logged, never thrown — this call is best-effort by design.
    func stopTranscodeSession(transcodeSessionID: String) async {
        do {
            _ = try await rawServerRequest(
                path: "/video/:/transcode/universal/stop",
                queryItems: [URLQueryItem(name: "session", value: transcodeSessionID)]
            )
            plexPlaybackLogger.notice(
                "Stopped transcode session \(transcodeSessionID, privacy: .public)"
            )
        } catch {
            plexPlaybackLogger.error(
                "Failed to stop transcode session \(transcodeSessionID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Keep-alive for an active transcode session; Plex reaps transcoders it
    /// has not heard from. Errors are logged, never thrown.
    func pingTranscodeSession(transcodeSessionID: String) async {
        do {
            _ = try await rawServerRequest(
                path: "/video/:/transcode/universal/ping",
                queryItems: [URLQueryItem(name: "session", value: transcodeSessionID)]
            )
            plexPlaybackLogger.debug(
                "Pinged transcode session \(transcodeSessionID, privacy: .public)"
            )
        } catch {
            plexPlaybackLogger.error(
                "Failed to ping transcode session \(transcodeSessionID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func sanitizedPlaybackURLString(for url: URL) -> String {
        Self.sanitizedPlaybackURLString(for: url)
    }
}

private extension PlexService {
    /// Shared decision + start.m3u8 flow for both delivery modes: asks
    /// `/video/:/transcode/universal/decision` whether the server can deliver
    /// the session, then builds the matching `start.m3u8` URL.
    func transcodeLadderURL(
        ratingKey: String,
        mediaIndex: Int,
        sourcePath: String? = nil,
        mode: TranscodeDeliveryMode,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: Int?,
        subtitleStreamID: Int?
    ) async throws -> (url: URL, outcome: TranscodeDecisionOutcome) {
        guard let baseURL = serverBaseURL else {
            throw PlexServiceError.noServerConnected
        }

        let queryItems = transcodeQueryItems(
            ratingKey: ratingKey,
            mediaIndex: mediaIndex,
            sourcePath: sourcePath,
            mode: mode,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            includeToken: true
        )

        let decisionData = try await rawServerRequest(
            path: "/video/:/transcode/universal/decision",
            queryItems: queryItems
        )
        let decision = try decodeJSON(PlexTranscodeDecisionResponse.self, from: decisionData)
        let outcome = decision.outcome

        guard case .transcodeAvailable = outcome else {
            return (baseURL, outcome)
        }

        guard let url = buildURL(
            base: baseURL.absoluteString,
            path: "/video/:/transcode/universal/start.m3u8",
            queryItems: queryItems
        ) else {
            throw PlexServiceError.invalidURL
        }

        plexPlaybackLogger.notice(
            "Constructed \(mode.logLabel, privacy: .public) URL for ratingKey \(ratingKey, privacy: .public), mediaIndex \(mediaIndex, privacy: .public): \(Self.sanitizedPlaybackURLString(for: url), privacy: .public)"
        )

        return (url, outcome)
    }

    func transcodeQueryItems(
        ratingKey: String,
        mediaIndex: Int,
        sourcePath: String?,
        mode: TranscodeDeliveryMode,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: Int?,
        subtitleStreamID: Int?,
        includeToken: Bool
    ) -> [URLQueryItem] {
        let clientProfileExtra = transcodeClientProfileExtra(for: mode)
        let resolvedSourcePath = sourcePath ?? "/library/metadata/\(ratingKey)"
        let isLiveTVSource = resolvedSourcePath.hasPrefix("/livetv/sessions/")

        // Manual transcodes force a full re-encode; the direct-stream fallback
        // lets the server copy the original tracks into HLS when it can.
        let allowsDirectStream: Bool
        switch mode {
        case .manualTranscode: allowsDirectStream = false
        case .directStreamFallback, .airPlay: allowsDirectStream = true
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "hasMDE", value: "1"),
            URLQueryItem(name: "path", value: resolvedSourcePath),
            URLQueryItem(name: "mediaIndex", value: String(mediaIndex)),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: allowsDirectStream ? "1" : "0"),
            URLQueryItem(name: "directStreamAudio", value: allowsDirectStream ? "1" : "0"),
            URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "audioBoost", value: "100"),
            URLQueryItem(name: "location", value: "lan"),
            URLQueryItem(name: "addDebugOverlay", value: "0"),
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
            URLQueryItem(name: "mediaBufferSize", value: "102400"),
            URLQueryItem(name: "session", value: transcodeSessionID),
            URLQueryItem(name: "transcodeSessionId", value: transcodeSessionID),
            URLQueryItem(name: "copyts", value: isLiveTVSource ? "0" : "1"),
            URLQueryItem(name: "Accept-Language", value: "en"),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier),
            URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: clientProfileExtra),
            URLQueryItem(name: "X-Plex-Client-Profile-Name", value: "Generic"),
            URLQueryItem(name: "X-Plex-Incomplete-Segments", value: "1"),
            URLQueryItem(name: "X-Plex-Features", value: "external-media,indirect-media"),
            URLQueryItem(name: "X-Plex-Language", value: "en"),
            URLQueryItem(name: "X-Plex-Product", value: "Dusk"),
            URLQueryItem(
                name: "X-Plex-Version",
                value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            ),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: Self.transcodeClientPlatform),
            URLQueryItem(name: "X-Plex-Platform-Version", value: Self.transcodeClientPlatformVersion),
            URLQueryItem(name: "X-Plex-Device", value: Self.transcodeClientDevice),
        ]

        if isLiveTVSource {
            items.append(URLQueryItem(name: "offset", value: "-1"))
        }

        if let subtitleStreamID {
            items.append(URLQueryItem(name: "subtitleStreamID", value: String(subtitleStreamID)))
            items.append(URLQueryItem(name: "subtitles", value: "burn"))
        } else {
            items.append(URLQueryItem(name: "subtitles", value: "none"))
        }

        if case let .manualTranscode(preset) = mode {
            if let bitrate = preset.videoBitrateKbps {
                items.append(URLQueryItem(name: "maxVideoBitrate", value: String(bitrate)))
                items.append(URLQueryItem(name: "videoBitrate", value: String(bitrate)))
            }
            if let resolution = preset.videoResolution {
                items.append(URLQueryItem(name: "videoResolution", value: resolution))
            }
            if let quality = preset.videoQuality {
                items.append(URLQueryItem(name: "videoQuality", value: String(quality)))
            }
        }
        if let audioStreamID {
            items.append(URLQueryItem(name: "audioStreamID", value: String(audioStreamID)))
        }
        if includeToken, let token = preferredServerToken {
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }

        return items
    }

    func transcodeClientProfileExtra(for mode: TranscodeDeliveryMode) -> String {
        var clauses: [String] = []
        if case let .manualTranscode(preset) = mode, let bitrate = preset.videoBitrateKbps {
            clauses.append(
                "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.bitrate&value=\(bitrate)&replace=true)"
            )
        }
        // Plex's HEVC transcoder can choose HEVC HLS from this profile, but the
        // current Generic/mpegts target is not reliable with AVPlayer on Apple
        // platforms and can produce audio-only playback.
        clauses.append(
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac)"
        )
        return clauses.joined(separator: "+")
    }

    // MARK: - Honest client identity

    static var transcodeClientPlatform: String {
        #if os(tvOS)
        "tvOS"
        #else
        "iOS"
        #endif
    }

    @MainActor
    static var transcodeClientPlatformVersion: String {
        #if canImport(UIKit)
        UIDevice.current.systemVersion
        #else
        ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    @MainActor
    static var transcodeClientDevice: String {
        #if canImport(UIKit)
        UIDevice.current.model
        #else
        "Mac"
        #endif
    }

    static func sanitizedPlaybackURLString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let sanitizedItems = queryItems.compactMap { item -> URLQueryItem? in
                guard item.name.caseInsensitiveCompare("X-Plex-Token") != .orderedSame else {
                    return URLQueryItem(name: item.name, value: "<redacted>")
                }
                return item
            }
            components.queryItems = sanitizedItems.isEmpty ? nil : sanitizedItems
        }

        return components.string ?? url.absoluteString
    }
}

private struct PlexTranscodeDecisionResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let generalDecisionCode: Int?
        let generalDecisionText: String?
        let transcodeDecisionCode: Int?
        let transcodeDecisionText: String?
        let mdeDecisionCode: Int?
        let mdeDecisionText: String?

        enum CodingKeys: String, CodingKey {
            case generalDecisionCode
            case generalDecisionText
            case transcodeDecisionCode
            case transcodeDecisionText
            case mdeDecisionCode
            case mdeDecisionText
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            generalDecisionCode = Self.decodeFlexibleInt(container, key: .generalDecisionCode)
            generalDecisionText = try container.decodeIfPresent(String.self, forKey: .generalDecisionText)
            transcodeDecisionCode = Self.decodeFlexibleInt(container, key: .transcodeDecisionCode)
            transcodeDecisionText = try container.decodeIfPresent(String.self, forKey: .transcodeDecisionText)
            mdeDecisionCode = Self.decodeFlexibleInt(container, key: .mdeDecisionCode)
            mdeDecisionText = try container.decodeIfPresent(String.self, forKey: .mdeDecisionText)
        }

        private static func decodeFlexibleInt(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(value)
            }
            return nil
        }
    }

    var outcome: PlexService.TranscodeDecisionOutcome {
        let general = MediaContainer.generalDecisionCode
        let transcode = MediaContainer.transcodeDecisionCode
        let mde = MediaContainer.mdeDecisionCode

        if [general, transcode, mde].contains(where: { ($0 ?? 0) >= 2000 }) {
            return .failed(MediaContainer.transcodeDecisionText ?? MediaContainer.generalDecisionText)
        }
        if transcode == 1000 || general == 1000 {
            return .directPlayOnly
        }
        if transcode == 1001 || general == 1001 {
            return .transcodeAvailable
        }

        return .transcodeAvailable
    }
}
