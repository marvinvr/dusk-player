import Foundation
import OSLog

/// Server-side subtitle search and download.
///
/// Plex Media Server proxies OpenSubtitles for us, so Dusk needs no
/// OpenSubtitles account, API key, or rate-limit handling of its own. The server
/// searches, downloads the chosen file, writes it as a sidecar next to the media,
/// and refreshes the item. Afterwards the new track appears in
/// `getMediaDetails(itemID:)` as a `MediaStream` with `kind == .subtitle`
/// and a non-nil `key` (`/library/streams/{id}`), which `externalSubtitleURL(for:)`
/// turns into a URL the playback engine can attach as a slave.
extension MediaService {

    /// Asks the server to download a search result and install it as a sidecar
    /// next to the media file.
    ///
    /// The server does the fetching, so this call blocks for as long as the
    /// provider takes — several seconds is normal. It returns once the server
    /// answers 200 (the body is empty or trivial). The new track is *not* in the
    /// response: refetch `getMediaDetails(itemID:)` afterwards to pick it up.
    ///
    /// Optional parameters are only sent when the result carries them, matching
    /// what Plex Web does.
    func downloadSubtitle(
        itemID: String,
        result: SubtitleSearchResult,
        serverID: String? = nil
    ) async throws {
        var queryItems = [URLQueryItem(name: "key", value: result.key)]

        if let codec = result.codec ?? result.format {
            queryItems.append(URLQueryItem(name: "codec", value: codec))
        }
        if let languageCode = result.languageCode {
            queryItems.append(URLQueryItem(name: "language", value: languageCode))
        }
        if let isHearingImpaired = result.isHearingImpaired {
            queryItems.append(URLQueryItem(name: "hearingImpaired", value: isHearingImpaired ? "1" : "0"))
        }
        if let isForced = result.isForced {
            queryItems.append(URLQueryItem(name: "forced", value: isForced ? "1" : "0"))
        }
        if let providerTitle = result.providerTitle {
            queryItems.append(URLQueryItem(name: "providerTitle", value: providerTitle))
        }
        if let title = result.title {
            queryItems.append(URLQueryItem(name: "title", value: title))
        }

        _ = try await rawServerRequest(
            method: "PUT",
            path: "/library/metadata/\(itemID)/subtitles",
            queryItems: queryItems,
            timeoutInterval: Self.subtitleDownloadTimeout,
            serverID: serverID
        )

        subtitleSearchLogger.notice(
            "Installed subtitle \(result.id, privacy: .public) on \(itemID, privacy: .public)"
        )
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
    /// Plex only lets the server owner write sidecar files, and restricted Home
    /// users (managed/child profiles) are blocked as well. Users on a shared
    /// server therefore never see the affordance — hide the entry point rather
    /// than showing an action that fails with a 403.
    ///
    /// Per server on purpose: the account can own one server and merely be
    /// shared another, so the answer differs per item.
    func canDownloadSubtitles(serverID: String?) -> Bool {
        guard let connection = pool.connection(for: serverID) else { return false }
        return serverProvider(for: connection.serverID).permissions.canInstallSubtitles
    }

    /// Server-side provider downloads are slower than a metadata read.
    ///
    /// Note: the shared `URLSession` caps `timeoutIntervalForResource` at 30s, so
    /// this is the practical ceiling — raising it further would need a
    /// session-level change, which would slow down every other call's failure
    /// detection.
    private static var subtitleDownloadTimeout: TimeInterval { 30 }
}
