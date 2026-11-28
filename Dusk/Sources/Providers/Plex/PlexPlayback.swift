import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

private let plexPlaybackLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexPlayback"
)

private let plexSubtitlesLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexSubtitles"
)

/// What `PlexPlayback` needs from the service to reach its server: the
/// session (base URL, token, locality) and a request that goes through the
/// service's routing, token refresh and self-healing (`rawServerRequest`).
/// `PlexClient` sends single attempts only, so a facet that talked to it
/// directly would lose the recovery every Plex call has today.
@MainActor
protocol PlexPlaybackRouting: AnyObject {
    func plexPlaybackSession(for serverID: String?) -> ServerSession?
    func resolveServerID(_ serverID: String?) throws -> String
    func rawServerRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?,
        timeoutInterval: TimeInterval?,
        serverID: String?
    ) async throws -> Data
    func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data, serverID: String?) throws -> T
}

/// Plex's `PlaybackProviding`: direct-play and sidecar URLs, the universal
/// transcoder's decision + `start.m3u8` flow, `/ping` and `/stop`, the part
/// selection PUT and the pre-roll play queue.
///
/// `serverID` nil means the primary server, exactly as the service's
/// `serverID: nil` always has. Without a `router` (a provider built before the
/// service wired one, see `PlexServerProvider.playback`) every verb answers
/// as for a disconnected server.
struct PlexPlayback: PlaybackProviding {
    let client: PlexClient
    let serverID: String?
    weak var router: (any PlexPlaybackRouting)?

    init(client: PlexClient, serverID: String? = nil, router: (any PlexPlaybackRouting)? = nil) {
        self.client = client
        self.serverID = serverID
        self.router = router
    }

    var traits: PlaybackTraits { .plex }
    var credentialPolicy: any CredentialTransportPolicy { PlexCredentialPolicy.shared }

    // MARK: - Direct play

    @MainActor
    func directPlayURL(for part: MediaPart) -> URL? {
        guard let connection = router?.plexPlaybackSession(for: serverID) else {
            plexPlaybackLogger.error(
                "Failed to build direct play URL for part \(part.id, privacy: .public): missing server base URL"
            )
            return nil
        }
        let baseURL = connection.baseURL
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
        items.append(URLQueryItem(name: "X-Plex-Token", value: connection.token))
        components.queryItems = items.isEmpty ? nil : items
        guard let url = PlexTransportSecurity.authenticatedURL(components.url) else {
            plexPlaybackLogger.error(
                "Failed to finalize direct play URL for part \(part.id, privacy: .public)"
            )
            return nil
        }

        plexPlaybackLogger.debug(
            "Constructed direct play URL for part \(part.id, privacy: .public): \(Self.sanitizedURLString(for: url), privacy: .public)"
        )
        return url
    }

