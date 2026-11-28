import Foundation
import OSLog

private let jellyfinPlaybackLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "JellyfinPlayback"
)

/// Jellyfin's playback (docs/jellyfin/04-architecture.md §12): direct play on
/// both engines, sidecar subtitles and server streams (remux, converted
/// audio, the server-stream rung, AV1 fallback, manual quality, AirPlay)
/// through `POST /Items/{id}/PlaybackInfo` with a profile built for the
/// request (`JellyfinStreamProfile`). Pre-rolls are `JellyfinPrerolls`;
/// Live TV is J-09.
@MainActor
struct JellyfinPlayback: PlaybackProviding {
    let server: JellyfinServerProvider

    nonisolated init(server: JellyfinServerProvider) {
        self.server = server
    }

    /// 04 §12.3: the traits Jellyfin's remux and reporting have.
    nonisolated var traits: PlaybackTraits {
        PlaybackTraits(
            remuxNeedsAtmosSignalingPatch: false,
            remuxNeedsDolbyVisionBoxes: false,
            remuxNeedsVariantFilter: true,
            serverAppliesWatchedThreshold: true,
            persistsTrackChoiceFromReports: true
        )
    }

    nonisolated var credentialPolicy: any CredentialTransportPolicy { JellyfinCredentialPolicy.shared }

    /// `/Videos/{id}/stream?static=true&mediaSourceId=…&ApiKey=…`: the file as
    /// stored, with byte ranges (02 §10).
    func directPlayURL(for part: MediaPart) -> URL? {
        guard let client = try? server.client() else { return nil }
        return Self.authenticatedURL(forServerPath: part.key, client: client)
    }

    /// Jellyfin has no remote-streaming gate like Plex's; the user's policy
    /// (`EnableMediaPlayback`, `EnableRemoteAccess`) is enforced on sign-in.
    func checkAccess(to url: URL) async -> PlaybackAccess { .allowed }

    /// One `/Items/{id}` read for the chosen version's streams (the request
    /// carries only its position), then `PlaybackInfo` with explicit source
    /// and track indexes. The stream opens `.predicted`: the answer names
    /// codecs and reasons, not what is copied; `confirm` reads that from the
    /// session once it plays.
    func openServerStream(_ request: ServerStreamRequest) async throws -> ServerStream {
        if case .live = request.intent { throw MediaServiceError.notImplemented }
        let client = try server.client()
        let item = try await client.send(JellyfinAPI.item(id: JellyfinID.normalized(request.itemID)))
        let sources = item.mediaSources ?? []
        guard sources.indices.contains(request.mediaIndex) else { throw MediaServiceError.invalidURL }
        let source = sources[request.mediaIndex]
        let tracks = Self.tracks(for: request, in: source)

        let answer = try await client.send(JellyfinAPI.playbackInfo(
            itemID: JellyfinID.normalized(request.itemID),
            JellyfinStreamProfile.request(
                intent: request.intent,
                source: source,
                tracks: tracks,
                dolbyVision: request.dolbyVision,
                av1HardwareDecode: AV1PlaybackCapabilities.current.hardwareDecode
            )
        ))
        let playSessionID = answer.playSessionID
        if let playSessionID,
           !JellyfinServerStreams.shared.register(streamSessionID: request.streamSessionID, playSessionID: playSessionID) {
            // Closed while the request was in flight.
            await stopEncoding(playSessionID: playSessionID, client: client)
        }

        let answered = answer.mediaSources.first { JellyfinID.same($0.id, source.id) } ?? answer.mediaSources.first
        func stream(_ url: URL, _ outcome: ServerStreamOutcome, _ decisions: StreamDecisions) -> ServerStream {
            ServerStream(
                url: url,
                sessionID: request.streamSessionID,
                outcome: outcome,
                playMethod: decisions.video == .copy && decisions.audio != .convert ? .directStream : .transcode,
                decisions: decisions,
                proof: .predicted,
                credentialPolicy: credentialPolicy
            )
        }
        guard answer.errorCode == nil, let answered, answered.supportsTranscoding == true,
              let transcodingURL = answered.transcodingURL else {
            jellyfinPlaybackLogger.notice(
                "No server stream for \(request.itemID, privacy: .public): \(answer.errorCode ?? "no transcoding URL", privacy: .public)"
            )
            return stream(client.baseURL, .failed(answer.errorCode), StreamDecisions())
        }
        let url = try client.resolveServerURL(transcodingURL)
        guard credentialPolicy.allowsCredential(in: url) else { throw MediaServiceError.invalidURL }
        let decisions = JellyfinStreamProfile.predictedDecisions(
            transcodingURL: transcodingURL, source: source, tracks: tracks
        )
        jellyfinPlaybackLogger.notice(
            "Server stream for \(request.itemID, privacy: .public) (\(String(describing: request.intent), privacy: .public), DV \(String(describing: request.dolbyVision), privacy: .public)) [\(decisions.logDescription, privacy: .public)]: \(PlaybackURLRedaction.redacted(url.absoluteString), privacy: .public)"
        )
        return stream(url, .transcodeAvailable, decisions)
    }

