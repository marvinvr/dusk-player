import Foundation

/// Playback streams: routes onto the server's `PlaybackProviding` facet
/// (docs/jellyfin/04-architecture.md §12). Every method resolves the server
/// first; `serverID: nil` is the primary server, as everywhere in the service.
extension MediaService {
    /// The playback facet of `serverID`'s provider (nil: the primary-tracking
    /// one, which resolves the server per request).
    func playback(for serverID: String?) -> any PlaybackProviding {
        serverProvider(for: serverID).playback
    }

    /// The Plex facet itself, for the Live TV consumers only Plex has.
    private func plexPlayback(for serverID: String?) -> PlexPlayback {
        PlexPlayback(client: client, serverID: serverID, router: plexAccount.router)
    }

    /// - Parameter serverID: The server holding the file. Parts are per-server
    ///   paths, so playing one from the wrong base URL either 404s or, worse,
    ///   streams a different title that happens to share the key.
    func directPlayURL(for part: MediaPart, serverID: String? = nil) -> URL? {
        playback(for: serverID).directPlayURL(for: part)
    }

    func transcodeURL(
        itemID: String,
        mediaIndex: Int,
        preset: PlaybackQualityPreset,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: String? = nil,
        subtitleStreamID: String? = nil,
        serverID: String? = nil
    ) async throws -> ServerStream {
        guard !preset.isOriginal else {
            throw MediaServiceError.invalidURL
        }

        return try await openServerStream(
            itemID: itemID,
            mediaIndex: mediaIndex,
            intent: .quality(preset),
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            serverID: serverID
        )
    }

    /// Server-stream ladder rung: asks the server for an HLS session that
    /// copies the original video/audio whenever it can and only re-encodes
    /// what it must. Used when direct play fails or is known to be
    /// unrenderable locally; no bitrate or resolution caps are applied.
    func serverStreamURL(
        itemID: String,
        mediaIndex: Int,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: String? = nil,
        subtitleStreamID: String? = nil,
        forceVideoTranscode: Bool = false,
        serverID: String? = nil
    ) async throws -> ServerStream {
        try await openServerStream(
            itemID: itemID,
            mediaIndex: mediaIndex,
            intent: forceVideoTranscode ? .av1Fallback : .videoCopyFallback,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            serverID: serverID
        )
    }

    /// Prepares an AirPlay-safe HLS stream. This is an intentional output
    /// route decision rather than an automatic quality default: local playback
    /// remains direct-play first, while an explicitly selected AirPlay receiver
    /// gets an AVPlayer-compatible stream with no bitrate or resolution cap.
    func airPlayStreamURL(
        itemID: String,
        mediaIndex: Int,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: String? = nil,
        subtitleStreamID: String? = nil,
        serverID: String? = nil
    ) async throws -> ServerStream {
        try await openServerStream(
            itemID: itemID,
            mediaIndex: mediaIndex,
            intent: .airPlay,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            serverID: serverID
        )
    }

    /// Asks for an fMP4 HLS remux (`.losslessRemux`), or with `convertsAudio`
    /// one that converts the audio to E-AC-3 (`.convertedAudioRemux`). Plex
    /// picks the session's subtitle from the part's server-side selection, so
    /// the caller sets that first (`selectStreams(partID:...)`). The stream's
    /// `decisions` let the caller validate copy/conversion and codecs before
    /// loading it.
    func spatialAudioRemuxURL(
        itemID: String,
        mediaIndex: Int,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: String?,
        subtitleStreamID: String?,
        convertsAudio: Bool = false,
        serverID: String? = nil
    ) async throws -> ServerStream {
        try await openServerStream(
            itemID: itemID,
            mediaIndex: mediaIndex,
            intent: convertsAudio ? .convertedAudioRemux(target: .surroundEAC3) : .losslessRemux,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            serverID: serverID
        )
    }

