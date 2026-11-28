import Foundation
import OSLog

/// Plex's `SubtitleSearchProviding`: `/library/metadata/{id}/subtitles`.
///
/// Plex Media Server proxies OpenSubtitles, so Dusk needs no OpenSubtitles
/// account, API key or rate-limit handling of its own. The server searches,
/// downloads the chosen file, writes it as a sidecar next to the media and
/// refreshes the item. Afterwards the new track appears in the item's details
/// as a subtitle `MediaStream` with a `key` (`/library/streams/{id}`).
///
/// Every request goes to `serverID` through `transport` (`PlexServerTransport`).
struct PlexSubtitleSearch: SubtitleSearchProviding {
    let serverID: String?
    /// nil on a provider built without routing; every call then throws.
    let transport: (any PlexServerTransport)?

    /// Server-side provider downloads are slower than a metadata read.
    ///
    /// The shared `URLSession` caps `timeoutIntervalForResource` at 30s, so
    /// this is the practical ceiling; raising it further would need a
    /// session-level change, which would slow down every other call's failure
    /// detection.
    static let installTimeout: TimeInterval = 30

    /// - Parameter languageCode: Plex Web sends ISO 639-1 (`en`, `de`);
    ///   current servers also accept ISO 639-2 (`eng`, `ger`). Trimmed and
    ///   lowercased, otherwise passed through.
    /// - Returns: Some servers answer `size: 0` with no `Stream` array at all.
    func search(
        itemID: String,
        languageCode: String,
        hearingImpaired: Bool,
        forced: Bool
    ) async throws -> [SubtitleSearchResult] {
        let transport = try requireTransport()
        let language = languageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let data = try await transport.rawServerRequest(
            method: "GET",
            path: "/library/metadata/\(itemID)/subtitles",
            queryItems: [
                URLQueryItem(name: "language", value: language),
                URLQueryItem(name: "hearingImpaired", value: hearingImpaired ? "1" : "0"),
                URLQueryItem(name: "forced", value: forced ? "1" : "0"),
            ],
            timeoutInterval: nil,
            serverID: serverID
        )
        let response = try transport.decodeJSON(
            StreamResponse<PlexSubtitleSearchResultDTO>.self,
            from: data,
            serverID: serverID
        )
        let results = (response.MediaContainer.Stream ?? []).map(PlexUserContentMapper.subtitleSearchResult)

        subtitleSearchLogger.debug(
            "Subtitle search for \(itemID, privacy: .public) [\(language, privacy: .public)] returned \(results.count, privacy: .public) result(s)"
        )
        return results
    }

    /// `PUT` to the search path with the result's `key`. Optional parameters
    /// are only sent when the result carries them, matching what Plex Web does.
    /// Blocks for as long as the provider takes; several seconds is normal.
    func install(_ result: SubtitleSearchResult, itemID: String) async throws {
        let transport = try requireTransport()
        _ = try await transport.rawServerRequest(
            method: "PUT",
            path: "/library/metadata/\(itemID)/subtitles",
            queryItems: Self.installQueryItems(for: result),
            timeoutInterval: Self.installTimeout,
            serverID: serverID
        )

        subtitleSearchLogger.notice(
            "Installed subtitle \(result.id, privacy: .public) on \(itemID, privacy: .public)"
        )
    }

    static func installQueryItems(for result: SubtitleSearchResult) -> [URLQueryItem] {
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
        return queryItems
    }

    @MainActor private func requireTransport() throws -> any PlexServerTransport {
        guard let transport else { throw MediaServiceError.noServerConnected }
        return transport
    }
}

extension PlexServerProvider {
    /// Sends through the account's routed send (`PlexServerRouter`).
    var subtitleSearch: (any SubtitleSearchProviding)? {
        PlexSubtitleSearch(serverID: routedServerID, transport: router)
    }
}
