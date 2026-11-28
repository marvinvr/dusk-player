import Foundation

/// The active profile's account language settings (plex.tv → Account →
/// Languages for Plex), routed to the account's `AccountPreferencesProviding`
/// (docs/jellyfin/04-architecture.md §13). Dusk uses them as defaults for
/// Settings › Audio & Subtitles until the viewer picks something in Dusk.
extension MediaService {
    /// Best-effort read of the active profile's language settings. nil on any
    /// failure; callers keep whatever defaults they already have.
    func fetchAccountLanguageDefaults() async -> AccountLanguageDefaults? {
        do {
            return try await accountPreferences.languageDefaults()
        } catch {
            plexAuthLogger.notice(
                "Account language lookup failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