    /// Remote sessions only: asks for the first byte of the direct-play file,
    /// because an engine handed a refused URL never reports it — AVPlayer
    /// just keeps loading — so the refusal would surface as an endless
    /// spinner. Refused only for a 403; anything else is left to the engine.
    @MainActor
    func checkAccess(to url: URL) async -> PlaybackAccess {
        guard let connection = router?.plexPlaybackSession(for: serverID), !connection.isLocal else {
            return .allowed
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10
        for (key, value) in client.plexRequestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard (try? PlexTransportSecurity.validate(request)) != nil else { return .allowed }
        guard let response = try? await client.session.data(for: request).1 as? HTTPURLResponse,
              response.statusCode == 403 else {
            return .allowed
        }
        return .refusedRemotely
    }

    // MARK: - Server streams

    @MainActor
    func openServerStream(_ request: ServerStreamRequest) async throws -> ServerStream {
        try await openStream(
            itemID: request.itemID,
            mediaIndex: request.mediaIndex,
            sourcePath: nil,
            intent: request.intent,
            sessionIdentifier: request.playbackSessionID,
            transcodeSessionID: request.streamSessionID,
            audioStreamID: request.audioStreamID,
            subtitleStreamID: request.subtitle.streamID
        )
    }

    /// Plex reports per track what it copies, so every stream opens proven.
    @MainActor
    func confirm(_ stream: ServerStream) async -> StreamDecisions? {
        nil
    }

    /// Keep-alive for an active transcode session; Plex reaps transcoders it
    /// has not heard from. Errors are logged, never thrown.
    @MainActor
    func keepAlive(streamSessionID transcodeSessionID: String) async {
        do {
            _ = try await send(
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

    /// Plex session hygiene: tells the server to reap the transcoder for a
    /// finished session so it stops burning CPU/disk on the server. Errors are
    /// logged, never thrown — this call is best-effort by design.
    @MainActor
    func close(streamSessionID transcodeSessionID: String) async {
        do {
            _ = try await send(
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

    /// Records the viewer's audio/subtitle choice on the Plex part — the same
    /// call Plex's own clients make on a track change. The universal
    /// transcoder takes a session's subtitle from this selection (the
    /// `subtitleStreamID` query item alone is ignored for segmented text
    /// subtitles). `subtitleStreamID: "0"` clears the subtitle selection.
    @MainActor
    func prepareTrackSelection(_ selection: TrackSelection, partID: String) async throws {
        var queryItems = [URLQueryItem(name: "allParts", value: "1")]
        if let audioStreamID = selection.audioStreamID {
            queryItems.append(URLQueryItem(name: "audioStreamID", value: String(audioStreamID)))
        }
        if let subtitleStreamID = selection.subtitleStreamID {
            queryItems.append(URLQueryItem(name: "subtitleStreamID", value: String(subtitleStreamID)))
        }
        _ = try await send(method: "PUT", path: "/library/parts/\(partID)", queryItems: queryItems)
    }

    // MARK: - Sidecars

    /// Returns nil for embedded streams: only external (sidecar) subtitle
    /// streams carry a `key`, and embedded tracks are selected in the engine
    /// instead of fetched.
    @MainActor
    func sidecarSubtitleURL(for stream: MediaStream) -> URL? {
        guard stream.kind == .subtitle, let key = stream.key?.nilIfEmpty else { return nil }
        guard let connection = router?.plexPlaybackSession(for: serverID) else {
            plexSubtitlesLogger.error(
                "Failed to build external subtitle URL for stream \(stream.id, privacy: .public): missing server base URL"
            )
            return nil
        }

        let baseURL = connection.baseURL
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        let path = key.hasPrefix("/") ? key : "/\(key)"
        guard var components = URLComponents(string: base + path) else {
            plexSubtitlesLogger.error(
                "Failed to build external subtitle URL for stream \(stream.id, privacy: .public): invalid URL string"
            )
            return nil
        }

        // Same token choice as direct play and image requests: the server token,
        // never the account token.
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "X-Plex-Token", value: connection.token))
        components.queryItems = items

        guard let url = PlexTransportSecurity.authenticatedURL(components.url) else {
            plexSubtitlesLogger.error(
                "Failed to finalize external subtitle URL for stream \(stream.id, privacy: .public)"
            )
            return nil
        }

        plexSubtitlesLogger.debug(
            "Constructed external subtitle URL for stream \(stream.id, privacy: .public): \(Self.sanitizedURLString(for: url), privacy: .public)"
        )
        return url
    }

    // MARK: - Pre-rolls

    /// The pre-roll videos the server wants played before `itemID`, in
    /// order. Empty when the server has none configured.
    ///
    /// This is how official Plex clients get them: create a play queue for the
    /// movie with `extrasPrefixCount`, and the server puts its extras in front
    /// of the movie. The server decides what plays (Settings → Extras →
    /// "Cinema Trailer pre-roll video": a comma plays every file in order, a
    /// semicolon picks one at random); the client never reads that preference,
    /// which shared users could not read anyway.
    ///
    /// `extrasPrefixCount` is the number of cinema *trailers* in front of the
    /// pre-roll — in Plex a per-client setting, not a server one. Dusk has no
    /// such setting and sends 0 ("pre-roll only"): it plays exactly what the
    /// server owner set up, and a server without a pre-roll answers with the
    /// movie alone. Leaving the parameter out entirely returns no extras at all.
    @MainActor
    func prerolls(before itemID: String) async throws -> [MediaDetails] {
        guard let router else { throw PlexServiceError.noServerConnected }
        let targetID = try router.resolveServerID(serverID)
        let data = try await router.rawServerRequest(
            method: "POST",
            path: "/playQueues",
            queryItems: [
                URLQueryItem(name: "type", value: "video"),
                URLQueryItem(
                    name: "uri",
                    value: "server://\(targetID)/com.plexapp.plugins.library/library/metadata/\(itemID)"
                ),
                URLQueryItem(name: "extrasPrefixCount", value: "0"),
                URLQueryItem(name: "repeat", value: "0"),
                URLQueryItem(name: "own", value: "1"),
            ],
            timeoutInterval: nil,
            serverID: targetID
        )
        let items = try router.decodeJSON(MetadataResponse<MediaDetails>.self, from: data, serverID: targetID)
            .MediaContainer.Metadata ?? []
        return Self.prerollItems(in: items, featureRatingKey: itemID)
    }

    /// Everything the queue puts in front of the movie. Only clips count: a
    /// queue that somehow led with anything else is not a pre-roll queue.
    static func prerollItems(in queue: [MediaDetails], featureRatingKey: String) -> [MediaDetails] {
        guard let featureIndex = queue.firstIndex(where: { $0.itemID == featureRatingKey }) else {
            return []
        }
        return queue[..<featureIndex].filter { $0.type == .clip && !$0.media.isEmpty }
    }
}

// MARK: - Live TV consumers

extension PlexPlayback {
    /// Starts a Plex HLS consumer for an already-tuned Live TV session.
    /// Live session paths are virtual resources, so they must go through the
    /// universal endpoint rather than direct-play URL validation for files.
    @MainActor
    func liveStream(
        sessionPath: String,
        sessionIdentifier: String,
        transcodeSessionID: String
    ) async throws -> ServerStream {
        try await openStream(
            itemID: sessionPath,
            mediaIndex: 0,
            sourcePath: sessionPath,
            intent: .videoCopyFallback,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: nil,
            subtitleStreamID: nil
        )
    }

    /// Live TV direct play: the live session's own HLS (the tuner stream as
    /// the grabber copies it into 1 s MPEG-TS segments), with no second
    /// transcoder in between. Plex answers a `directPlay=1` decision for the
    /// session with the consumer's playlist,
    /// `/livetv/sessions/{uuid}/{sessionIdentifier}/index.m3u8`, and only
    /// serves that playlist once the decision registered the consumer, so
    /// `sessionIdentifier` must be the one the tune was sent with.
    ///
    /// Why not the transcoder: Live TV media has no bitrate, which Plex reads
    /// as 2147483647 kbps. On any connection Plex counts as remote (Plex
    /// behind a reverse proxy, Tailscale) that "exceeds" the WAN upload
    /// limit, so Plex rewrites the request to a 1280x720 quality-99
    /// re-encode with direct stream disabled — every live channel at 720p,
    /// whatever `directStream`/bitrate Dusk asks for. Direct play is not
    /// bitrate-limited that way. Nil when Plex does not answer with a direct
    /// play of the live session; the caller then transcodes.
    @MainActor
    func liveDirectPlayURL(sessionPath: String, sessionIdentifier: String) async -> URL? {
        guard let router, let connection = router.plexPlaybackSession(for: serverID) else { return nil }
        var queryItems = Self.transcodeQueryItems(
            itemID: sessionPath,
            mediaIndex: 0,
            sourcePath: sessionPath,
            intent: .videoCopyFallback,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: sessionIdentifier,
            audioStreamID: nil,
            subtitleStreamID: nil,
            token: connection.token,
            clientIdentifier: client.clientIdentifier
        )
        if let index = queryItems.firstIndex(where: { $0.name == "directPlay" }) {
            queryItems[index].value = "1"
        }
        do {
            let data = try await send(
                path: "/video/:/transcode/universal/decision",
                queryItems: queryItems
            )
            let decision = try router.decodeJSON(PlexTranscodeDecisionDTO.self, from: data, serverID: nil)
            guard let key = decision.directPlayPartKey,
                  key.hasPrefix("\(sessionPath)/"),
                  let url = Self.liveTVDirectPlayURL(
                    baseURL: connection.baseURL,
                    partKey: key,
                    token: connection.token
                  ) else {
                plexPlaybackLogger.notice(
                    "Live TV direct play declined for \(sessionPath, privacy: .public): \(decision.MediaContainer.mdeDecisionText ?? decision.MediaContainer.generalDecisionText ?? "no direct play part", privacy: .public)"
                )
                return nil
            }
            plexPlaybackLogger.notice(
                "Constructed Live TV direct play URL: \(Self.sanitizedURLString(for: url), privacy: .public)"
            )
            return url
        } catch {
            plexPlaybackLogger.error(
                "Live TV direct play decision failed for \(sessionPath, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// The decision's part key on the server, with the token, minus
    /// `X-Plex-Incomplete-Segments` (Plex adds it to the key): on a cold tune
    /// it opens the playlist with one `#EXTINF:0` segment that AVPlayer never
    /// gets past (see `transcodeQueryItems`).
    static func liveTVDirectPlayURL(baseURL: URL, partKey: String, token: String?) -> URL? {
        guard var components = URLComponents(string: baseURL.absoluteString + partKey) else { return nil }
        var items = (components.queryItems ?? []).filter {
            $0.name != "X-Plex-Incomplete-Segments" && $0.name != "X-Plex-Token"
        }
        if let token {
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}

// MARK: - Decision + start.m3u8

private extension PlexPlayback {
    @MainActor
    func send(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem]?
    ) async throws -> Data {
        guard let router else { throw PlexServiceError.noServerConnected }
        return try await router.rawServerRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            timeoutInterval: nil,
            serverID: serverID
        )
    }

    /// Shared decision + start.m3u8 flow for every intent: asks
    /// `/video/:/transcode/universal/decision` whether the server can deliver
    /// the session, then builds the matching `start.m3u8` URL.
    @MainActor
    func openStream(
        itemID: String,
        mediaIndex: Int,
        sourcePath: String?,
        intent: StreamIntent,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: String?,
        subtitleStreamID: String?
    ) async throws -> ServerStream {
        guard let router else { throw PlexServiceError.noServerConnected }
        let targetID = try router.resolveServerID(serverID)
        guard let connection = router.plexPlaybackSession(for: targetID) else {
            throw PlexServiceError.noServerConnected
        }
        let baseURL = connection.baseURL

        let queryItems = Self.transcodeQueryItems(
            itemID: itemID,
            mediaIndex: mediaIndex,
            sourcePath: sourcePath,
            intent: intent,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            token: connection.token,
            clientIdentifier: client.clientIdentifier
        )

        let decisionData = try await router.rawServerRequest(
            method: "GET",
            path: "/video/:/transcode/universal/decision",
            queryItems: queryItems,
            timeoutInterval: nil,
            serverID: targetID
        )
        let decision = try router.decodeJSON(PlexTranscodeDecisionDTO.self, from: decisionData, serverID: nil)
        let outcome = decision.outcome
        let streams = decision.streamDecisions

        func stream(_ url: URL, _ outcome: ServerStreamOutcome) -> ServerStream {
            ServerStream(
                url: url,
                sessionID: transcodeSessionID,
                outcome: outcome,
                playMethod: Self.playMethod(for: intent),
                decisions: streams,
                proof: .proven,
                credentialPolicy: credentialPolicy
            )
        }

        if case .av1Fallback = intent {
            guard streams.video == .convert,
                  ["h264", "hevc"].contains(streams.videoCodec?.lowercased() ?? ""),
                  ["mp4", "mpegts"].contains(streams.container?.lowercased() ?? "") else {
                return stream(baseURL, .failed("Plex could not convert AV1 to a supported video codec."))
            }
        }

        guard case .transcodeAvailable = outcome else {
            return stream(baseURL, outcome)
        }

        guard let url = client.buildURL(
            base: baseURL.absoluteString,
            path: "/video/:/transcode/universal/start.m3u8",
            queryItems: queryItems
        ) else {
            throw PlexServiceError.invalidURL
        }

        plexPlaybackLogger.notice(
            "Constructed \(Self.logLabel(for: intent), privacy: .public) URL for ratingKey \(itemID, privacy: .public), mediaIndex \(mediaIndex, privacy: .public) [\(streams.logDescription, privacy: .public)]: \(Self.sanitizedURLString(for: url), privacy: .public)"
        )

        return stream(url, outcome)
    }

    static func playMethod(for intent: StreamIntent) -> PlayMethod {
        switch intent {
        case .quality, .av1Fallback: .transcode
        case .losslessRemux, .convertedAudioRemux, .videoCopyFallback, .airPlay, .live: .directStream
        }
    }

    static func logLabel(for intent: StreamIntent) -> String {
        switch intent {
        case let .quality(preset): "manual transcode (\(preset.displayName))"
        case .videoCopyFallback, .live: "server direct-stream"
        case .av1Fallback: "AV1 decoder fallback transcode"
        case .airPlay: "AirPlay stream"
        case .losslessRemux: "Atmos/spatial audio remux"
        case .convertedAudioRemux: "video remux with audio conversion"
        }
    }
}

// MARK: - Request construction

extension PlexPlayback {
    /// Pure request construction, shared by decision/start and codec-policy tests.
    ///
    /// How each intent asks Plex for its stream:
    /// - `.quality`: full server transcode with hard bitrate/resolution caps
    ///   (directPlay=0, directStream=0).
    /// - `.videoCopyFallback` (and `.live`): the server copies the original
    ///   tracks into HLS when the profile allows (directStream=1,
    ///   directStreamAudio=1) and only re-encodes what it must. No caps.
    /// - `.av1Fallback`: AV1 converted to HEVC/H.264; no quality or resolution cap.
    /// - `.airPlay`: the original packaged as HLS for native AVPlayer external
    ///   playback. Plex may copy compatible tracks, but the H.264/AAC target
    ///   lets it convert receiver-incompatible containers, video, audio, and
    ///   burned subtitles without imposing a quality cap.
    /// - `.losslessRemux` / `.convertedAudioRemux`: Dolby Atmos / spatial-audio
    ///   and HDR delivery for files only VLCKit could direct play (MKV & co.):
    ///   Plex copies the original video and Dolby audio into fragmented-MP4 HLS
    ///   so AVPlayer — the engine that feeds Atmos to HDMI and spatial audio to
    ///   AirPods — can render them. Text subtitles ride along as WebVTT
    ///   segments. Only accepted when Plex confirms both tracks are copied
    ///   (`StreamDecisions`). Converting, the video is still copied but Plex
    ///   converts the selected audio stream to E-AC-3 surround. The profile
    ///   allows 7.1; current Plex versions may still cap conversion at 5.1.
    @MainActor
    static func transcodeQueryItems(
        itemID: String,
        mediaIndex: Int,
        sourcePath: String?,
        intent: StreamIntent,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: String?,
        subtitleStreamID: String?,
        token: String?,
        clientIdentifier: String,
        av1Capabilities: AV1PlaybackCapabilities = .current
    ) -> [URLQueryItem] {
        let clientProfileExtra = transcodeClientProfileExtra(for: intent, av1Capabilities: av1Capabilities)
        let resolvedSourcePath = sourcePath ?? "/library/metadata/\(itemID)"
        let isLiveTVSource = resolvedSourcePath.hasPrefix("/livetv/sessions/")

        // Manual transcodes force a full re-encode; the direct-stream fallback
        // lets the server copy the original tracks into HLS when it can.
        let allowsDirectStream: Bool
        switch intent {
        case .quality, .av1Fallback: allowsDirectStream = false
        case .videoCopyFallback, .live, .airPlay, .losslessRemux, .convertedAudioRemux: allowsDirectStream = true
        }
        // Converting audio: with direct-stream audio on, Plex ignores the
        // requested stream and substitutes a copyable sibling (TrueHD 7.1 →
        // the AC-3 5.1 track) instead of converting the one asked for.
        let allowsDirectStreamAudio: Bool
        if case .convertedAudioRemux = intent {
            allowsDirectStreamAudio = false
        } else {
            allowsDirectStreamAudio = allowsDirectStream
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
            URLQueryItem(name: "directStreamAudio", value: allowsDirectStreamAudio ? "1" : "0"),
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
        } else {
            // Never for Live TV. With it, a freshly tuned channel's first
            // media playlist is a single `#EXTINF:0.000000` segment (the one
            // still being written). AVPlayer takes that playlist, then never
            // reloads it, never requests a segment and never fails: an
            // endless spinner (TestFlight, Threadfin channels; reproduced in
            // the simulator against a cold tune). Without it Plex holds the
            // first playlist until whole segments exist, like the Plex app.
            items.append(URLQueryItem(name: "X-Plex-Incomplete-Segments", value: "1"))
        }

        if intent.isRemux {
            // Text subtitles become WebVTT segments (the part's server-side
            // selection decides which); burning one in would force a video
            // re-encode, which the remux refuses anyway.
            if let subtitleStreamID {
                items.append(URLQueryItem(name: "subtitleStreamID", value: String(subtitleStreamID)))
                items.append(URLQueryItem(name: "subtitles", value: "auto"))
            } else {
                items.append(URLQueryItem(name: "subtitles", value: "none"))
            }
        } else if let subtitleStreamID {
            items.append(URLQueryItem(name: "subtitleStreamID", value: String(subtitleStreamID)))
            items.append(URLQueryItem(name: "subtitles", value: "burn"))
        } else {
            items.append(URLQueryItem(name: "subtitles", value: "none"))
        }

        if case let .quality(preset) = intent {
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
        if let token {
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }

        return items
    }

    static func sanitizedURLString(for url: URL) -> String {
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

private extension PlexPlayback {
    static func transcodeClientProfileExtra(for intent: StreamIntent, av1Capabilities: AV1PlaybackCapabilities) -> String {
        var clauses: [String] = []
        let convertsAudio: Bool
        if case .convertedAudioRemux = intent {
            convertsAudio = true
        } else {
            convertsAudio = false
        }
        if intent.isRemux {
            // Listed first so Plex prefers it: fragmented MP4 is the only HLS
            // container AVPlayer plays HEVC from (HEVC in MPEG-TS comes out
            // audio-only). Copy-remuxes accept E-AC-3/AC-3/AAC; converted
            // audio must be E-AC-3. The WebVTT subtitle target turns text
            // subtitles into HLS subtitle segments.
            let audioCodecs = convertsAudio ? "eac3" : (av1Capabilities.hardwareDecode ? "eac3,ac3,aac,flac,alac,mp3" : "eac3,ac3,aac")
            let videoCodecs = av1Capabilities.hardwareDecode ? "hevc,h264,av1" : "hevc,h264"
            clauses.append(
                "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=\(videoCodecs)&audioCodec=\(audioCodecs))"
            )
            clauses.append(
                "add-transcode-target(type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt)"
            )
        }
        if case .av1Fallback = intent {
            clauses.append("add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=hevc,h264&audioCodec=eac3,ac3,aac)")
        }
        if case let .quality(preset) = intent, let bitrate = preset.videoBitrateKbps {
            clauses.append(
                "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.bitrate&value=\(bitrate)&replace=true)"
            )
        }
        // Plex's HEVC transcoder can choose HEVC HLS from this profile, but the
        // current Generic/mpegts target is not reliable with AVPlayer on Apple
        // platforms and can produce audio-only playback.
        if !convertsAudio {
            clauses.append(
                "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac)"
            )
        }

        // Surround survival on the server-side rungs. With only the Generic
        // profile's lone AAC target declared, Plex downmixes every 5.1/7.1
        // source to 2-channel AAC — which is what the direct-stream fallback
        // and every TrueHD title (undecodable in stock VLCKit, so routed
        // through the server before Dusk's own build decoded it) had been
        // getting. AC-3/E-AC-3 in
        // HLS/mpegts is decoded natively by AVPlayer on tvOS and iOS, so
        // offering them keeps discrete channels intact instead of handing the
        // player a pre-folded stereo mix.
        //
        // Deliberately NOT applied to `.airPlay`: that rung targets whatever
        // receiver the user picked, which is not necessarily AC-3 capable, and
        // its current behaviour is known-good. Deliberately no `aac` channel
        // limitation either — capping it would fight Plex's own decision
        // engine rather than simply widening what we accept.
        let allowsSurroundAudioTargets: Bool
        switch intent {
        case .quality, .videoCopyFallback, .live, .losslessRemux, .convertedAudioRemux, .av1Fallback:
            allowsSurroundAudioTargets = true
        case .airPlay:
            allowsSurroundAudioTargets = false
        }
        if allowsSurroundAudioTargets {
            clauses.append(
                "add-transcode-target-audio-codec(type=videoProfile&context=streaming&protocol=hls&audioCodec=eac3)"
            )
            if !convertsAudio {
                clauses.append(
                    "add-transcode-target-audio-codec(type=videoProfile&context=streaming&protocol=hls&audioCodec=ac3)"
                )
            }
            let maxEAC3Channels = convertsAudio ? 8 : 6
            clauses.append(
                "add-limitation(scope=videoAudioCodec&scopeName=eac3&type=upperBound&name=audio.channels&value=\(maxEAC3Channels)&replace=true)"
            )
            clauses.append(
                "add-limitation(scope=videoAudioCodec&scopeName=ac3&type=upperBound&name=audio.channels&value=6&replace=true)"
            )
        }
        return clauses.joined(separator: "+")
    }

    // MARK: - Honest client identity

    static var transcodeClientPlatform: String {
        #if os(tvOS)
        "tvOS"
        #elseif os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }

    @MainActor
    static var transcodeClientPlatformVersion: String {
        #if canImport(UIKit)
        UIDevice.current.systemVersion
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
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
}

extension PlaybackTraits {
    /// Plex's remux needs Dusk to put back what its fMP4 muxer drops: the
    /// Atmos `dec3` extension and the Dolby Vision `dvcC`/`dvvC` boxes. The
    /// server neither lists a second variant nor applies the watched
    /// threshold itself.
    static let plex = PlaybackTraits(
        remuxNeedsAtmosSignalingPatch: true,
        remuxNeedsDolbyVisionBoxes: true,
        remuxNeedsVariantFilter: false,
        serverAppliesWatchedThreshold: false,
        persistsTrackChoiceFromReports: false
    )
}

extension PlexServerProvider {
    /// No router yet: the provider is built by the pool, which cannot hand it
    /// the service. Until the service wires one in (P0-16), playback routes
    /// through `MediaService.playback(for:)`, which builds the facet with
    /// itself as the router.
    var playback: any PlaybackProviding { PlexPlayback(client: client, serverID: descriptor.id) }
}
