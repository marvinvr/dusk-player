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
        static let defaultAudioLanguage = "defaultAudioLanguage"
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
        didSet { UserDefaults.standard.set(defaultSubtitleLanguage, forKey: Keys.defaultSubtitleLanguage) }
    }

    /// ISO 639-1 language code for preferred audio track.
    var defaultAudioLanguage: String {
        didSet { UserDefaults.standard.set(defaultAudioLanguage, forKey: Keys.defaultAudioLanguage) }
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

        let defaultSubtitleLanguage = defaults.string(forKey: Keys.defaultSubtitleLanguage)
        let defaultAudioLanguage = defaults.string(forKey: Keys.defaultAudioLanguage) ?? "en"
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
        self.defaultAudioLanguage = defaultAudioLanguage
        self.forceAVPlayer = forceAVPlayer
        self.forceVLCKit = forceVLCKit
        self.appearanceMode = appearanceMode
        self.playerDebugOverlayEnabled = playerDebugOverlayEnabled
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
}
