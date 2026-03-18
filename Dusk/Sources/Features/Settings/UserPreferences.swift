import Foundation
import SwiftUI

/// Centralized user preferences backed by UserDefaults.
///
/// Injected into the environment so any view or coordinator can read settings.
/// StreamResolver and PlaybackCoordinator consume these to pick the right engine
/// and select default tracks.
@MainActor
@Observable
final class UserPreferences {
    // MARK: - Keys

    private enum Keys {
        static let maxResolution = "maxResolution"
        static let defaultSubtitleLanguage = "defaultSubtitleLanguage"
        static let subtitleForcedOnly = "subtitleForcedOnly"
        static let defaultAudioLanguage = "defaultAudioLanguage"
        static let continuousPlayEnabled = "continuousPlayEnabled"
        static let continuousPlayCountdown = "continuousPlayCountdown"
        static let continuousPlayPassoutProtectionEpisodeLimit = "continuousPlayPassoutProtectionEpisodeLimit"
        static let playerDoubleTapSeekEnabled = "playerDoubleTapSeekEnabled"
        static let playerDoubleTapForwardInterval = "playerDoubleTapForwardInterval"
        static let playerDoubleTapBackwardInterval = "playerDoubleTapBackwardInterval"
        static let autoSkipIntro = "autoSkipIntro"
        static let autoSkipCredits = "autoSkipCredits"
        static let forceAVPlayer = "forceAVPlayer"
        static let forceVLCKit = "forceVLCKit"
        static let appearanceMode = "appearanceMode"
        static let playerDebugOverlayEnabled = "playerDebugOverlayEnabled"
    }

    // MARK: - Properties

    var maxResolution: MaxResolution {
        didSet { UserDefaults.standard.set(maxResolution.rawValue, forKey: Keys.maxResolution) }
    }

    /// ISO 639-1 language code, or nil for "None" (no default subtitle).
    var defaultSubtitleLanguage: String? {
        didSet { UserDefaults.standard.set(defaultSubtitleLanguage ?? "", forKey: Keys.defaultSubtitleLanguage) }
    }

    /// When enabled, automatic subtitle selection only picks forced tracks.
    var subtitleForcedOnly: Bool {
        didSet { UserDefaults.standard.set(subtitleForcedOnly, forKey: Keys.subtitleForcedOnly) }
    }

    /// ISO 639-1 language code for preferred audio track.
    var defaultAudioLanguage: String {
        didSet { UserDefaults.standard.set(defaultAudioLanguage, forKey: Keys.defaultAudioLanguage) }
    }

    /// Automatically continue to the next episode when TV playback finishes.
    var continuousPlayEnabled: Bool {
        didSet { UserDefaults.standard.set(continuousPlayEnabled, forKey: Keys.continuousPlayEnabled) }
    }

    /// Delay before automatically starting the next episode from the Up Next screen.
    var continuousPlayCountdown: ContinuousPlayCountdown {
        didSet { UserDefaults.standard.set(continuousPlayCountdown.rawValue, forKey: Keys.continuousPlayCountdown) }
    }

    /// Stops automatic episode chaining after a streak until the user confirms.
    /// `nil` disables passout protection entirely.
    var continuousPlayPassoutProtectionEpisodeLimit: Int? {
        didSet {
            let storedValue = max(continuousPlayPassoutProtectionEpisodeLimit ?? 0, 0)
            UserDefaults.standard.set(storedValue, forKey: Keys.continuousPlayPassoutProtectionEpisodeLimit)
        }
    }

    /// Automatically skip intro markers after a brief countdown.
    var autoSkipIntro: Bool {
        didSet { UserDefaults.standard.set(autoSkipIntro, forKey: Keys.autoSkipIntro) }
    }

    /// Automatically skip credits markers after a brief countdown.
    var autoSkipCredits: Bool {
        didSet { UserDefaults.standard.set(autoSkipCredits, forKey: Keys.autoSkipCredits) }
    }

    /// Enable left/right double-tap seeking on touch-based platforms.
    var playerDoubleTapSeekEnabled: Bool {
        didSet { UserDefaults.standard.set(playerDoubleTapSeekEnabled, forKey: Keys.playerDoubleTapSeekEnabled) }
    }

