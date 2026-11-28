import Foundation
import Testing
@testable import Dusk

/// G5 (docs/jellyfin/05-plan.md §3), the preference half: the UserDefaults
/// keys of `UserPreferences`, the per-library stores and Seerr, and the raw
/// values of every enum persisted by `rawValue`. Every expected string is a
/// literal captured from the pre-refactor build: a type rename may not change
/// what an existing install has stored. Keys are pinned through the read path
/// (seed the literal key, read it back through the real type), so a renamed
/// key fails even though it is private.
@Suite("Persisted preference golden strings", .serialized)
@MainActor
struct PersistedPreferenceGoldenTests {
    // MARK: - Raw values

    @Test func libraryTypeRawValues() {
        // Stored in `libraryTabOrder` / `hiddenLibraryTabs`.
        #expect(LibraryKind.allCases.map(\.rawValue) == ["movie", "show", "video", "liveTV", "photo", "playlists"])
    }

    @Test func mediaTypeRawValues() {
        // Stored in download records and deep links.
        let literals = ["movie", "show", "person", "season", "episode", "clip", "artist", "album", "track",
                        "collection", "unknown"]
        let types: [MediaKind] = [.movie, .show, .person, .season, .episode, .clip, .artist, .album, .track,
                                      .collection, .unknown]
        #expect(types.map(\.rawValue) == literals)
        #expect(literals.compactMap(MediaKind.init(rawValue:)) == types)
    }

    @Test func playbackPreferenceRawValues() {
        #expect(MaxResolution.allCases.map(\.rawValue) == ["auto", "4k", "1080p", "720p"])
        #expect(PreferredMediaVersion.allCases.map(\.rawValue) == ["automatic", "highestQuality", "1080p", "smallestFile"])
        #expect(SubtitleMode.allCases.map(\.rawValue) == ["off", "auto", "always"])
        #expect(SubtitleFontSize.allCases.map(\.rawValue) == ["extraSmall", "small", "medium", "large"])
        #expect(SubtitleStyle.allCases.map(\.rawValue) == ["system", "dusk"])
        #expect(VideoEnhancementMode.allCases.map(\.rawValue) == ["automatic", "enabled", "disabled"])
        #expect(AutoSkipIntroMode.allCases.map(\.rawValue) == ["off", "always", "alwaysExceptFirstEpisode"])
        #expect(PlayerSeekInterval.allCases.map(\.rawValue) == [5, 10, 15, 30, 45, 60])
        #expect(ContinuousPlayCountdown.allCases.map(\.rawValue) == [3, 5, 10, 15])
    }

