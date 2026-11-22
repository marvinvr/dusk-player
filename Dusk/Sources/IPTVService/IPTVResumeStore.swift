import CryptoKit
import Foundation

/// Identifies one past IPTV programme across launches: a hash of the source,
/// the channel's own (live) stream URL and the programme's airtime. Never the
/// catch-up URL itself, which can carry "now"-relative values (`{lutc}`,
/// `{offset}`) or tokens that change between plays.
struct IPTVResumeKey: Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(sourceID: UUID, channelStreamURL: URL, start: Date, end: Date) {
        let identity = [
            sourceID.uuidString.lowercased(),
            channelStreamURL.absoluteString,
            String(Int(start.timeIntervalSince1970)),
            String(Int(end.timeIntervalSince1970)),
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8))
        // 128 bits is plenty for a couple of hundred entries and keeps the
        // stored dictionary small.
        rawValue = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// A catch-up programme of an IPTV channel; nil for anything else (a
    /// live channel has no resume point).
    init?(channel: PlexLiveChannel, program: PlexLiveProgram) {
        guard let live = channel.iptv, let start = program.beginsAt, let end = program.endsAt else { return nil }
        self.init(sourceID: live.sourceID, channelStreamURL: live.streamURL, start: start, end: end)
    }
}

/// How far a past IPTV programme was watched (Plex knows nothing of IPTV).
/// Small and throwaway: a capped dictionary in UserDefaults, entries expire
/// after two weeks, losing it is harmless. Mirrored to iCloud key-value
/// storage when the app has it (`IPTVResumeCloud`), merged per entry by the
/// newest write; without it everything stays on the device.
///
/// A finished programme leaves a position-less entry (a tombstone) instead of
/// disappearing, so a merged copy of the dictionary cannot bring an older
/// resume point back. Tombstones expire like everything else.
@MainActor
final class IPTVResumeStore {
    struct Entry: Codable, Equatable, Sendable {
        /// Seconds into the programme; nil once it was watched to the end.
        var position: TimeInterval?
        var duration: TimeInterval
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case position = "p"
            case duration = "d"
            case updatedAt = "t"
        }
    }

    static let shared = IPTVResumeStore(cloud: UbiquitousIPTVResumeCloud())

    /// Positions this early are not worth resuming (nor worth saving).
    static let minimumPosition: TimeInterval = 30
    static let maximumAge: TimeInterval = 14 * 24 * 3600
    static let maximumCount = 200
    static let storageKey = "iptvResumePoints"

    /// Within the last 5% of the programme, and at most its last two
    /// minutes, it counts as watched (credits, padding of the catch-up).
    static func isFinished(position: TimeInterval, duration: TimeInterval) -> Bool {
        position >= duration - min(120, duration * 0.05)
    }

    private let defaults: UserDefaults
    private let cloud: IPTVResumeCloud?
    private let now: () -> Date
    private(set) var entries: [String: Entry]

    init(defaults: UserDefaults = .standard, cloud: IPTVResumeCloud? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.cloud = cloud
        self.now = now
        entries = Self.decode(defaults.data(forKey: Self.storageKey))
        if prune() { persist() }
        cloud?.observeExternalChanges { [weak self] in self?.mergeFromCloud() }
        mergeFromCloud()
    }

    /// Where to offer resuming the programme from, if anywhere.
    func resumePosition(for key: IPTVResumeKey) -> TimeInterval? {
        guard let entry = entries[key.rawValue], let position = entry.position,
              now().timeIntervalSince(entry.updatedAt) < Self.maximumAge else { return nil }
        return position
    }

    /// Saves the playback position. Only finite, seekable programmes count
    /// (a positive duration); the first seconds are ignored and the end
    /// marks the programme as finished.
    func record(position: TimeInterval, duration: TimeInterval, for key: IPTVResumeKey) {
        guard position.isFinite, duration.isFinite, duration > 0, position >= Self.minimumPosition else { return }
        let finished = Self.isFinished(position: position, duration: duration)
        if finished, entries[key.rawValue] == nil { return }
        let entry = Entry(position: finished ? nil : min(position, duration), duration: duration, updatedAt: now())
        // The same second again (a paused player's ticks) changes nothing.
        if let old = entries[key.rawValue], old.position.map(Int.init) == entry.position.map(Int.init) { return }
        entries[key.rawValue] = entry
        prune()
        persist()
        // Merged first: the cloud may hold another device's newer entries.
        mergeFromCloud()
    }

    /// Takes the cloud copy's newer entries; pushes back when this device
    /// had something the cloud did not.
    func mergeFromCloud() {
        guard let cloud else { return }
        let remote = Self.decode(cloud.read())
        let merged = Self.merged(entries, remote, now: now())
        if merged != entries {
            entries = merged
            persist()
        }
        if merged != remote, let data = try? JSONEncoder().encode(merged) {
            cloud.write(data)
        }
    }

    /// Per entry, the newer write wins (a tombstone included); then expiry
    /// and the cap.
    static func merged(_ local: [String: Entry], _ remote: [String: Entry], now: Date) -> [String: Entry] {
        let combined = local.merging(remote) { mine, theirs in theirs.updatedAt > mine.updatedAt ? theirs : mine }
        return pruned(combined, now: now)
    }

    /// Drops expired entries, then the oldest beyond the cap. Returns
    /// whether anything was dropped.
    @discardableResult
    func prune() -> Bool {
        let before = entries.count
        entries = Self.pruned(entries, now: now())
        return entries.count != before
    }

    static func pruned(_ entries: [String: Entry], now: Date) -> [String: Entry] {
        var kept = entries.filter { now.timeIntervalSince($0.value.updatedAt) < maximumAge }
        if kept.count > maximumCount {
            let newest = kept.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(maximumCount)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        return kept
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func decode(_ data: Data?) -> [String: Entry] {
        guard let data, let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return decoded
    }
}

/// Where the resume points are mirrored for the viewer's other devices.
@MainActor
protocol IPTVResumeCloud: AnyObject {
    func read() -> Data?
    func write(_ data: Data)
    /// Calls back on the main actor when another device changed the copy.
    func observeExternalChanges(_ handler: @escaping @MainActor () -> Void)
}

/// iCloud key-value storage (`com.apple.developer.ubiquity-kvstore-identifier`).
/// One key, ~15 KB at the 200-entry cap, far below the 1 MB limit. Without
/// the entitlement or an iCloud account the store only keeps a local copy,
/// so this degrades to device-only on its own.
@MainActor
final class UbiquitousIPTVResumeCloud: IPTVResumeCloud {
    static let key = "iptvResumePoints"
    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    func read() -> Data? {
        store.data(forKey: Self.key)
    }

    func write(_ data: Data) {
        store.set(data, forKey: Self.key)
    }

    func observeExternalChanges(_ handler: @escaping @MainActor () -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        // Fetches what changed while the app was not running.
        store.synchronize()
    }
}
