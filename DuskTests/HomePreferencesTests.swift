import Foundation
import Testing
@testable import Dusk

@Suite("Home preferences")
struct HomePreferencesTests {
    @Test("Personalized shelves defaults on and persists both switch positions")
    @MainActor func personalizedShelvesPersistence() {
        let defaults = UserDefaults.standard
        let key = "personalizedShelvesEnabled"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        let preferences = UserPreferences()
        #expect(preferences.personalizedShelvesEnabled)
        preferences.personalizedShelvesEnabled = false
        #expect(!UserPreferences().personalizedShelvesEnabled)
        preferences.personalizedShelvesEnabled = true
        #expect(UserPreferences().personalizedShelvesEnabled)
    }

    @Test("Compact Continue Watching defaults off and persists both switch positions")
    @MainActor func compactContinueWatchingPersistence() {
        let defaults = UserDefaults.standard
        let key = "compactHomeContinueWatching"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        let preferences = UserPreferences()
        #expect(!preferences.compactHomeContinueWatching)
        preferences.compactHomeContinueWatching = true
        #expect(UserPreferences().compactHomeContinueWatching)
        preferences.compactHomeContinueWatching = false
        #expect(!UserPreferences().compactHomeContinueWatching)
    }

    @Test("Continue Watching Artwork defaults to Poster and persists both choices")
    @MainActor func continueWatchingArtworkPersistence() {
        let defaults = UserDefaults.standard
        let key = "continueWatchingArtwork"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        let preferences = UserPreferences()
        #expect(preferences.continueWatchingArtwork == .poster)
        preferences.continueWatchingArtwork = .episodeStill
        #expect(UserPreferences().continueWatchingArtwork == .episodeStill)
        preferences.continueWatchingArtwork = .poster
        #expect(UserPreferences().continueWatchingArtwork == .poster)
    }

    @Test("Hide Spoilers blurs only an unfinished episode's description")
    func blursSummary() {
        #expect(UserPreferences.blursSummary(isUnwatchedEpisode: true, hidesSpoilers: true))
        #expect(!UserPreferences.blursSummary(isUnwatchedEpisode: false, hidesSpoilers: true))
        #expect(!UserPreferences.blursSummary(isUnwatchedEpisode: true, hidesSpoilers: false))
    }
}
