import Foundation
import OSLog

private let jellyfinSubtitleSearchLogger = Logger(subsystem: "app.dusk", category: "JellyfinSubtitleSearch")

/// Jellyfin's `SubtitleSearchProviding` (02 §10): the server's subtitle
/// plugins (OpenSubtitles) behind `/Items/{id}/RemoteSearch/Subtitles`.
///
/// Only users with `Policy.EnableSubtitleManagement` (or administrators) may
/// call it (`ServerPermissions.canInstallSubtitles`); others get `403`. A
/// server without a subtitle plugin answers every search with `[]`. A
/// download adds an external subtitle stream to the item, which the next
/// details read lists.
struct JellyfinSubtitleSearch: SubtitleSearchProviding {
    let server: JellyfinServerProvider

    /// The server has no hearing-impaired or forced filter; both narrow the
    /// results here, in the server's order.
    @MainActor
    func search(
        itemID: String,
        languageCode: String,
        hearingImpaired: Bool,
        forced: Bool
    ) async throws -> [SubtitleSearchResult] {
        let client = try server.client()
        let language = JellyfinLanguageCodes.threeLetter(languageCode)
        let found = try await client.send(JellyfinAPI.searchRemoteSubtitles(itemID: itemID, language: language))
        let results = found
            .filter { !hearingImpaired || $0.hearingImpaired == true }
            .filter { !forced || $0.forced == true }
            .map(Self.result(for:))
        jellyfinSubtitleSearchLogger.debug(
            "Subtitle search for \(itemID, privacy: .public) [\(language, privacy: .public)] returned \(results.count, privacy: .public) result(s)"
        )
        return results
    }

    @MainActor
    func install(_ result: SubtitleSearchResult, itemID: String) async throws {
        let client = try server.client()
        _ = try await client.send(JellyfinAPI.downloadRemoteSubtitle(itemID: itemID, subtitleID: result.key))
        jellyfinSubtitleSearchLogger.notice(
            "Installed subtitle \(result.id, privacy: .public) on \(itemID, privacy: .public)"
        )
    }

    /// The result id is the download handle.
    static func result(for dto: JellyfinRemoteSubtitleInfoDTO) -> SubtitleSearchResult {
        let languageCode = JellyfinLanguageCodes.twoLetter(dto.threeLetterISOLanguageName)
        return SubtitleSearchResult(
            id: dto.id,
            key: dto.id,
            codec: dto.format?.nilIfEmpty,
            title: dto.name?.nilIfEmpty,
            providerTitle: dto.providerName?.nilIfEmpty,
            sourceTitle: dto.comment?.nilIfEmpty,
            score: nil,
            languageCode: dto.threeLetterISOLanguageName?.nilIfEmpty,
            language: languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) },
            isHearingImpaired: dto.hearingImpaired,
            isForced: dto.forced,
            format: dto.format?.nilIfEmpty
        )
    }
}
