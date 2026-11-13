import SwiftUI

enum SettingsSupport {
    static let integrationsFooterText = "Seerr adds requestable movies and shows to search."

    static let liveTVFooterText = "Channels from M3U playlists appear next to Plex Live TV."

    static func iptvSourcesSummary(_ count: Int) -> String {
        switch count {
        case 0: "None"
        case 1: "1 source"
        default: "\(count) sources"
        }
    }

    static let playbackDefaultsFooterText = "AI Upscaling can use more power."
    static let audioLanguageFooterText = "Until you change them here, languages follow your Plex account."
    static let subtitlesFooterText = "Auto turns subtitles on when the audio isn’t in your subtitle language."
    static let subtitlesAdvancedFooterText = "Forced subtitles translate foreign dialogue and signs."

    #if os(tvOS)
    static let playbackBehaviorFooterText = "Pause After includes the episode that’s playing."
    #else
    static let playbackBehaviorFooterText = "Episode Buttons add Previous and Next Episode to the player."
    #endif

    #if os(tvOS)
    static let playbackAdvancedFooterText = "Plex repackages Dolby and HDR titles without re-encoding, and Speed is off while Atmos goes to your receiver."
    #else
    static let playbackAdvancedFooterText = "Plex repackages Dolby and HDR titles for Apple’s player without re-encoding."
    #endif
    static let downloadsFooterText = "Preferred Version picks between a title’s versions, quality is chosen per download."
    static func pinnedPlaylistsSummary(_ count: Int) -> String {
        count == 0 ? "None" : String(count)
    }

    static let homeFooterText = "Personalized shelves are recommendations from Dusk, not Plex."
    static let homeAdvancedFooterText = "Swaps the large artwork at the top of Home for a Continue Watching row."
    static let privacyFooterText = "Sends anonymous events and error reports, never anything about your library, server, viewing or searches."
    static let supporterFooterText = "Supporting unlocks alternate app icons, and subscribing adds four exclusive ones."
    static let githubURL = URL(string: "https://github.com/marvinvr/dusk-player")!
    static let redditURL = URL(string: "https://www.reddit.com/r/DuskPlayer/")!
    static let aboutMeURL = URL(string: "https://marvinvr.ch")!
    static let feedbackURL = URL(string: "mailto:info@getdusk.app")!
    static let plexAccountURL = URL(string: "https://app.plex.tv/desktop/#!/settings/account")!
    static let privacyPolicyURL = URL(string: "https://getdusk.app/privacy/")!
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// Common languages plus the device language and the current choice
    /// (which may come from the Plex account) when they are not common ones.
    static func subtitleLanguageOptions(including current: String) -> [String] {
        var options = CommonLanguage.allCases.map(\.code)
        for code in [UserPreferences.systemPreferredSubtitleLanguageCode, current].compactMap({ $0 })
        where !code.isEmpty && !options.contains(code) {
            options.insert(code, at: 0)
        }
        return options
    }

    /// "" (Original) first, then the subtitle languages.
    static func audioLanguageOptions(including current: String) -> [String] {
        [""] + subtitleLanguageOptions(including: current)
    }

    static func audioLanguageDisplayName(for code: String) -> String {
        code.isEmpty ? "Original" : languageDisplayName(for: code)
    }

    @MainActor
    static func audioSubtitlesSummary(_ preferences: UserPreferences) -> String {
        "\(audioLanguageDisplayName(for: preferences.defaultAudioLanguage)) · Subtitles \(preferences.subtitleMode.displayName)"
    }

    static var passoutProtectionEpisodeOptions: [Int?] {
        [nil] + Array(1...10).map(Optional.some)
    }

    @MainActor
    static func libraryTabsSummary(_ preferences: UserPreferences) -> String {
        let visibleCount = preferences.libraryTabOrder.filter {
            preferences.isLibraryTabVisible($0)
        }.count

        if visibleCount == preferences.libraryTabOrder.count {
            return "All Visible"
        }
        return "\(visibleCount) Visible"
    }

    /// Names the server on a single-server account — the count would be noise
    /// there — and otherwise says how many of them Dusk is using.
    /// Counts only libraries Dusk can show; a music library hidden in Plex Web
    /// is not something this screen lists.
    @MainActor
    static func hiddenLibrariesSummary(_ plexService: PlexService) -> String {
        let hidden = plexService.libraryOrder.hiddenSectionIdentities
        let count = plexService.libraryOrder.sections.filter {
            $0.libraryType != nil && hidden.contains($0.id)
        }.count
        return count == 0 ? "None" : "\(count) Hidden"
    }

    @MainActor
    static func serverPrioritySummary(_ plexService: PlexService) -> String {
        let servers = plexService.pool.servers
        guard !servers.isEmpty else { return "" }

        if servers.count == 1, let name = servers.values.first?.name.nilIfEmpty {
            return name
        }

        let enabled = servers.keys.filter { plexService.serverPriority.isEnabled($0) }.count
        return enabled == servers.count ? "\(servers.count) Servers" : "\(enabled) of \(servers.count)"
    }

    static func languageDisplayName(for code: String) -> String {
        if let commonLanguage = CommonLanguage(rawValue: code) {
            return commonLanguage.displayName
        }

        return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    static func passoutProtectionDisplayName(for episodeLimit: Int?) -> String {
        guard let episodeLimit else { return "Disabled" }
        return episodeLimit == 1 ? "1 Episode" : "\(episodeLimit) Episodes"
    }
}

enum CommonLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case russian = "ru"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh"
    case arabic = "ar"
    case hindi = "hi"
    case swedish = "sv"
    case norwegian = "no"
    case danish = "da"
    case finnish = "fi"
    case polish = "pl"
    case czech = "cs"
    case romanian = "ro"
    case hungarian = "hu"
    case greek = "el"
    case ukrainian = "uk"
    case croatian = "hr"
    case bulgarian = "bg"
    case slovak = "sk"
    case serbian = "sr"
    case slovenian = "sl"
    case turkish = "tr"
    case thai = "th"
    case vietnamese = "vi"
    case indonesian = "id"
    case malay = "ms"
    case hebrew = "he"

    var id: String { rawValue }
    var code: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .portuguese: "Portuguese"
        case .dutch: "Dutch"
        case .russian: "Russian"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .chinese: "Chinese"
        case .arabic: "Arabic"
        case .hindi: "Hindi"
        case .swedish: "Swedish"
        case .norwegian: "Norwegian"
        case .danish: "Danish"
        case .finnish: "Finnish"
        case .polish: "Polish"
        case .czech: "Czech"
        case .romanian: "Romanian"
        case .hungarian: "Hungarian"
        case .greek: "Greek"
        case .ukrainian: "Ukrainian"
        case .croatian: "Croatian"
        case .bulgarian: "Bulgarian"
        case .slovak: "Slovak"
        case .serbian: "Serbian"
        case .slovenian: "Slovenian"
        case .turkish: "Turkish"
        case .thai: "Thai"
        case .vietnamese: "Vietnamese"
        case .indonesian: "Indonesian"
        case .malay: "Malay"
        case .hebrew: "Hebrew"
        }
    }
}
