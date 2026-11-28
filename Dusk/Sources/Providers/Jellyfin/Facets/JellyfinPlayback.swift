import Foundation

/// Jellyfin's playback (docs/jellyfin/04-architecture.md §12): direct play on
/// both engines and sidecar subtitles. Server streams (remux, quality,
/// AirPlay) are J-06; until then `openServerStream` throws, which the ladder
/// treats like any declined remux and plays the file directly. Pre-rolls
/// (`/Items/{id}/Intros`) are J-11.
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

    func openServerStream(_ request: ServerStreamRequest) async throws -> ServerStream {
        throw MediaServiceError.notImplemented
    }

    func confirm(_ stream: ServerStream) async -> StreamDecisions? { nil }

    func keepAlive(streamSessionID: String) async {}

    func close(streamSessionID: String) async {}

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

    func prerolls(before itemID: String) async throws -> [MediaDetails] { [] }

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
