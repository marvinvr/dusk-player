import Foundation

/// Searching for subtitles and installing one on the server
/// (docs/jellyfin/04-architecture.md §13). The server does the searching and
/// writes the file next to the media; afterwards the new track is in the
/// item's details as an external subtitle stream, so callers refetch and mount
/// it. Whether the signed-in user may do this is
/// `ServerPermissions.canInstallSubtitles`.
protocol SubtitleSearchProviding: Sendable {
    /// Candidates in the server's order (best match first); empty when its
    /// providers have nothing. `languageCode` is ISO 639-1 (`en`, `de`).
    @MainActor func search(
        itemID: String,
        languageCode: String,
        hearingImpaired: Bool,
        forced: Bool
    ) async throws -> [SubtitleSearchResult]

    /// Downloads `result` onto the server as a sidecar of `itemID`. Returns
    /// once the server answered; the new track is not in the answer.
    @MainActor func install(_ result: SubtitleSearchResult, itemID: String) async throws
}
