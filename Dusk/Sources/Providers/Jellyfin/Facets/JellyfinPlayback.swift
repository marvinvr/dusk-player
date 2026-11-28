import Foundation

/// Jellyfin's playback. Placeholder until J-05 (direct play) and J-06
/// (server streams): nothing plays yet.
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

    nonisolated var credentialPolicy: any CredentialTransportPolicy { TransportSecurity.defaultPolicy }

    func directPlayURL(for part: MediaPart) -> URL? { nil }

    func checkAccess(to url: URL) async -> PlaybackAccess { .allowed }

    func openServerStream(_ request: ServerStreamRequest) async throws -> ServerStream {
        throw MediaServiceError.notImplemented
    }

    func confirm(_ stream: ServerStream) async -> StreamDecisions? { nil }

    func keepAlive(streamSessionID: String) async {}

    func close(streamSessionID: String) async {}

    func prepareTrackSelection(_ selection: TrackSelection, partID: String) async throws {}

    func sidecarSubtitleURL(for stream: MediaStream) -> URL? { nil }

    func prerolls(before itemID: String) async throws -> [MediaDetails] { [] }
}
