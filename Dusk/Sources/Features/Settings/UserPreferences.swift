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
        static let subtitleFontSize = "subtitleFontSize"
        static let subtitleStyle = "subtitleStyle"
        static let defaultAudioLanguage = "defaultAudioLanguage"
        static let subtitleMode = "subtitleMode"
        static let forcedSubtitlesEnabled = "forcedSubtitlesEnabled"
        static let accountAudioLanguage = "plexAccountAudioLanguage"
        static let accountSubtitleLanguage = "plexAccountSubtitleLanguage"
        static let accountSubtitleMode = "plexAccountSubtitleMode"
        static let continuousPlayEnabled = "continuousPlayEnabled"
        static let continuousPlayCountdown = "continuousPlayCountdown"
        static let continuousPlayPassoutProtectionEpisodeLimit = "continuousPlayPassoutProtectionEpisodeLimit"
        static let playerDoubleTapSeekEnabled = "playerDoubleTapSeekEnabled"
        static let playerEpisodeButtonsEnabled = "playerEpisodeButtonsEnabled"
        static let playerAdvancedControlsEnabled = "playerAdvancedControlsEnabled"
        static let alwaysPlayInLandscape = "alwaysPlayInLandscape"
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
        static let spatialAudioRemuxEnabled = "spatialAudioRemuxEnabled"
        static let hdrVideoRemuxEnabled = "hdrVideoRemuxEnabled"
        static let dolbyVision7ConversionEnabled = "dolbyVision7ConversionEnabled"
        static let appearanceMode = "appearanceMode"
        static let libraryTabOrder = "libraryTabOrder"
        static let hiddenLibraryTabs = "hiddenLibraryTabs"
        static let showsLiveTVOnHome = "showsLiveTVOnHome"
        static let personalizedShelvesEnabled = "personalizedShelvesEnabled"
        static let compactHomeContinueWatching = "compactHomeContinueWatching"
        static let blursUnwatchedEpisodes = "blursUnwatchedEpisodes"
        static let showsClock = "showsClock"
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
        static let analyticsEnabled = "analyticsEnabled"
    }

    // MARK: - Properties

    var maxResolution: MaxResolution {
        didSet { UserDefaults.standard.set(maxResolution.rawValue, forKey: Keys.maxResolution) }
    }

    /// ISO 639-1 code of the language automatic subtitle selection looks for.
    var defaultSubtitleLanguage: String {
        didSet { persistLanguageSetting(defaultSubtitleLanguage, forKey: Keys.defaultSubtitleLanguage) }
    }

    /// When subtitles turn on without the viewer picking a track
    /// (`SubtitleSelectionPolicy`). A per-show remembered choice always wins.
    var subtitleMode: SubtitleMode {
        didSet { persistLanguageSetting(subtitleMode.rawValue, forKey: Keys.subtitleMode) }
    }

    /// Forced subtitles (foreign dialogue, signs) may start on their own.
    /// Off means subtitles only ever appear in Auto/Always or when picked.
    var forcedSubtitlesEnabled: Bool {
        didSet { UserDefaults.standard.set(forcedSubtitlesEnabled, forKey: Keys.forcedSubtitlesEnabled) }
    }

    /// On-screen size of locally rendered subtitles. Applies to both engines
    /// and can also be changed from inside the player.
    var subtitleFontSize: SubtitleFontSize {
        didSet { UserDefaults.standard.set(subtitleFontSize.rawValue, forKey: Keys.subtitleFontSize) }
    }

    /// Whether subtitles follow the system caption style or Dusk's own look.
    var subtitleStyle: SubtitleStyle {
        didSet { UserDefaults.standard.set(subtitleStyle.rawValue, forKey: Keys.subtitleStyle) }
    }

    /// ISO 639-1 language code for preferred audio track, or "" to keep each
    /// title's original audio.
    var defaultAudioLanguage: String {
        didSet { persistLanguageSetting(defaultAudioLanguage, forKey: Keys.defaultAudioLanguage) }
    }

    /// Set while Plex account defaults are copied in, so they stay defaults
    /// (and keep following the account) instead of becoming Dusk choices.
    @ObservationIgnored private var isApplyingAccountLanguageDefaults = false

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

    /// Previous / Next Episode buttons beside Play in the iOS player. Opt-in so
    /// the default HUD stays clean; tvOS always offers Next Episode in its
    /// action row and has no toggle.
    var playerEpisodeButtonsEnabled: Bool {
        didSet { UserDefaults.standard.set(playerEpisodeButtonsEnabled, forKey: Keys.playerEpisodeButtonsEnabled) }
    }

    /// Skip back / skip forward buttons and the playback speed control in the
    /// player overlay, on iOS and tvOS. Off keeps the default HUD; speed is
    /// only reachable while this is on.
    var playerAdvancedControlsEnabled: Bool {
        didSet { UserDefaults.standard.set(playerAdvancedControlsEnabled, forKey: Keys.playerAdvancedControlsEnabled) }
    }

    /// iPhone player opens in landscape even when Portrait Orientation Lock is
    /// on, and follows the phone between landscape left and right. Off leaves
    /// rotation to the system. iPad and tvOS ignore it.
    var alwaysPlayInLandscape: Bool {
        didSet { UserDefaults.standard.set(alwaysPlayInLandscape, forKey: Keys.alwaysPlayInLandscape) }
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

    /// Play Dolby Atmos (and, on iPhone/iPad, multichannel Dolby) from files
    /// only VLCKit could direct play through a lossless Plex remux into
    /// AVPlayer, so Atmos reaches HDMI and AirPods get spatial audio.
    var spatialAudioRemuxEnabled: Bool {
        didSet { UserDefaults.standard.set(spatialAudioRemuxEnabled, forKey: Keys.spatialAudioRemuxEnabled) }
    }

    /// Play HDR files only VLCKit could direct play (HDR10, HDR10+, HLG,
    /// Dolby Vision 7/8) through a lossless Plex remux into AVPlayer, which
    /// shows real HDR and applies Dolby Vision 8.1/8.4 metadata. VLCKit
    /// renders into an 8-bit SDR surface on iOS/tvOS.
    var hdrVideoRemuxEnabled: Bool {
        didSet { UserDefaults.standard.set(hdrVideoRemuxEnabled, forKey: Keys.hdrVideoRemuxEnabled) }
    }

    /// Convert Dolby Vision profile 7 to 8.1 on device during the HDR remux,
    /// so a Dolby Vision display shows Dolby Vision instead of the HDR10
    /// base layer. Only applies while `hdrVideoRemuxEnabled` is on.
    var dolbyVision7ConversionEnabled: Bool {
        didSet { UserDefaults.standard.set(dolbyVision7ConversionEnabled, forKey: Keys.dolbyVision7ConversionEnabled) }
    }

    /// App-wide appearance override.
    var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }

    /// The preferred order of library destinations in the main tab bar.
    /// All supported types remain in this array, including hidden ones, so a
    /// library returns to its previous position when it is shown again.
    private(set) var libraryTabOrder: [PlexLibraryType] {
        didSet {
            UserDefaults.standard.set(
                libraryTabOrder.map(\.rawValue),
                forKey: Keys.libraryTabOrder
            )
        }
    }

    /// Library destinations excluded from the main tab bar.
    private var hiddenLibraryTabs: Set<PlexLibraryType> {
        didSet {
            UserDefaults.standard.set(
                hiddenLibraryTabs.map(\.rawValue).sorted(),
                forKey: Keys.hiddenLibraryTabs
            )
        }
    }

    func visibleLibraryTabs(from availableTypes: [PlexLibraryType]) -> [PlexLibraryType] {
        let availableTypes = Set(availableTypes)
        return libraryTabOrder.filter {
            availableTypes.contains($0) && !hiddenLibraryTabs.contains($0)
        }
    }

    func isLibraryTabVisible(_ libraryType: PlexLibraryType) -> Bool {
        !hiddenLibraryTabs.contains(libraryType)
    }

    func setLibraryTabVisible(_ isVisible: Bool, for libraryType: PlexLibraryType) {
        if isVisible {
            hiddenLibraryTabs.remove(libraryType)
        } else {
            hiddenLibraryTabs.insert(libraryType)
        }
    }

    func moveLibraryTabs(fromOffsets: IndexSet, toOffset: Int) {
        libraryTabOrder.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func moveLibraryTab(_ libraryType: PlexLibraryType, to destinationIndex: Int) {
        guard let sourceIndex = libraryTabOrder.firstIndex(of: libraryType) else { return }

        var reorderedTabs = libraryTabOrder
        let movedTab = reorderedTabs.remove(at: sourceIndex)
        let clampedIndex = min(max(destinationIndex, 0), reorderedTabs.count)
        reorderedTabs.insert(movedTab, at: clampedIndex)
        libraryTabOrder = reorderedTabs
    }

    /// Whether Home shows the currently airing Live TV shelf. Off by default;
    /// it does not affect the Live TV navigation tab.
    var showsLiveTVOnHome: Bool {
        didSet { UserDefaults.standard.set(showsLiveTVOnHome, forKey: Keys.showsLiveTVOnHome) }
    }

    /// Extra Home shelves generated by Dusk, enabled for existing installs.
    var personalizedShelvesEnabled: Bool {
        didSet { UserDefaults.standard.set(personalizedShelvesEnabled, forKey: Keys.personalizedShelvesEnabled) }
    }

    /// Whether Home opens with the small Continue Watching row (the one the
    /// library pages use) instead of the cinematic hero. Off by default.
    var compactHomeContinueWatching: Bool {
        didSet { UserDefaults.standard.set(compactHomeContinueWatching, forKey: Keys.compactHomeContinueWatching) }
    }

    /// Whether the own images of TV episodes the user hasn't finished are
    /// blurred, so a frame grab never spoils them. Off by default.
    var blursUnwatchedEpisodes: Bool {
        didSet { UserDefaults.standard.set(blursUnwatchedEpisodes, forKey: Keys.blursUnwatchedEpisodes) }
    }

    /// Whether tvOS shows the time at the top right of Home. On by default.
    var showsClock: Bool {
        didSet { UserDefaults.standard.set(showsClock, forKey: Keys.showsClock) }
    }

    /// `blursUnwatchedEpisodes` for code that has no `UserPreferences` at hand
    /// (the Top Shelf publisher).
    static var storedBlursUnwatchedEpisodes: Bool {
        UserDefaults.standard.bool(forKey: Keys.blursUnwatchedEpisodes)
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
    /// first-ask clock counts from here (`SupporterPromptSchedule`).
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

    /// When the most recent supporter prompt was shown; the schedule's
    /// growing gaps count from here.
    private(set) var supporterLastPromptDate: Date? {
        didSet { UserDefaults.standard.set(supporterLastPromptDate, forKey: Keys.supporterLastPromptDate) }
    }

    /// Usage-day count when the most recent supporter prompt was shown. Later
    /// prompts use the delta to avoid asking people who barely use the app.
    private(set) var supporterLastPromptUsageDayCount: Int {
        didSet {
            UserDefaults.standard.set(
                supporterLastPromptUsageDayCount,
                forKey: Keys.supporterLastPromptUsageDayCount
            )
        }
    }

    /// Whether Dusk may report anonymous product events. Defaults to on and is
    /// turned off in Settings; `AnalyticsClient` checks this before every send
    /// and drops its install identifier when it flips off.
    var analyticsEnabled: Bool {
        didSet { UserDefaults.standard.set(analyticsEnabled, forKey: Keys.analyticsEnabled) }
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

        let subtitleSettings = Self.storedSubtitleSettings(defaults: defaults)
        let subtitleFontSize: SubtitleFontSize
        if let raw = defaults.string(forKey: Keys.subtitleFontSize),
           let value = SubtitleFontSize(rawValue: raw) {
            subtitleFontSize = value
        } else {
            subtitleFontSize = .default
        }
        let subtitleStyle = defaults.string(forKey: Keys.subtitleStyle)
            .flatMap(SubtitleStyle.init(rawValue:)) ?? .default
        let defaultAudioLanguage = Self.storedAudioLanguage(defaults: defaults)
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
        let playerEpisodeButtonsEnabled = defaults.bool(forKey: Keys.playerEpisodeButtonsEnabled)
        let playerAdvancedControlsEnabled = defaults.bool(forKey: Keys.playerAdvancedControlsEnabled)
        let alwaysPlayInLandscape = defaults.object(forKey: Keys.alwaysPlayInLandscape) as? Bool ?? true
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
        let libraryTabOrder = Self.storedLibraryTabOrder(defaults: defaults)
        let hiddenLibraryTabs = Self.storedHiddenLibraryTabs(defaults: defaults)

        self.maxResolution = maxResolution
        self.defaultSubtitleLanguage = subtitleSettings.language
        self.subtitleMode = subtitleSettings.mode
        self.forcedSubtitlesEnabled = subtitleSettings.forcedSubtitlesEnabled
        self.subtitleFontSize = subtitleFontSize
        self.subtitleStyle = subtitleStyle
        self.defaultAudioLanguage = defaultAudioLanguage
        self.continuousPlayEnabled = continuousPlayEnabled
        self.continuousPlayCountdown = continuousPlayCountdown
        self.continuousPlayPassoutProtectionEpisodeLimit = continuousPlayPassoutProtectionEpisodeLimit
        self.autoSkipIntroMode = autoSkipIntroMode
        self.autoSkipCredits = autoSkipCredits
        self.playerDoubleTapSeekEnabled = playerDoubleTapSeekEnabled
        self.playerEpisodeButtonsEnabled = playerEpisodeButtonsEnabled
        self.playerAdvancedControlsEnabled = playerAdvancedControlsEnabled
        self.alwaysPlayInLandscape = alwaysPlayInLandscape
        self.playerDoubleTapForwardInterval = playerDoubleTapForwardInterval
        self.playerDoubleTapBackwardInterval = playerDoubleTapBackwardInterval
        self.playerAspectFillPortrait = playerAspectFillPortrait
        self.playerAspectFillLandscape = playerAspectFillLandscape
        self.videoEnhancementMode = videoEnhancementMode
        self.forceAVPlayer = forceAVPlayer
        self.forceVLCKit = forceVLCKit
        self.spatialAudioRemuxEnabled = defaults.object(forKey: Keys.spatialAudioRemuxEnabled) as? Bool ?? true
        self.hdrVideoRemuxEnabled = defaults.object(forKey: Keys.hdrVideoRemuxEnabled) as? Bool ?? true
        self.dolbyVision7ConversionEnabled = defaults.object(forKey: Keys.dolbyVision7ConversionEnabled) as? Bool ?? true
        self.appearanceMode = appearanceMode
        self.libraryTabOrder = libraryTabOrder
        self.hiddenLibraryTabs = hiddenLibraryTabs
        self.showsLiveTVOnHome = defaults.bool(forKey: Keys.showsLiveTVOnHome)
        self.personalizedShelvesEnabled = defaults.object(forKey: Keys.personalizedShelvesEnabled) as? Bool ?? true
        self.compactHomeContinueWatching = defaults.bool(forKey: Keys.compactHomeContinueWatching)
        self.blursUnwatchedEpisodes = defaults.bool(forKey: Keys.blursUnwatchedEpisodes)
        self.showsClock = defaults.object(forKey: Keys.showsClock) as? Bool ?? true
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
        self.analyticsEnabled = defaults.object(forKey: Keys.analyticsEnabled) as? Bool ?? true
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

    private static func storedLibraryTabOrder(defaults: UserDefaults) -> [PlexLibraryType] {
        let storedTypes = (defaults.stringArray(forKey: Keys.libraryTabOrder) ?? [])
            .compactMap(PlexLibraryType.init(rawValue:))

        var normalizedTypes: [PlexLibraryType] = []
        for libraryType in storedTypes + PlexLibraryType.allCases
        where !normalizedTypes.contains(libraryType) {
            normalizedTypes.append(libraryType)
        }
        return normalizedTypes
    }

    private static func storedHiddenLibraryTabs(defaults: UserDefaults) -> Set<PlexLibraryType> {
        Set(
            (defaults.stringArray(forKey: Keys.hiddenLibraryTabs) ?? [])
                .compactMap(PlexLibraryType.init(rawValue:))
        )
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

    private func persistLanguageSetting(_ value: String, forKey key: String) {
        guard !isApplyingAccountLanguageDefaults else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Adopts the Plex account's language settings for every value the viewer
    /// has not chosen in Dusk. They are remembered, so a relaunch before the
    /// account answers starts from the same defaults, and they keep following
    /// the account until the viewer picks something in Dusk.
    func applyPlexAccountLanguageDefaults(_ accountDefaults: PlexAccountLanguageDefaults) {
        let defaults = UserDefaults.standard
        defaults.set(accountDefaults.audioLanguage, forKey: Keys.accountAudioLanguage)
        defaults.set(accountDefaults.subtitleLanguage, forKey: Keys.accountSubtitleLanguage)
        defaults.set(accountDefaults.subtitleMode?.rawValue, forKey: Keys.accountSubtitleMode)

        isApplyingAccountLanguageDefaults = true
        defer { isApplyingAccountLanguageDefaults = false }
        let resolved = Self.storedSubtitleSettings(defaults: defaults)
        if defaults.string(forKey: Keys.defaultAudioLanguage) == nil,
           let audioLanguage = accountDefaults.audioLanguage,
           audioLanguage != defaultAudioLanguage {
            defaultAudioLanguage = audioLanguage
        }
        if resolved.language != defaultSubtitleLanguage {
            defaultSubtitleLanguage = resolved.language
        }
        if resolved.mode != subtitleMode {
            subtitleMode = resolved.mode
        }
    }

    struct StoredSubtitleSettings: Equatable {
        var language: String
        var mode: SubtitleMode
        var forcedSubtitlesEnabled: Bool
    }

    /// Preferred audio language. Order: the viewer's Audio & Subtitles choice
    /// (including "" for Original), the cached Plex account language, then the
    /// device language (`Locale.preferredLanguages`, the same codes subtitles
    /// use), with English only when that yields nothing. A missing key is not
    /// a choice, so a later account default can still apply; a stored value,
    /// including English or Original, is left alone.
    ///
    /// `systemLanguage` exists so tests can pin the device language. Production
    /// passes `systemPreferredSubtitleLanguageCode`.
    static func storedAudioLanguage(
        defaults: UserDefaults,
        systemLanguage: String? = systemPreferredSubtitleLanguageCode
    ) -> String {
        if let chosen = defaults.string(forKey: Keys.defaultAudioLanguage) {
            return chosen
        }
        if let account = defaults.string(forKey: Keys.accountAudioLanguage) {
            return account
        }
        return systemLanguage ?? "en"
    }

    /// Resolves the subtitle settings in this order: the viewer's Dusk choice,
    /// the pre-1.8 "Subtitles" + "Forced Only" pair it replaces, the Plex
    /// account's defaults, then the device language with forced-only
    /// subtitles (the old out-of-the-box behavior).
    ///
    /// Legacy mapping: a language with Forced Only off was "always show"; any
    /// language with Forced Only on, or "None", showed forced subtitles only
    /// (Off); "None" with Forced Only off showed nothing, which is Off with
    /// forced subtitles disabled.
    static func storedSubtitleSettings(defaults: UserDefaults) -> StoredSubtitleSettings {
        let storedLanguage = defaults.string(forKey: Keys.defaultSubtitleLanguage)
        let legacyNone = storedLanguage?.isEmpty == true
        let legacyForcedOnly = defaults.object(forKey: Keys.subtitleForcedOnly) as? Bool

        let language = storedLanguage.flatMap(normalizedLanguageCode(from:))
            ?? defaults.string(forKey: Keys.accountSubtitleLanguage).flatMap(normalizedLanguageCode(from:))
            ?? systemPreferredSubtitleLanguageCode
            ?? "en"

        let mode: SubtitleMode
        if let raw = defaults.string(forKey: Keys.subtitleMode), let stored = SubtitleMode(rawValue: raw) {
            mode = stored
        } else if legacyForcedOnly == false, !legacyNone {
            mode = .always
        } else if legacyForcedOnly != nil || legacyNone {
            mode = .off
        } else {
            mode = defaults.string(forKey: Keys.accountSubtitleMode).flatMap(SubtitleMode.init(rawValue:)) ?? .off
        }

        let forcedSubtitlesEnabled = defaults.object(forKey: Keys.forcedSubtitlesEnabled) as? Bool
            ?? !(legacyNone && legacyForcedOnly == false)

        return StoredSubtitleSettings(language: language, mode: mode, forcedSubtitlesEnabled: forcedSubtitlesEnabled)
    }

    nonisolated static var systemPreferredSubtitleLanguageCode: String? {
        Locale.preferredLanguages.lazy
            .compactMap(normalizedLanguageCode(from:))
            .first
    }

    nonisolated static func normalizedLanguageCode(from identifier: String) -> String? {
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
