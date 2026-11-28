import Foundation

/// Server-side subtitle search and download, routed to the item's server's
/// `SubtitleSearchProviding` (docs/jellyfin/04-architecture.md §13), and the
/// sidecar URL the engines attach.
///
/// The server searches its providers (OpenSubtitles), downloads the chosen
/// file and writes it next to the media. The new track is not in the install
/// answer: callers refetch `getMediaDetails(itemID:)`, where it appears as an
/// external subtitle `MediaStream` that `externalSubtitleURL(for:)` turns into
/// a URL the engine can attach.
extension MediaService {
    /// Asks the item's server to search its subtitle providers.
    ///
    /// - Parameters:
    ///   - languageCode: ISO 639-1 (`en`, `de`).
    ///   - hearingImpaired: Restrict to SDH/HI results.
    ///   - forced: Restrict to forced-narrative results.
    /// - Returns: Candidates in the server's order (best match first), or an
    ///   empty array when the provider has nothing.
    func searchSubtitles(
        itemID: String,
        languageCode: String,
        hearingImpaired: Bool = false,
        forced: Bool = false,
        serverID: String? = nil
    ) async throws -> [SubtitleSearchResult] {
        try await subtitleSearch(on: serverID).search(
            itemID: itemID,
            languageCode: languageCode,
            hearingImpaired: hearingImpaired,
            forced: forced
        )
    }

    /// Asks the server to download a search result and install it as a
    /// sidecar next to the media file. Blocks for as long as the provider
    /// takes (several seconds is normal) and returns once the server answers.
    func downloadSubtitle(
        itemID: String,
        result: SubtitleSearchResult,
        serverID: String? = nil
    ) async throws {
        try await subtitleSearch(on: serverID).install(result, itemID: itemID)
    }

    /// Token-bearing URL for a sidecar subtitle stream, suitable for VLCKit's
    /// `addPlaybackSlave` (or any direct fetch).
    ///
    /// Returns nil for embedded streams: only external (sidecar) subtitle
    /// streams carry a `key`, and embedded tracks are selected in the engine
    /// instead of fetched.
    func externalSubtitleURL(for stream: MediaStream, serverID: String? = nil) -> URL? {
        playback(for: serverID).sidecarSubtitleURL(for: stream)
    }

    /// Whether this session may search for and install subtitles on one server.
    ///
    /// The server has to offer subtitle search and the signed-in user has to
    /// be allowed to write sidecars: on Plex only the server owner on an
    /// unrestricted profile, on Jellyfin a user with subtitle management.
    /// Everyone else never sees the affordance, rather than an action that
    /// fails with a 403.
    ///
    /// Per server on purpose: the account can own one server and merely be
    /// shared another, so the answer differs per item.
    func canDownloadSubtitles(serverID: String?) -> Bool {
        guard let connection = pool.connection(for: serverID) else { return false }
        let provider = serverProvider(for: connection.serverID)
        return provider.subtitleSearch != nil && provider.permissions.canInstallSubtitles
    }

    private func subtitleSearch(on serverID: String?) throws -> any SubtitleSearchProviding {
        guard let facet = serverProvider(for: try resolveServerID(serverID)).subtitleSearch else {
            throw MediaServiceError.notImplemented
        }
        return facet
    }
}
