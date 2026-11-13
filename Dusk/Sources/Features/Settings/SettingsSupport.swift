import SwiftUI

enum SettingsSupport {
    static func integrationsFooterText(showsTrakt: Bool) -> String {
        showsTrakt
            ? "Optionally add requestable movies and shows to search, or keep your Trakt history up to date."
            : "Optionally add requestable movies and shows to search."
    }

    static let liveTVFooterText = "Watch channels from standard M3U playlists beside Plex Live TV."

    static func iptvSourcesSummary(_ count: Int) -> String {
        switch count {
        case 0: "None"
        case 1: "1 source"
        default: "\(count) sources"
        }
    }

    static let playbackDefaultsFooterText = "Choose preferred stream quality. Preferred Version picks which version plays when a title has more than one. Audio & Subtitles sets the languages Dusk plays and when subtitles turn on. AI Upscaling sharpens lower-resolution video when the source benefits from it, but can increase power usage."
    static let audioLanguageFooterText = "Dusk plays audio in this language when a title has it. Original keeps each title’s own audio."
    static let subtitlesFooterText = "Auto turns subtitles on when the audio isn’t in your subtitle language, and otherwise shows only forced subtitles, which translate foreign dialogue and signs. Off shows only forced subtitles. Style System follows Accessibility › Subtitles & Captioning in the system Settings; Dusk always uses white text on a dark box. Size can also be changed from the player."
    static let subtitlesAdvancedFooterText = "Turn off Forced Subtitles to see subtitles only when Auto or Always calls for them, or when you pick a track. Until you change them here, these settings follow the language settings of your Plex account. A track you pick in the player is remembered for that show and wins over them."

    #if os(tvOS)
    static let playbackBehaviorFooterText = "Auto-Skip automatically skips intros and credits after a brief countdown. Intro skipping can skip every intro or skip every intro except episode 1 of each season. Continuous Play shows an Up Next screen after TV episodes finish and can auto-start the next one after the configured delay. Pause After counts the current episode too, then pauses autoplay until you confirm. Back Jump and Forward Jump set how many seconds skip back and skip forward move."
    #else
    static let playbackBehaviorFooterText = "Auto-Skip automatically skips intros and credits after a brief countdown. Intro skipping can skip every intro or skip every intro except episode 1 of each season. Continuous Play shows an Up Next screen after TV episodes finish and can auto-start the next one after the configured delay. Pause After counts the current episode too, then pauses autoplay until you confirm. Episode Buttons adds Previous and Next Episode buttons beside Play while you watch a TV episode. Double-Tap to Seek adds left and right double-tap seek zones in the player. Always Play in Landscape keeps iPhone video in landscape, including while Portrait Orientation Lock is on."
    #endif

    #if os(tvOS)
    static let playbackAdvancedFooterText = "Advanced Playback Controls adds skip back, skip forward and playback speed to the player. Speed is not available while Dolby Atmos is sent to your receiver or TV. Dolby Atmos plays Atmos tracks in MKV and similar files through Apple's player, which sends Atmos to your receiver or TV. HDR & Dolby Vision does the same for HDR10, HDR10+, HLG and Dolby Vision video. Dolby Vision 7 → 8.1 converts Dolby Vision profile 7 (UHD Blu-ray) video so a Dolby Vision TV shows Dolby Vision instead of HDR10; turn it off if those titles misbehave. Your Plex server repackages the file on the fly without re-encoding it, so video quality stays the original's. Force AVPlayer and Force VLCKit bypass automatic engine selection. Enabling one disables the other. Force AVPlayer may fail on formats it cannot handle."
    #else
    static let playbackAdvancedFooterText = "Advanced Playback Controls adds skip back, skip forward and playback speed to the player. Dolby Atmos & Spatial Audio plays Atmos and surround Dolby tracks in MKV and similar files through Apple's player, which enables spatial audio on AirPods. HDR & Dolby Vision does the same for HDR10, HDR10+, HLG and Dolby Vision video on HDR screens. Dolby Vision 7 → 8.1 converts Dolby Vision profile 7 (UHD Blu-ray) video so they play as Dolby Vision instead of HDR10; turn it off if those titles misbehave. Your Plex server repackages the file on the fly without re-encoding it, so video quality stays the original's. Force AVPlayer and Force VLCKit bypass automatic engine selection. Enabling one disables the other. Force AVPlayer may fail on formats it cannot handle."
    #endif
    static let downloadsFooterText = "Preferred Version picks which Plex version is downloaded when a title has several. Download quality is chosen each time you start a download. Wi-Fi Only lets the system wait for a non-cellular network before starting new transfer tasks."
    static let librariesFooterText = "Choose which library and Live TV destinations appear in the navigation bar and the order they use. Hidden Libraries removes a library from Dusk completely, including Home and search. Server Priority decides which of your servers Dusk uses, and which one plays a title that is on more than one."
    static func pinnedPlaylistsSummary(_ count: Int) -> String {
        count == 0 ? "None" : String(count)
    }

