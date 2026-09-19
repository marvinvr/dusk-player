import Foundation

/// Drives the "Download Subtitles" flow: pick a language, ask Plex to search its
/// providers (OpenSubtitles), then ask it to install the chosen result as a
/// sidecar next to the media file.
///
/// Views never touch `PlexService` themselves. Whoever presents the flow passes
/// an `onDownloaded` completion — the player refreshes the live session's
/// subtitle streams, detail screens re-read their media details.
@MainActor
@Observable
final class SubtitleSearchViewModel {
    /// One state at a time. `results` survives an `.error` raised by a failed
    /// download, so the list stays usable and the view can show the message
    /// inline instead of replacing everything.
    enum Phase: Equatable {
        case idle
        case searching
        case empty
        case error(String)
        /// Carries `PlexSubtitleSearchResult.id` so only that row spins.
        case downloading(String)
        case downloaded
    }

    private let plexService: PlexService
    private let onDownloaded: (PlexSubtitleSearchResult) async -> Void

    let ratingKey: String
    /// The server the item lives on; nil means the primary one.
    let serverID: String?

    var language: CommonLanguage
    var hearingImpaired = false
    private(set) var results: [PlexSubtitleSearchResult] = []
    private(set) var phase: Phase = .idle

    /// Guards against a stale search landing after a newer one.
    private var searchGeneration = 0

    init(
        plexService: PlexService,
        ratingKey: String,
        serverID: String? = nil,
        preferredLanguageCode: String?,
        onDownloaded: @escaping (PlexSubtitleSearchResult) async -> Void
    ) {
        self.plexService = plexService
        self.ratingKey = ratingKey
        self.serverID = serverID
        self.onDownloaded = onDownloaded
        self.language = Self.defaultLanguage(preferredCode: preferredLanguageCode)
    }

    // MARK: - Derived state

    var isSearching: Bool { phase == .searching }

    var downloadingResultID: String? {
        if case let .downloading(id) = phase { return id }
        return nil
    }

    var isDownloading: Bool { downloadingResultID != nil }

    var errorMessage: String? {
        if case let .error(message) = phase { return message }
        return nil
    }

    var didDownload: Bool { phase == .downloaded }

    /// Controls that must not fire while a search or a download is in flight.
    var isBusy: Bool { isSearching || isDownloading }

    // MARK: - Actions

    func search() async {
        guard !isDownloading else { return }

        searchGeneration += 1
        let generation = searchGeneration
        phase = .searching
        results = []

        do {
            // Server order is the match ranking (best first). Never re-sort it.
            let found = try await plexService.searchSubtitles(
                ratingKey: ratingKey,
                languageCode: language.code,
                hearingImpaired: hearingImpaired,
                serverID: serverID
            )
            guard generation == searchGeneration else { return }
            results = found
            phase = found.isEmpty ? .empty : .idle
        } catch {
            guard generation == searchGeneration else { return }
            phase = .error(error.localizedDescription)
        }
    }

    /// Clears the current results when the query changes, so a stale list is
    /// never shown next to a different language.
    func queryDidChange() {
        searchGeneration += 1
        results = []
        phase = .idle
    }

    func download(_ result: PlexSubtitleSearchResult) async {
        guard !isBusy else { return }

        phase = .downloading(result.id)
        do {
            try await plexService.downloadSubtitle(
                ratingKey: ratingKey,
                result: result,
                serverID: serverID
            )
            phase = .downloaded
            await onDownloaded(result)
        } catch {
            // The 30s ceiling reports "may still have worked", so the list stays
            // up and the message rides above it rather than replacing it.
            phase = .error(error.localizedDescription)
        }
    }

    /// Dismisses an inline error without throwing away the results.
    func clearError() {
        guard errorMessage != nil else { return }
        phase = .idle
    }

    // MARK: - Default language

    /// The saved subtitle preference wins, then the device language when it is
    /// one of the offered languages, then English.
    static func defaultLanguage(preferredCode: String?) -> CommonLanguage {
        if let preferredCode,
           let match = CommonLanguage(rawValue: preferredCode.lowercased()) {
            return match
        }

        if let deviceCode = Locale.current.language.languageCode?.identifier.lowercased(),
           let match = CommonLanguage(rawValue: deviceCode) {
            return match
        }

        return .english
    }
}