    /// `GET /Sessions?deviceId=` → `TranscodingInfo` of this device's session:
    /// what the server really copies (03 §5.1 item 8). nil while the session
    /// shows no transcode, or on any failure.
    func confirm(_ stream: ServerStream) async -> StreamDecisions? {
        guard let client = try? server.client(),
              let sessions = try? await client.send(JellyfinAPI.sessions(deviceID: client.identity.deviceID)),
              let info = sessions.lazy.compactMap(\.transcodingInfo).first else {
            return nil
        }
        let confirmed = JellyfinStreamProfile.confirmedDecisions(info, predicted: stream.decisions)
        jellyfinPlaybackLogger.notice(
            "Server stream \(stream.sessionID, privacy: .public) confirmed: \(confirmed.logDescription, privacy: .public)"
        )
        return confirmed
    }

    /// `POST /Sessions/Playing/Ping`: keeps the transcode job of a paused
    /// stream from being reaped.
    func keepAlive(streamSessionID: String) async {
        guard let playSessionID = JellyfinServerStreams.shared.playSessionID(for: streamSessionID),
              let client = try? server.client() else { return }
        do {
            _ = try await client.send(JellyfinAPI.pingPlaybackSession(playSessionID: playSessionID))
        } catch {
            jellyfinPlaybackLogger.error("Ping failed for \(streamSessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `DELETE /Videos/ActiveEncodings`: ends the ffmpeg job. A stream whose
    /// request is still in flight is stopped when its answer arrives.
    func close(streamSessionID: String) async {
        guard let playSessionID = JellyfinServerStreams.shared.close(streamSessionID: streamSessionID),
              let client = try? server.client() else { return }
        await stopEncoding(playSessionID: playSessionID, client: client)
    }

    private func stopEncoding(playSessionID: String, client: JellyfinClient) async {
        do {
            _ = try await client.send(JellyfinAPI.stopEncoding(deviceID: client.identity.deviceID, playSessionID: playSessionID))
        } catch {
            jellyfinPlaybackLogger.error("Stopping encoding \(playSessionID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The request's track ids as the source's streams. Stream ids are
    /// Jellyfin indexes (`JellyfinMediaMapper`). No audio id: the server's
    /// own pick for the user (`DefaultAudioStreamIndex`), never left open.
    /// A burned-in subtitle id `"0"` is the ladder's "off" (Plex's clear
    /// value), not the external subtitle that can sit at index 0.
    nonisolated static func tracks(for request: ServerStreamRequest, in source: JellyfinMediaSourceDTO) -> JellyfinStreamProfile.Tracks {
        let audios = source.streams.filter { $0.type == .audio }
        let audio = request.audioStreamID.flatMap(Int.init).flatMap { index in audios.first { $0.index == index } }
            ?? source.defaultAudioStreamIndex.flatMap { index in audios.first { $0.index == index } }
            ?? audios.first
        var subtitle: JellyfinMediaStreamDTO?
        var delivery = SubtitleDelivery.burnIn
        if case let .stream(id, requestedDelivery) = request.subtitle,
           !(id == "0" && requestedDelivery == .burnIn),
           let index = Int(id), index >= 0 {
            subtitle = source.streams.first { $0.type == .subtitle && $0.index == index }
            delivery = requestedDelivery
        }
        return JellyfinStreamProfile.Tracks(audio: audio, subtitle: subtitle, subtitleDelivery: delivery)
    }

    /// Jellyfin takes the tracks from each request and remembers the ones the
    /// playback reports name (`RememberAudioSelections`); nothing to store first.
    func prepareTrackSelection(_ selection: TrackSelection, partID: String) async throws {}

    /// An external subtitle as the server serves it (`…/Subtitles/{index}/0/Stream.srt`).
    /// nil for embedded tracks, which the engine selects itself, and for
    /// formats the server cannot serve as a file (VobSub).
    func sidecarSubtitleURL(for stream: MediaStream) -> URL? {
        guard stream.kind == .subtitle, let key = stream.key?.nilIfEmpty,
              JellyfinMediaMapper.servableSidecarFormats.contains(URL(fileURLWithPath: key).pathExtension.lowercased()),
              let client = try? server.client() else { return nil }
        return Self.authenticatedURL(forServerPath: key, client: client)
    }

    func prerolls(before itemID: String) async throws -> [MediaDetails] { try await JellyfinPrerolls.load(before: itemID, server: server) }

    /// A token-free server path from the mapper (`part.key`, `stream.key`:
    /// path plus query) as a URL carrying `ApiKey`, for engines that cannot
    /// send the `Authorization` header.
    nonisolated static func authenticatedURL(forServerPath serverPath: String, client: JellyfinClient) -> URL? {
        guard let components = URLComponents(string: serverPath), !components.path.isEmpty else { return nil }
        guard let url = try? client.authenticatedURL(path: components.path, query: components.queryItems ?? []),
              JellyfinCredentialPolicy.shared.allowsCredential(in: url) else { return nil }
        return url
    }
}