    static let homeFooterText = "Hidden Rows chooses which of Plex’s rows appear on Home. Pinned Playlists appear near the top. Personalized shelves add recommendations from Dusk to Home. Show Live TV adds currently airing channels without changing the Live TV tab."
    static let homeTVFooterText = homeFooterText + " Show Clock puts the current time at the top right of Home."
    static let homeAdvancedFooterText = "Compact Continue Watching replaces the large artwork at the top of Home with a smaller Continue Watching row, like the one on library pages."
    static let appearanceFooterText = "System follows your device appearance. Light and Dark override it for the whole app. Blur Unwatched Episodes hides the images of episodes you haven’t finished, so they can’t spoil anything."
    static let aboutFooterText = "Dusk is open source. Visit the repository, join the community on Reddit, learn more about Marvin, or send feedback by email."
    static let privacyFooterText = "Dusk sends a small number of anonymous events, including error reports, to its own server. This helps keep quality consistent and makes the app better for everyone. Nothing about your library, your server, what you watch, or what you search for is ever included."
    static let accountFooterText = "Clears the saved Plex session and returns to the sign-in flow."
    #if os(macOS)
    static let accountManagementFooterText = "Opens your Plex account settings in your browser. Plex account deletion is available there."
    #else
    static let accountManagementFooterText = "Opens your Plex account settings inside Dusk. Plex account deletion is available there."
    #endif
    static let supporterFooterText = "Dusk is free and open source. Supporting is entirely optional and unlocks alternate app icons as a thank-you — the subscription adds four exclusive ones."
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

/// A settings page's list. iOS and tvOS keep their plain `List`; on the Mac
/// it is a grouped `Form`, the System Settings look, which a `List` can't
/// take on there. Pages that reorder rows (`onMove`) stay a `List`.
struct SettingsList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(macOS)
        Form(content: content)
            .formStyle(.grouped)
            // Rows that are buttons read as rows, as on iOS, not push buttons.
            .buttonStyle(.borderless)
        #else
        List(content: content)
        #endif
    }
}

// MARK: - Settings page chrome

/// The Dusk palette on iOS/tvOS settings pages. The Mac's settings are a
/// grouped `Form` in the Settings window (or a sheet over it) and keep the
/// system's grouped backgrounds and row fills, so each of these is a no-op
/// there.
extension View {
    @ViewBuilder
    func duskSettingsRowBackground() -> some View {
        #if os(macOS)
        self
        #else
        self.listRowBackground(Color.duskSurface)
        #endif
    }

    @ViewBuilder
    func duskSettingsPageBackground() -> some View {
        #if os(macOS)
        self
        #else
        self.background(Color.duskBackground.ignoresSafeArea())
        #endif
    }

    /// `duskScrollContentBackgroundHidden()` on iOS/tvOS.
    @ViewBuilder
    func duskSettingsScrollBackgroundHidden() -> some View {
        #if os(macOS)
        self
        #else
        self.duskScrollContentBackgroundHidden()
        #endif
    }

    /// `scrollContentBackground(.hidden)` on iOS/tvOS.
    @ViewBuilder
    func duskSettingsFormBackgroundHidden() -> some View {
        #if os(macOS) || os(tvOS)
        // tvOS: unavailable there; its callers are iOS/Mac-only code.
        self
        #else
        self.scrollContentBackground(.hidden)
        #endif
    }
}
