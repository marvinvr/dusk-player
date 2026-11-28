import Foundation
import OSLog

/// Server-side subtitle search: Plex's `/library/metadata/{id}/subtitles`
/// (`SubtitleSearchProviding` has no members yet). Downloading a result, the
/// sidecar URL and the permission check stay in `MediaService+Subtitles`.
extension MediaService {
    /// Asks the server to search its subtitle providers (OpenSubtitles) for the item.
    ///
    /// - Parameters:
    ///   - itemID: Library item to search subtitles for.
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
        itemID: String,
        languageCode: String,
        hearingImpaired: Bool = false,
        forced: Bool = false,
        serverID: String? = nil
    ) async throws -> [SubtitleSearchResult] {
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
            path: "/library/metadata/\(itemID)/subtitles",
            queryItems: queryItems,
            serverID: targetID
        )
        let response = try decodeJSON(
            StreamResponse<PlexSubtitleSearchResultDTO>.self,
            from: data,
            serverID: targetID
        )
        let results = (response.MediaContainer.Stream ?? []).map(PlexUserContentMapper.subtitleSearchResult)

        subtitleSearchLogger.debug(
            "Subtitle search for \(itemID, privacy: .public) [\(language, privacy: .public)] returned \(results.count, privacy: .public) result(s)"
        )
        return results
    }
}
