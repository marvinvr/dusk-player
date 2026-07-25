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
        static let playerAspectFillPortrait = "playerAspectFillPortrait"
        static let playerAspectFillLandscape = "playerAspectFillLandscape"
        static let autoSkipIntroMode = "autoSkipIntroMode"
        static let autoSkipIntro = "autoSkipIntro"
        static let autoSkipCredits = "autoSkipCredits"
        static let videoEnhancementMode = "videoEnhancementMode"
        static let forceAVPlayer = "forceAVPlayer"
        static let forceVLCKit = "forceVLCKit"
        static let appearanceMode = "appearanceMode"
        static let downloadMaxResolution = "downloadMaxResolution"
        static let downloadsWifiOnly = "downloadsWifiOnly"
        static let maximumActiveDownloads = "maximumActiveDownloads"
        static let downloadFreeSpaceReserve = "downloadFreeSpaceReserve"
        static let firstLaunchDate = "firstLaunchDate"
        static let usageDayCount = "usageDayCount"
        static let lastUsageDay = "lastUsageDay"
        static let supporterPromptCount = "supporterPromptCount"
        static let supporterLastPromptDate = "supporterLastPromptDate"
        static let supporterLastPromptUsageDayCount = "supporterLastPromptUsageDayCount"
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

    /// Controls automatic skipping of intro markers after a brief countdown.
    var autoSkipIntroMode: AutoSkipIntroMode {
        didSet { UserDefaults.standard.set(autoSkipIntroMode.rawValue, forKey: Keys.autoSkipIntroMode) }
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

    /// Whether the player's zoom-to-fill control is on while the video area is
    /// taller than wide (portrait). Stored separately from landscape so each
    /// orientation remembers its own framing independently.
    var playerAspectFillPortrait: Bool {
        didSet { UserDefaults.standard.set(playerAspectFillPortrait, forKey: Keys.playerAspectFillPortrait) }
    }

    /// Whether the player's zoom-to-fill control is on while the video area is
    /// wider than tall (landscape).
    var playerAspectFillLandscape: Bool {
        didSet { UserDefaults.standard.set(playerAspectFillLandscape, forKey: Keys.playerAspectFillLandscape) }
    }

    /// Saved zoom-to-fill choice for the given player orientation.
    func playerAspectFill(isLandscape: Bool) -> Bool {
        isLandscape ? playerAspectFillLandscape : playerAspectFillPortrait
    }

    /// Persists the zoom-to-fill choice for the given player orientation.
    func setPlayerAspectFill(_ enabled: Bool, isLandscape: Bool) {
        if isLandscape {
            playerAspectFillLandscape = enabled
        } else {
            playerAspectFillPortrait = enabled
        }
    }

    /// Metal-backed video upscaling and adaptive sharpening.
    var videoEnhancementMode: VideoEnhancementMode {
        didSet { UserDefaults.standard.set(videoEnhancementMode.rawValue, forKey: Keys.videoEnhancementMode) }
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

    /// Maximum version quality selected for downloads.
    var downloadMaxResolution: MaxResolution {
        didSet { UserDefaults.standard.set(downloadMaxResolution.rawValue, forKey: Keys.downloadMaxResolution) }
    }

    /// Prevent new download tasks from using expensive networks such as cellular.
    var downloadsWifiOnly: Bool {
        didSet { UserDefaults.standard.set(downloadsWifiOnly, forKey: Keys.downloadsWifiOnly) }
    }

    /// Number of download tasks the queue may run at the same time.
    var maximumActiveDownloads: DownloadConcurrency {
        didSet { UserDefaults.standard.set(maximumActiveDownloads.rawValue, forKey: Keys.maximumActiveDownloads) }
    }

    /// Amount of free storage Dusk should leave available.
    var downloadFreeSpaceReserve: DownloadFreeSpaceReserve {
        didSet { UserDefaults.standard.set(downloadFreeSpaceReserve.rawValue, forKey: Keys.downloadFreeSpaceReserve) }
    }

    /// First launch on this device — or, for users who installed before this
    /// key existed, the first launch after updating. The supporter prompt's
    /// 7-day clock counts from here.
    private(set) var firstLaunchDate: Date

    /// Number of distinct calendar days the app has been used, fed by
    /// `registerUsageDay()`. Gates the supporter prompt so it only reaches
    /// people who actually use the app.
    private(set) var usageDayCount: Int {
        didSet { UserDefaults.standard.set(usageDayCount, forKey: Keys.usageDayCount) }
    }

    /// Day key ("yyyy-MM-dd") of the last counted usage day.
    private var lastUsageDay: String {
        didSet { UserDefaults.standard.set(lastUsageDay, forKey: Keys.lastUsageDay) }
    }

    /// How many supporter prompts have been shown on this device.
    private(set) var supporterPromptCount: Int {
        didSet { UserDefaults.standard.set(supporterPromptCount, forKey: Keys.supporterPromptCount) }
    }

    /// When the most recent supporter prompt was shown; spaces the ladder out
    /// for users whose usage catches up to several milestones at once.
    private(set) var supporterLastPromptDate: Date? {
        didSet { UserDefaults.standard.set(supporterLastPromptDate, forKey: Keys.supporterLastPromptDate) }
    }

    /// Usage-day count when the most recent supporter prompt was shown. Annual
    /// prompts use the delta to avoid asking people who barely use the app.
    private(set) var supporterLastPromptUsageDayCount: Int {
        didSet {
            UserDefaults.standard.set(
                supporterLastPromptUsageDayCount,
                forKey: Keys.supporterLastPromptUsageDayCount
            )
        }
    }

    /// Records that a supporter prompt was presented.
    func registerSupporterPrompt(now: Date = .now) {
        supporterPromptCount += 1
        supporterLastPromptDate = now
        supporterLastPromptUsageDayCount = usageDayCount
    }

    /// Counts today as a usage day if it hasn't been counted yet.
    func registerUsageDay(now: Date = .now) {
        let day = Self.usageDayKey(for: now)
        guard day != lastUsageDay else { return }
        lastUsageDay = day
        usageDayCount += 1
    }

    private static func usageDayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
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
        let autoSkipIntroMode = Self.storedAutoSkipIntroMode(defaults: defaults)
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
            fallback: .fifteenSeconds
        )
        // Absent defaults to `false` (letterboxed fit), matching the old
        // session-scoped behavior where zoom always started off.
        let playerAspectFillPortrait = defaults.bool(forKey: Keys.playerAspectFillPortrait)
        let playerAspectFillLandscape = defaults.bool(forKey: Keys.playerAspectFillLandscape)
        let videoEnhancementMode: VideoEnhancementMode
        if let raw = defaults.string(forKey: Keys.videoEnhancementMode),
           let mode = VideoEnhancementMode(rawValue: raw) {
            videoEnhancementMode = mode
        } else {
            videoEnhancementMode = .defaultForPlatform
        }
        let storedForceAVPlayer = defaults.bool(forKey: Keys.forceAVPlayer)
        let storedForceVLCKit = defaults.bool(forKey: Keys.forceVLCKit)
        let forceAVPlayer = storedForceAVPlayer
        let forceVLCKit = storedForceAVPlayer ? false : storedForceVLCKit
        let downloadMaxResolution: MaxResolution
        if let raw = defaults.string(forKey: Keys.downloadMaxResolution),
           let value = MaxResolution(rawValue: raw) {
            downloadMaxResolution = value
        } else {
            downloadMaxResolution = maxResolution
        }
        let downloadsWifiOnly = defaults.object(forKey: Keys.downloadsWifiOnly) as? Bool ?? true
        let maximumActiveDownloads = Self.storedDownloadConcurrency(
            forKey: Keys.maximumActiveDownloads,
            defaults: defaults,
            fallback: .one
        )
        let downloadFreeSpaceReserve = Self.storedDownloadFreeSpaceReserve(
            forKey: Keys.downloadFreeSpaceReserve,
            defaults: defaults,
            fallback: .fiveGB
        )

        let appearanceMode: AppearanceMode
        if let raw = defaults.string(forKey: Keys.appearanceMode),
           let mode = AppearanceMode(rawValue: raw) {
            appearanceMode = mode
        } else {
            // tvOS's Light appearance is unpleasant for this app, so default to Dark
            // there. Other platforms still follow the system setting by default.
            #if os(tvOS)
            appearanceMode = .dark
            #else
            appearanceMode = .system
            #endif
        }

        self.maxResolution = maxResolution
        self.defaultSubtitleLanguage = defaultSubtitleLanguage
        self.subtitleForcedOnly = subtitleForcedOnly
        self.defaultAudioLanguage = defaultAudioLanguage
        self.continuousPlayEnabled = continuousPlayEnabled
        self.continuousPlayCountdown = continuousPlayCountdown
        self.continuousPlayPassoutProtectionEpisodeLimit = continuousPlayPassoutProtectionEpisodeLimit
        self.autoSkipIntroMode = autoSkipIntroMode
        self.autoSkipCredits = autoSkipCredits
        self.playerDoubleTapSeekEnabled = playerDoubleTapSeekEnabled
        self.playerDoubleTapForwardInterval = playerDoubleTapForwardInterval
        self.playerDoubleTapBackwardInterval = playerDoubleTapBackwardInterval
        self.playerAspectFillPortrait = playerAspectFillPortrait
        self.playerAspectFillLandscape = playerAspectFillLandscape
        self.videoEnhancementMode = videoEnhancementMode
        self.forceAVPlayer = forceAVPlayer
        self.forceVLCKit = forceVLCKit
        self.appearanceMode = appearanceMode
        self.downloadMaxResolution = downloadMaxResolution
        self.downloadsWifiOnly = downloadsWifiOnly
        self.maximumActiveDownloads = maximumActiveDownloads
        self.downloadFreeSpaceReserve = downloadFreeSpaceReserve

        if let storedFirstLaunch = defaults.object(forKey: Keys.firstLaunchDate) as? Date {
            self.firstLaunchDate = storedFirstLaunch
        } else {
            let now = Date()
            defaults.set(now, forKey: Keys.firstLaunchDate)
            self.firstLaunchDate = now
        }
        self.usageDayCount = defaults.integer(forKey: Keys.usageDayCount)
        self.lastUsageDay = defaults.string(forKey: Keys.lastUsageDay) ?? ""
        self.supporterPromptCount = defaults.integer(forKey: Keys.supporterPromptCount)
        self.supporterLastPromptDate = defaults.object(forKey: Keys.supporterLastPromptDate) as? Date
        if defaults.object(forKey: Keys.supporterLastPromptUsageDayCount) != nil {
            self.supporterLastPromptUsageDayCount = defaults.integer(
                forKey: Keys.supporterLastPromptUsageDayCount
            )
        } else {
            // Existing installs have no historical usage snapshot. Start from
            // today's total so the first annual prompt still requires 12 new
            // usage days instead of treating all past activity as recent.
            let currentUsageDayCount = defaults.integer(forKey: Keys.usageDayCount)
            self.supporterLastPromptUsageDayCount = currentUsageDayCount
            defaults.set(
                currentUsageDayCount,
                forKey: Keys.supporterLastPromptUsageDayCount
            )
        }
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

    private static func storedAutoSkipIntroMode(defaults: UserDefaults) -> AutoSkipIntroMode {
        if let raw = defaults.string(forKey: Keys.autoSkipIntroMode),
           let mode = AutoSkipIntroMode(rawValue: raw) {
            return mode
        }

        if let legacyValue = defaults.object(forKey: Keys.autoSkipIntro) as? Bool {
            return legacyValue ? .always : .off
        }

        return .alwaysExceptFirstEpisode
    }

    private static func storedDownloadConcurrency(
        forKey key: String,
        defaults: UserDefaults,
        fallback: DownloadConcurrency
    ) -> DownloadConcurrency {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return DownloadConcurrency(rawValue: defaults.integer(forKey: key)) ?? fallback
    }

    private static func storedDownloadFreeSpaceReserve(
        forKey key: String,
        defaults: UserDefaults,
        fallback: DownloadFreeSpaceReserve
    ) -> DownloadFreeSpaceReserve {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return DownloadFreeSpaceReserve(rawValue: defaults.integer(forKey: key)) ?? fallback
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

enum AutoSkipIntroMode: String, CaseIterable, Identifiable {
    case off
    case always
    case alwaysExceptFirstEpisode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .always: "Always"
        case .alwaysExceptFirstEpisode: "Always Except First Episode"
        }
    }

    func shouldAutoSkipIntro(isFirstEpisodeInSeason: Bool) -> Bool {
        switch self {
        case .off:
            false
        case .always:
            true
        case .alwaysExceptFirstEpisode:
            !isFirstEpisodeInSeason
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

enum DownloadConcurrency: Int, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case three = 3

    var id: Int { rawValue }

    var displayName: String {
        rawValue == 1 ? "1 Download" : "\(rawValue) Downloads"
    }
}

enum DownloadFreeSpaceReserve: Int, CaseIterable, Identifiable {
    case oneGB = 1_000_000_000
    case fiveGB = 5_000_000_000
    case tenGB = 10_000_000_000
    case twentyGB = 20_000_000_000

    var id: Int { rawValue }

    var bytes: Int64 {
        Int64(rawValue)
    }

    var displayName: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
