import Foundation

/// The `profile` object of `GET https://plex.tv/api/v2/user`:
/// `autoSelectAudio` (bool), `defaultAudioLanguage`,
/// `defaultSubtitleLanguage` (ISO 639-1, sometimes with a region) and
/// `autoSelectSubtitle` (0 manually selected, 1 shown with foreign audio,
/// 2 always enabled). Plex has sent the numeric fields as numbers, strings
/// and booleans over the years, so each one is read leniently. Mapped to
/// `AccountLanguageDefaults` by `PlexAccountPreferences.languageDefaults(from:)`.
struct PlexAccountProfileDTO: Decodable, Sendable {
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
