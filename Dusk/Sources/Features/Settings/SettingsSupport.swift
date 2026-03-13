import SwiftUI

enum SettingsSupport {
    static let playbackDefaultsFooterText = "Choose preferred stream quality and default audio or subtitle languages. Forced Only limits automatic subtitle selection to forced tracks."

    #if os(tvOS)
    static let playbackBehaviorFooterText = "Continuous Play shows an Up Next screen after TV episodes finish and can auto-start the next one after the configured delay. Pause After counts the current episode too, then pauses autoplay until you confirm."
    #else
    static let playbackBehaviorFooterText = "Continuous Play shows an Up Next screen after TV episodes finish and can auto-start the next one after the configured delay. Pause After counts the current episode too, then pauses autoplay until you confirm. Double-Tap to Seek adds left and right double-tap seek zones in the player."
    #endif

    static let playbackAdvancedFooterText = "Force AVPlayer and Force VLCKit bypass automatic engine selection. Enabling one disables the other. Force AVPlayer may fail on formats it cannot handle. Player Debug Overlay shows stream stats during playback."
    static let appearanceFooterText = "System follows your device appearance. Light and Dark override it for the whole app."
    static let accountFooterText = "Clears the saved Plex session and returns to the sign-in flow."

    static var subtitleLanguageOptions: [String] {
        [""] + CommonLanguage.allCases.map(\.code)
    }

    static var audioLanguageOptions: [String] {
        CommonLanguage.allCases.map(\.code)
    }

    static var passoutProtectionEpisodeOptions: [Int?] {
        [nil] + Array(1...10).map(Optional.some)
    }

    static func subtitleLanguageBinding(_ preferences: UserPreferences) -> Binding<String> {
        Binding(
            get: { preferences.defaultSubtitleLanguage ?? "" },
            set: { preferences.defaultSubtitleLanguage = $0.isEmpty ? nil : $0 }
        )
    }

    static func subtitleDisplayName(for code: String) -> String {
        code.isEmpty ? "None" : languageDisplayName(for: code)
    }

    static func languageDisplayName(for code: String) -> String {
        CommonLanguage(rawValue: code)?.displayName ?? code.uppercased()
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
        case .turkish: "Turkish"
        case .thai: "Thai"
        case .vietnamese: "Vietnamese"
        case .indonesian: "Indonesian"
        case .malay: "Malay"
        case .hebrew: "Hebrew"
        }
    }
}
