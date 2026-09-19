import Foundation
import OSLog

private let plexSubtitlesLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexSubtitles"
)

/// Server-side subtitle search and download.
///
/// Plex Media Server proxies OpenSubtitles for us, so Dusk needs no
/// OpenSubtitles account, API key, or rate-limit handling of its own. The server
/// searches, downloads the chosen file, writes it as a sidecar next to the media,
/// and refreshes the item. Afterwards the new track appears in
/// `getMediaDetails(ratingKey:)` as a `PlexStream` with `streamType == .subtitle`
/// and a non-nil `key` (`/library/streams/{id}`), which `externalSubtitleURL(for:)`
/// turns into a URL the playback engine can attach as a slave.
extension PlexService {
    /// Asks the server to search its subtitle providers (OpenSubtitles) for the item.
    ///
    /// - Parameters:
    ///   - ratingKey: Library item to search subtitles for.
    ///   - languageCode: Language filter. Plex Web sends ISO 639-1 (`en`, `de`);
    ///     current servers also accept ISO 639-2 (`eng`, `ger`). The value is
    ///     trimmed and lowercased and otherwise passed through untouched, so
    ///     callers may use either form. Prefer 639-1 to match Plex Web.
    ///   - hearingImpaired: Restrict to SDH/HI results.
    ///   - forced: Restrict to forced-narrative results.
    /// - Returns: Candidates in the server's order (best match first), or an
    ///   empty array when the provider has nothing — some servers answer
    ///   `size: 0` with no `Stream` array at all.
    func searchSubtitles(
        ratingKey: String,
        languageCode: String,
        hearingImpaired: Bool = false,
        forced: Bool = false,
        serverID: String? = nil
    ) async throws -> [PlexSubtitleSearchResult] {
        let language = languageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let queryItems = [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "hearingImpaired", value: hearingImpaired ? "1" : "0"),
            URLQueryItem(name: "forced", value: forced ? "1" : "0"),
        ]

        let targetID = try resolveServerID(serverID)
        let data = try await rawServerRequest(
            path: "/library/metadata/\(ratingKey)/subtitles",
            queryItems: queryItems,
            serverID: targetID
        )
        let response = try decodeJSON(
            StreamResponse<PlexSubtitleSearchResult>.self,
            from: data,
            serverID: targetID
        )
        let results = response.MediaContainer.Stream ?? []

        plexSubtitlesLogger.debug(
            "Subtitle search for \(ratingKey, privacy: .public) [\(language, privacy: .public)] returned \(results.count, privacy: .public) result(s)"
        )
        return results
    }

    /// Asks the server to download a search result and install it as a sidecar
    /// next to the media file.
    ///
    /// The server does the fetching, so this call blocks for as long as the
    /// provider takes — several seconds is normal. It returns once the server
    /// answers 200 (the body is empty or trivial). The new track is *not* in the
    /// response: refetch `getMediaDetails(ratingKey:)` afterwards to pick it up.
    ///
    /// Optional parameters are only sent when the result carries them, matching
    /// what Plex Web does.
    func downloadSubtitle(
        ratingKey: String,
        result: PlexSubtitleSearchResult,
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
            path: "/library/metadata/\(ratingKey)/subtitles",
            queryItems: queryItems,
            timeoutInterval: Self.subtitleDownloadTimeout,
            serverID: serverID
        )

        plexSubtitlesLogger.notice(
            "Installed subtitle \(result.id, privacy: .public) on \(ratingKey, privacy: .public)"
        )
    }

    /// Token-bearing URL for a sidecar subtitle stream, suitable for VLCKit's
    /// `addPlaybackSlave` (or any direct fetch).
    ///
    /// Returns nil for embedded streams: only external (sidecar) subtitle
    /// streams carry a `key`, and embedded tracks are selected in the engine
    /// instead of fetched.
    func externalSubtitleURL(for stream: PlexStream, serverID: String? = nil) -> URL? {
        guard stream.streamType == .subtitle, let key = stream.key?.nilIfEmpty else { return nil }
        guard let connection = pool.connection(for: serverID) else {
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

        guard let url = components.url else {
            plexSubtitlesLogger.error(
                "Failed to finalize external subtitle URL for stream \(stream.id, privacy: .public)"
            )
            return nil
        }

        plexSubtitlesLogger.debug(
            "Constructed external subtitle URL for stream \(stream.id, privacy: .public): \(self.sanitizedPlaybackURLString(for: url), privacy: .public)"
        )
        return url
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
        return connection.owned && activeHomeUser?.isRestricted != true
    }

    /// Server-side provider downloads are slower than a metadata read.
    ///
    /// Note: the shared `URLSession` caps `timeoutIntervalForResource` at 30s, so
    /// this is the practical ceiling — raising it further would need a
    /// session-level change, which would slow down every other call's failure
    /// detection.
    private static var subtitleDownloadTimeout: TimeInterval { 30 }
}
