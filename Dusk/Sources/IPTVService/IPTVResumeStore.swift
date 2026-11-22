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

/// How far a past IPTV programme was watched, kept on this device only (Plex
/// knows nothing of IPTV). Small and throwaway: a capped dictionary in
/// UserDefaults, entries expire after two weeks, losing it is harmless.
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

    static let shared = IPTVResumeStore()

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
    private let now: () -> Date
    private(set) var entries: [String: Entry]

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        entries = Self.decode(defaults.data(forKey: Self.storageKey))
        if prune() { persist() }
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
