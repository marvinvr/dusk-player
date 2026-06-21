import Foundation
import OSLog

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

    func reportTimeline(ratingKey: String, state: PlaybackState, timeMs: Int, durationMs: Int) async {
        try? await submitTimeline(
            ratingKey: ratingKey,
            state: state,
            timeMs: timeMs,
            durationMs: durationMs
        )
    }

    func submitTimeline(ratingKey: String, state: PlaybackState, timeMs: Int, durationMs: Int) async throws {
        let stateString: String
        switch state {
        case .playing:
            stateString = "playing"
        case .paused:
            stateString = "paused"
        default:
            stateString = "stopped"
        }

        _ = try await rawServerRequest(
            path: "/:/timeline",
            queryItems: [
                URLQueryItem(name: "ratingKey", value: ratingKey),
                URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
                URLQueryItem(name: "state", value: stateString),
                URLQueryItem(name: "time", value: String(timeMs)),
                URLQueryItem(name: "duration", value: String(durationMs)),
            ]
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
        audioStreamID: Int? = nil
    ) async throws -> (url: URL, outcome: TranscodeDecisionOutcome) {
        guard !preset.isOriginal else {
            throw PlexServiceError.invalidURL
        }
        guard let baseURL = serverBaseURL else {
            throw PlexServiceError.noServerConnected
        }

        let queryItems = transcodeQueryItems(
            ratingKey: ratingKey,
            mediaIndex: mediaIndex,
            preset: preset,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
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

        let startQueryItems = transcodeQueryItems(
            ratingKey: ratingKey,
            mediaIndex: mediaIndex,
            preset: preset,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            includeToken: true
        )

        guard let url = buildURL(
            base: baseURL.absoluteString,
            path: "/video/:/transcode/universal/start.m3u8",
            queryItems: startQueryItems
        ) else {
            throw PlexServiceError.invalidURL
        }

        plexPlaybackLogger.notice(
            "Constructed transcode URL for ratingKey \(ratingKey, privacy: .public), mediaIndex \(mediaIndex, privacy: .public), preset \(preset.displayName, privacy: .public): \(Self.sanitizedPlaybackURLString(for: url), privacy: .public)"
        )

        return (url, outcome)
    }

    func sanitizedPlaybackURLString(for url: URL) -> String {
        Self.sanitizedPlaybackURLString(for: url)
    }
}

private extension PlexService {
    func transcodeQueryItems(
        ratingKey: String,
        mediaIndex: Int,
        preset: PlaybackQualityPreset,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: Int?,
        includeToken: Bool
    ) -> [URLQueryItem] {
        let clientProfileExtra = transcodeClientProfileExtra(for: preset)

        var items: [URLQueryItem] = [
            URLQueryItem(name: "hasMDE", value: "1"),
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: String(mediaIndex)),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "0"),
            URLQueryItem(name: "directStreamAudio", value: "0"),
            URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "audioBoost", value: "100"),
            URLQueryItem(name: "location", value: "lan"),
            URLQueryItem(name: "addDebugOverlay", value: "0"),
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
            URLQueryItem(name: "mediaBufferSize", value: "102400"),
            URLQueryItem(name: "session", value: transcodeSessionID),
            URLQueryItem(name: "transcodeSessionId", value: transcodeSessionID),
            URLQueryItem(name: "subtitles", value: "none"),
            URLQueryItem(name: "copyts", value: "1"),
            URLQueryItem(name: "Accept-Language", value: "en"),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier),
            URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: clientProfileExtra),
            URLQueryItem(name: "X-Plex-Client-Profile-Name", value: "Generic"),
            URLQueryItem(name: "X-Plex-Incomplete-Segments", value: "1"),
            URLQueryItem(name: "X-Plex-Features", value: "external-media,indirect-media"),
            URLQueryItem(name: "X-Plex-Model", value: "standalone"),
            URLQueryItem(name: "X-Plex-Language", value: "en"),
            URLQueryItem(name: "X-Plex-Product", value: "Dusk"),
            URLQueryItem(
                name: "X-Plex-Version",
                value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            ),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: "Generic"),
        ]

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
        if let audioStreamID {
            items.append(URLQueryItem(name: "audioStreamID", value: String(audioStreamID)))
        }
        if includeToken, let token = preferredServerToken {
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }

        return items
    }

    func transcodeClientProfileExtra(for preset: PlaybackQualityPreset) -> String {
        var clauses: [String] = []
        if let bitrate = preset.videoBitrateKbps {
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