    func openServerStream(
        itemID: String,
        mediaIndex: Int,
        intent: StreamIntent,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: String?,
        subtitleStreamID: String?,
        serverID: String?
    ) async throws -> ServerStream {
        try await playback(for: serverID).openServerStream(
            ServerStreamRequest(
                itemID: itemID,
                mediaIndex: mediaIndex,
                intent: intent,
                playbackSessionID: sessionIdentifier,
                streamSessionID: transcodeSessionID,
                audioStreamID: audioStreamID,
                subtitle: subtitleStreamID.map { .stream(id: $0, delivery: intent.subtitleDelivery) } ?? .none
            )
        )
    }

    /// The post-start check of a `.predicted` stream; nil when there is
    /// nothing to check.
    func confirmServerStream(_ stream: ServerStream, serverID: String?) async -> StreamDecisions? {
        guard stream.proof == .predicted else { return nil }
        return await playback(for: serverID).confirm(stream)
    }

    /// Records the viewer's audio/subtitle choice for the next stream of the
    /// part (see `PlaybackProviding.prepareTrackSelection`).
    /// `subtitleStreamID: "0"` clears the subtitle selection.
    func selectStreams(
        partID: String,
        audioStreamID: String?,
        subtitleStreamID: String?,
        serverID: String? = nil
    ) async throws {
        try await enqueueStreamSelection(
            partID: partID, audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID, serverID: serverID
        ).value
        try Task.checkCancellation()
    }

    /// Enqueue synchronously so quick picker changes and remux rebuilds share
    /// one write order. A late PUT must never undo a newer subtitle On/Off.
    func enqueueStreamSelection(
        partID: String,
        audioStreamID: String?,
        subtitleStreamID: String?,
        serverID: String?
    ) -> Task<Void, Error> {
        let previous = streamSelectionWriteTask
        let session = serverSessionToken
        let task = Task { @MainActor [weak self] in
            _ = try? await previous?.value
            guard let self, session == self.serverSessionToken else { throw CancellationError() }
            try await self.playback(for: serverID).prepareTrackSelection(
                TrackSelection(audioStreamID: audioStreamID, subtitleStreamID: subtitleStreamID),
                partID: partID
            )
        }
        streamSelectionWriteTask = task
        return task
    }

    /// Starts an HLS consumer for an already-tuned Live TV session.
    func liveTVStreamURL(
        sessionPath: String,
        sessionIdentifier: String,
        transcodeSessionID: String,
        serverID: String? = nil
    ) async throws -> ServerStream {
        try await plexPlayback(for: serverID).liveStream(
            sessionPath: sessionPath,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID
        )
    }

    /// Live TV direct play of the tuned session's own HLS; nil when the server
    /// does not offer it (see `PlexPlayback.liveDirectPlayURL`).
    func liveTVDirectPlayURL(
        sessionPath: String,
        sessionIdentifier: String,
        serverID: String
    ) async -> URL? {
        await plexPlayback(for: serverID).liveDirectPlayURL(
            sessionPath: sessionPath,
            sessionIdentifier: sessionIdentifier
        )
    }

    /// Releases a finished stream on the server. Best effort, never throws.
    func stopTranscodeSession(transcodeSessionID: String, serverID: String? = nil) async {
        await playback(for: serverID).close(streamSessionID: transcodeSessionID)
    }

    /// Keep-alive for an active stream. Best effort, never throws.
    func pingTranscodeSession(transcodeSessionID: String, serverID: String? = nil) async {
        await playback(for: serverID).keepAlive(streamSessionID: transcodeSessionID)
    }

    func sanitizedPlaybackURLString(for url: URL) -> String {
        PlexPlayback.sanitizedURLString(for: url)
    }

    /// Pure request construction (`PlexPlayback.transcodeQueryItems`) with
    /// this service's client identifier, for the codec-policy tests.
    func transcodeQueryItems(
        itemID: String,
        mediaIndex: Int,
        sourcePath: String?,
        intent: StreamIntent,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: String?,
        subtitleStreamID: String?,
        token: String?,
        av1Capabilities: AV1PlaybackCapabilities = .current
    ) -> [URLQueryItem] {
        PlexPlayback.transcodeQueryItems(
            itemID: itemID,
            mediaIndex: mediaIndex,
            sourcePath: sourcePath,
            intent: intent,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            token: token,
            clientIdentifier: clientIdentifier,
            av1Capabilities: av1Capabilities
        )
    }
}
