import Foundation
import Testing
@testable import Dusk

@Suite("IPTV resume store")
@MainActor
struct IPTVResumeStoreTests {
    private let sourceID = UUID(uuidString: "6F1C2B9E-0D4A-4C55-9A57-3E2E1B7C8D90")!
    private let channelURL = URL(string: "https://tv.example/live/1.m3u8")!
    private let start = Date(timeIntervalSince1970: 1_793_000_000)

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_793_100_000)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "IPTVResumeStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func key(_ offset: TimeInterval = 0) -> IPTVResumeKey {
        IPTVResumeKey(
            sourceID: sourceID,
            channelStreamURL: channelURL,
            start: start.addingTimeInterval(offset),
            end: start.addingTimeInterval(offset + 3600)
        )
    }

    @Test func keyIsStableAndHidesTheURL() {
        let a = key()
        #expect(a == key())
        // Pinned: a changed hash would orphan every saved point.
        #expect(a.rawValue == "5cb7884447aad5d9f6d44d8da7274e97")
        // Case of the source ID and sub-second times do not matter.
        #expect(a.rawValue == IPTVResumeKey(
            sourceID: UUID(uuidString: sourceID.uuidString.lowercased())!,
            channelStreamURL: channelURL,
            start: start.addingTimeInterval(0.4),
            end: start.addingTimeInterval(3600.4)
        ).rawValue)
        #expect(!a.rawValue.contains("tv.example"))
        #expect(a != key(3600))
        #expect(a != IPTVResumeKey(sourceID: sourceID, channelStreamURL: URL(string: "https://tv.example/live/2.m3u8")!,
                                   start: start, end: start.addingTimeInterval(3600)))
        #expect(a != IPTVResumeKey(sourceID: UUID(), channelStreamURL: channelURL,
                                   start: start, end: start.addingTimeInterval(3600)))
    }

    @Test func savesAndReloadsAPosition() {
        let defaults = makeDefaults()
        let clock = Clock()
        let store = IPTVResumeStore(defaults: defaults, now: { clock.now })
        store.record(position: 754, duration: 3600, for: key())
        #expect(store.resumePosition(for: key()) == 754)
        #expect(store.resumePosition(for: key(3600)) == nil)

        let reloaded = IPTVResumeStore(defaults: defaults, now: { clock.now })
        #expect(reloaded.resumePosition(for: key()) == 754)
    }

    @Test func ignoresTheFirstSecondsAndUnseekableStreams() {
        let store = IPTVResumeStore(defaults: makeDefaults())
        store.record(position: 29, duration: 3600, for: key())
        store.record(position: 300, duration: 0, for: key(1))
        store.record(position: 300, duration: .infinity, for: key(2))
        store.record(position: .nan, duration: 3600, for: key(3))
        #expect(store.entries.isEmpty)

        // An early position does not wipe a real one either.
        store.record(position: 600, duration: 3600, for: key())
        store.record(position: 5, duration: 3600, for: key())
        #expect(store.resumePosition(for: key()) == 600)
    }

    @Test func nearTheEndCountsAsFinished() {
        // Last 5%, at most the last two minutes.
        #expect(IPTVResumeStore.isFinished(position: 3480, duration: 3600))
        #expect(!IPTVResumeStore.isFinished(position: 3470, duration: 3600))
        #expect(IPTVResumeStore.isFinished(position: 1715, duration: 1800))
        #expect(!IPTVResumeStore.isFinished(position: 1700, duration: 1800))

        let store = IPTVResumeStore(defaults: makeDefaults())
        store.record(position: 1200, duration: 3600, for: key())
        store.record(position: 3590, duration: 3600, for: key())
        #expect(store.resumePosition(for: key()) == nil)
        // Never-started programmes watched to the end leave nothing behind.
        store.record(position: 3600, duration: 3600, for: key(3600))
        #expect(store.entries[key(3600).rawValue] == nil)
        // A later partial watch resumes again.
        store.record(position: 900, duration: 3600, for: key())
        #expect(store.resumePosition(for: key()) == 900)
    }

    @Test func entriesExpireAfterTwoWeeks() {
        let defaults = makeDefaults()
        let clock = Clock()
        let store = IPTVResumeStore(defaults: defaults, now: { clock.now })
        store.record(position: 600, duration: 3600, for: key())
        clock.now = clock.now.addingTimeInterval(13 * 24 * 3600)
        #expect(store.resumePosition(for: key()) == 600)
        clock.now = clock.now.addingTimeInterval(2 * 24 * 3600)
        #expect(store.resumePosition(for: key()) == nil)

        // Pruned from storage on the next launch.
        let reloaded = IPTVResumeStore(defaults: defaults, now: { clock.now })
        #expect(reloaded.entries.isEmpty)
        #expect(IPTVResumeStore.decode(defaults.data(forKey: IPTVResumeStore.storageKey)).isEmpty)
    }

    @Test func keepsOnlyTheNewestEntries() {
        let clock = Clock()
        let store = IPTVResumeStore(defaults: makeDefaults(), now: { clock.now })
        let total = IPTVResumeStore.maximumCount + 25
        for index in 0..<total {
            clock.now = clock.now.addingTimeInterval(1)
            store.record(position: 600, duration: 3600, for: key(TimeInterval(index) * 3600))
        }
        #expect(store.entries.count == IPTVResumeStore.maximumCount)
        #expect(store.resumePosition(for: key(0)) == nil)
        #expect(store.resumePosition(for: key(24 * 3600)) == nil)
        #expect(store.resumePosition(for: key(25 * 3600)) == 600)
        #expect(store.resumePosition(for: key(TimeInterval(total - 1) * 3600)) == 600)
    }
}