    @Test func appAndDownloadPreferenceRawValues() {
        #expect(AppearanceMode.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(ContinueWatchingArtwork.allCases.map(\.rawValue) == ["poster", "episodeStill"])
        #expect(DownloadConcurrency.allCases.map(\.rawValue) == [1, 2, 3])
        #expect(DownloadFreeSpaceReserve.allCases.map(\.rawValue)
            == [1_000_000_000, 5_000_000_000, 10_000_000_000, 20_000_000_000])
        #expect(DownloadQuality.allCases.map(\.rawValue)
            == ["original", "p1080High", "p1080", "p720", "p720Low", "p480", "p320"])
    }

    @Test func librarySortRawValues() {
        #expect(LibrarySortField.allCases.map(\.rawValue) == [
            "title", "releaseDate", "year", "addedAt", "lastEpisodeAdded", "userRating", "criticRating",
            "audienceRating", "duration", "lastViewed", "random",
        ])
        #expect(LibrarySortOption(.addedAt, descending: true).rawValue == "addedAt:desc")
        #expect(LibrarySortOption.titleAscending.rawValue == "title")
        #expect(LibrarySortOption(rawValue: "year:desc") == LibrarySortOption(.year, descending: true))
        // Names of the fixed sorts that came before still read.
        #expect(LibrarySortOption(rawValue: "titleDescending") == .titleDescending)
        #expect(LibrarySortOption(rawValue: "durationDescending") == LibrarySortOption(.duration, descending: true))
    }

    // MARK: - Keys

    @Test func perLibraryKeys() {
        #expect(LibrarySortStore.key(forLibraryID: "srv|3") == "librarySort.srv|3")
        #expect(LibraryUnwatchedFilterStore.key(forLibraryID: "srv|3") == "libraryUnwatchedOnly.srv|3")
    }

    /// Seeds `UserDefaults.standard` with an old install's values under the
    /// literal keys and reads them back through `UserPreferences.init`.
    @Test func userPreferenceKeysReadThroughInit() async throws {
        let seeded: [String: Any] = [
            "maxResolution": "1080p",
            "preferredVersion": "smallestFile",
            "subtitleFontSize": "large",
            "subtitleStyle": "dusk",
            "videoEnhancementMode": "disabled",
            "autoSkipIntroMode": "alwaysExceptFirstEpisode",
            "continuousPlayCountdown": 15,
            "playerDoubleTapForwardInterval": 30,
            "playerDoubleTapBackwardInterval": 5,
            "appearanceMode": "dark",
            "libraryTabOrder": ["show", "movie", "photo"],
            "hiddenLibraryTabs": ["video"],
            "continueWatchingArtwork": "episodeStill",
            "showsClock": false,
            "downloadMaxResolution": "720p",
            "maximumActiveDownloads": 3,
            "downloadFreeSpaceReserve": 20_000_000_000,
        ]
        try await LegacyFixture.preservingStandardDefaults(Array(seeded.keys)) {
            for (key, value) in seeded {
                UserDefaults.standard.set(value, forKey: key)
            }
            let preferences = UserPreferences()
            #expect(preferences.maxResolution == .tenEightyP)
            #expect(preferences.preferredVersion == .smallestFile)
            #expect(preferences.subtitleFontSize == .large)
            #expect(preferences.subtitleStyle == .dusk)
            #expect(preferences.videoEnhancementMode == .disabled)
            #expect(preferences.autoSkipIntroMode == .alwaysExceptFirstEpisode)
            #expect(preferences.continuousPlayCountdown == .fifteenSeconds)
            #expect(preferences.playerDoubleTapForwardInterval == .thirtySeconds)
            #expect(preferences.playerDoubleTapBackwardInterval == .fiveSeconds)
            #expect(preferences.appearanceMode == .dark)
            #expect(Array(preferences.libraryTabOrder.prefix(3)) == [.show, .movie, .photo])
            #expect(!preferences.isLibraryTabVisible(.video))
            #expect(preferences.isLibraryTabVisible(.movie))
            #expect(preferences.continueWatchingArtwork == .episodeStill)
            #expect(preferences.showsClock == false)
            #expect(preferences.downloadMaxResolution == .sevenTwentyP)
            #expect(preferences.maximumActiveDownloads == .three)
            #expect(preferences.downloadFreeSpaceReserve == .twentyGB)
        }
    }

    /// The Dusk subtitle/audio choices win over the Plex-account defaults,
    /// which are stored under their own literal keys.
    @Test func languageKeys() throws {
        let suite = "dusk.golden.languages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("de", forKey: "plexAccountAudioLanguage")
        defaults.set("fr", forKey: "plexAccountSubtitleLanguage")
        defaults.set("always", forKey: "plexAccountSubtitleMode")
        #expect(UserPreferences.storedAudioLanguage(defaults: defaults, systemLanguage: "en") == "de")
        #expect(UserPreferences.storedSubtitleSettings(defaults: defaults)
            == .init(language: "fr", mode: .always, forcedSubtitlesEnabled: true))

        defaults.set("it", forKey: "defaultAudioLanguage")
        defaults.set("es", forKey: "defaultSubtitleLanguage")
        defaults.set("auto", forKey: "subtitleMode")
        defaults.set(false, forKey: "forcedSubtitlesEnabled")
        #expect(UserPreferences.storedAudioLanguage(defaults: defaults, systemLanguage: "en") == "it")
        #expect(UserPreferences.storedSubtitleSettings(defaults: defaults)
            == .init(language: "es", mode: .auto, forcedSubtitlesEnabled: false))
    }

    @Test func seerrConfigurationKeys() async throws {
        try await LegacyFixture.preservingStandardDefaults(["SeerrBaseURL", "SeerrPlexServerID"]) {
            UserDefaults.standard.set("https://seerr.example.test", forKey: "SeerrBaseURL")
            UserDefaults.standard.set("golden-server", forKey: "SeerrPlexServerID")
            let seerr = SeerrService(media: MediaService())
            #expect(seerr.configuredBaseURL == URL(string: "https://seerr.example.test"))
            #expect(seerr.configuredPlexServerID == "golden-server")
        }
    }
}
