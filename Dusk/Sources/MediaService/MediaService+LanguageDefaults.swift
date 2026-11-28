import Foundation

/// The language settings of the active Plex account (plex.tv → Account →
/// Languages), translated into Dusk's terms. Dusk uses them as defaults for
/// Settings › Audio & Subtitles until the viewer picks something in Dusk.
struct PlexAccountLanguageDefaults: Equatable, Sendable {
    /// "" when the account turns automatic audio selection off (keep the
    /// title's original audio), nil when the account says nothing.
    var audioLanguage: String?
    var subtitleLanguage: String?
    var subtitleMode: SubtitleMode?

    /// The `profile` object of `GET https://plex.tv/api/v2/user`:
    /// `autoSelectAudio` (bool), `defaultAudioLanguage`,
    /// `defaultSubtitleLanguage` (ISO 639-1, sometimes with a region) and
    /// `autoSelectSubtitle` (0 manually selected, 1 shown with foreign audio,
    /// 2 always enabled). Plex has sent the numeric fields as numbers, strings
    /// and booleans over the years, so each one is read leniently.
    struct Profile: Decodable, Sendable {
        let autoSelectAudio: Bool?
        let defaultAudioLanguage: String?
        let defaultSubtitleLanguage: String?
        let autoSelectSubtitle: Int?

        enum CodingKeys: String, CodingKey {
            case autoSelectAudio, defaultAudioLanguage, defaultSubtitleLanguage, autoSelectSubtitle
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            autoSelectAudio = Self.lenientInt(container, .autoSelectAudio).map { $0 != 0 }
            defaultAudioLanguage = try? container.decodeIfPresent(String.self, forKey: .defaultAudioLanguage)
            defaultSubtitleLanguage = try? container.decodeIfPresent(String.self, forKey: .defaultSubtitleLanguage)
            autoSelectSubtitle = Self.lenientInt(container, .autoSelectSubtitle)
        }

        private static func lenientInt(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value ? 1 : 0 }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(value) ?? (value == "true" ? 1 : value == "false" ? 0 : nil)
            }
            return nil
        }
    }

    init(audioLanguage: String?, subtitleLanguage: String?, subtitleMode: SubtitleMode?) {
        self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage
        self.subtitleMode = subtitleMode
    }

    init(profile: Profile) {
        let audioLanguage = profile.defaultAudioLanguage.flatMap(UserPreferences.normalizedLanguageCode(from:))
        self.audioLanguage = profile.autoSelectAudio == false ? "" : audioLanguage
        subtitleLanguage = profile.defaultSubtitleLanguage.flatMap(UserPreferences.normalizedLanguageCode(from:))
        subtitleMode = switch profile.autoSelectSubtitle {
        case 0: .off
        case 1: .auto
        case 2: .always
        default: nil
        }
    }
}

extension MediaService {
    private struct AccountLanguageResponse: Decodable {
        let profile: PlexAccountLanguageDefaults.Profile?
    }

    /// Best-effort read of the active profile's Plex language settings. nil on
    /// any failure; callers keep whatever defaults they already have.
    func fetchAccountLanguageDefaults() async -> PlexAccountLanguageDefaults? {
        guard activeAccountToken != nil else { return nil }
        do {
            let account: AccountLanguageResponse = try await plexTVRequest(path: "/api/v2/user")
            return account.profile.map(PlexAccountLanguageDefaults.init(profile:))
        } catch {
            plexAuthLogger.notice(
                "Account language lookup failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