    /// Jump interval for double-tapping the right side of the player.
    var playerDoubleTapForwardInterval: PlayerSeekInterval {
        didSet { UserDefaults.standard.set(playerDoubleTapForwardInterval.rawValue, forKey: Keys.playerDoubleTapForwardInterval) }
    }

    /// Jump interval for double-tapping the left side of the player.
    var playerDoubleTapBackwardInterval: PlayerSeekInterval {
        didSet { UserDefaults.standard.set(playerDoubleTapBackwardInterval.rawValue, forKey: Keys.playerDoubleTapBackwardInterval) }
    }

    /// Bypass StreamResolver and always use AVPlayer.
    var forceAVPlayer: Bool {
        didSet {
            if forceAVPlayer && forceVLCKit {
                forceVLCKit = false
            }
            UserDefaults.standard.set(forceAVPlayer, forKey: Keys.forceAVPlayer)
        }
    }

    /// Bypass StreamResolver and always use VLCKit.
    var forceVLCKit: Bool {
        didSet {
            if forceVLCKit && forceAVPlayer {
                forceAVPlayer = false
            }
            UserDefaults.standard.set(forceVLCKit, forKey: Keys.forceVLCKit)
        }
    }

    /// App-wide appearance override.
    var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }

    /// Show playback debug stats over the active player.
    var playerDebugOverlayEnabled: Bool {
        didSet { UserDefaults.standard.set(playerDebugOverlayEnabled, forKey: Keys.playerDebugOverlayEnabled) }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        let maxResolution: MaxResolution
        if let raw = defaults.string(forKey: Keys.maxResolution),
           let value = MaxResolution(rawValue: raw) {
            maxResolution = value
        } else {
            maxResolution = .auto
        }

        let defaultSubtitleLanguage = Self.storedSubtitleLanguage(defaults: defaults)
        let subtitleForcedOnly = defaults.object(forKey: Keys.subtitleForcedOnly) as? Bool ?? true
        let defaultAudioLanguage = defaults.string(forKey: Keys.defaultAudioLanguage) ?? "en"
        let continuousPlayEnabled = defaults.object(forKey: Keys.continuousPlayEnabled) as? Bool ?? true
        let continuousPlayCountdown = Self.storedContinuousPlayCountdown(
            forKey: Keys.continuousPlayCountdown,
            defaults: defaults,
            fallback: .fiveSeconds
        )
        let continuousPlayPassoutProtectionEpisodeLimit = Self.storedOptionalPositiveInt(
            forKey: Keys.continuousPlayPassoutProtectionEpisodeLimit,
            defaults: defaults,
            fallback: 3
        )
        let autoSkipIntro = defaults.object(forKey: Keys.autoSkipIntro) as? Bool ?? true
        let autoSkipCredits = defaults.object(forKey: Keys.autoSkipCredits) as? Bool ?? false
        let playerDoubleTapSeekEnabled = defaults.object(forKey: Keys.playerDoubleTapSeekEnabled) as? Bool ?? true
        let playerDoubleTapForwardInterval = Self.storedSeekInterval(
            forKey: Keys.playerDoubleTapForwardInterval,
            defaults: defaults,
            fallback: .fifteenSeconds
        )
        let playerDoubleTapBackwardInterval = Self.storedSeekInterval(
            forKey: Keys.playerDoubleTapBackwardInterval,
            defaults: defaults,
            fallback: .fiveSeconds
        )
        let storedForceAVPlayer = defaults.bool(forKey: Keys.forceAVPlayer)
        let storedForceVLCKit = defaults.bool(forKey: Keys.forceVLCKit)
        let forceAVPlayer = storedForceAVPlayer
        let forceVLCKit = storedForceAVPlayer ? false : storedForceVLCKit
        let playerDebugOverlayEnabled = defaults.bool(forKey: Keys.playerDebugOverlayEnabled)

        let appearanceMode: AppearanceMode
        if let raw = defaults.string(forKey: Keys.appearanceMode),
           let mode = AppearanceMode(rawValue: raw) {
            appearanceMode = mode
        } else {
            appearanceMode = .system
        }

        self.maxResolution = maxResolution
        self.defaultSubtitleLanguage = defaultSubtitleLanguage
        self.subtitleForcedOnly = subtitleForcedOnly
        self.defaultAudioLanguage = defaultAudioLanguage
        self.continuousPlayEnabled = continuousPlayEnabled
        self.continuousPlayCountdown = continuousPlayCountdown
        self.continuousPlayPassoutProtectionEpisodeLimit = continuousPlayPassoutProtectionEpisodeLimit
        self.autoSkipIntro = autoSkipIntro
        self.autoSkipCredits = autoSkipCredits
        self.playerDoubleTapSeekEnabled = playerDoubleTapSeekEnabled
        self.playerDoubleTapForwardInterval = playerDoubleTapForwardInterval
        self.playerDoubleTapBackwardInterval = playerDoubleTapBackwardInterval
        self.forceAVPlayer = forceAVPlayer
        self.forceVLCKit = forceVLCKit
        self.appearanceMode = appearanceMode
        self.playerDebugOverlayEnabled = playerDebugOverlayEnabled
    }

    private static func storedSeekInterval(
        forKey key: String,
        defaults: UserDefaults,
        fallback: PlayerSeekInterval
    ) -> PlayerSeekInterval {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return PlayerSeekInterval(rawValue: defaults.integer(forKey: key)) ?? fallback
    }

    private static func storedContinuousPlayCountdown(
        forKey key: String,
        defaults: UserDefaults,
        fallback: ContinuousPlayCountdown
    ) -> ContinuousPlayCountdown {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return ContinuousPlayCountdown(rawValue: defaults.integer(forKey: key)) ?? fallback
    }

    private static func storedOptionalPositiveInt(
        forKey key: String,
        defaults: UserDefaults,
        fallback: Int?
    ) -> Int? {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let value = defaults.integer(forKey: key)
        return value > 0 ? value : nil
    }

    private static func storedSubtitleLanguage(defaults: UserDefaults) -> String? {
        guard defaults.object(forKey: Keys.defaultSubtitleLanguage) != nil else {
            return systemPreferredSubtitleLanguageCode
        }

        guard let storedValue = defaults.string(forKey: Keys.defaultSubtitleLanguage) else {
            return nil
        }

        return storedValue.isEmpty ? nil : normalizedLanguageCode(from: storedValue)
    }

    nonisolated static var systemPreferredSubtitleLanguageCode: String? {
        Locale.preferredLanguages.lazy
            .compactMap(normalizedLanguageCode(from:))
            .first
    }

    nonisolated private static func normalizedLanguageCode(from identifier: String) -> String? {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else { return nil }

        let normalizedIdentifier = trimmedIdentifier.replacingOccurrences(of: "-", with: "_")
        let components = Locale.components(fromIdentifier: normalizedIdentifier)

        if let languageCode = components[NSLocale.Key.languageCode.rawValue], !languageCode.isEmpty {
            return languageCode.lowercased()
        }

        if normalizedIdentifier.range(of: "_") == nil {
            return normalizedIdentifier.lowercased()
        }

        return nil
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum PlayerSeekInterval: Int, CaseIterable, Identifiable {
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case fortyFiveSeconds = 45
    case sixtySeconds = 60

    var id: Int { rawValue }

    var displayName: String {
        "\(rawValue)s"
    }

    var timeInterval: TimeInterval {
        TimeInterval(rawValue)
    }
}

enum ContinuousPlayCountdown: Int, CaseIterable, Identifiable {
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15

    var id: Int { rawValue }

    var displayName: String {
        "\(rawValue)s"
    }

    var timeInterval: TimeInterval {
        TimeInterval(rawValue)
    }
}

// MARK: - MaxResolution

enum MaxResolution: String, CaseIterable, Identifiable {
    case auto = "auto"
    case fourK = "4k"
    case tenEightyP = "1080p"
    case sevenTwentyP = "720p"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .fourK: "4K"
        case .tenEightyP: "1080p"
        case .sevenTwentyP: "720p"
        }
    }

    /// Maximum vertical resolution in pixels, or nil for "auto" (no limit).
    var maxHeight: Int? {
        switch self {
        case .auto: nil
        case .fourK: 2160
        case .tenEightyP: 1080
        case .sevenTwentyP: 720
        }
    }

    /// Playback target used when selecting among multiple Plex media versions.
    /// Auto prefers 4K on Apple TV and 1080p everywhere else.
    var selectionTargetMaxHeight: Int {
        switch self {
        case .auto:
            #if os(tvOS)
            2160
            #else
            1080
            #endif
        case .fourK:
            2160
        case .tenEightyP:
            1080
        case .sevenTwentyP:
            720
        }
    }
}
