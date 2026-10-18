import Foundation
import OSLog

private let introFingerprintStoreLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk", category: "AutoSkipIntro"
)

#if canImport(UIKit)
extension IntroFingerprintSeasonKey {
    init?(mediaDetails: PlexMediaDetails, viewerProfileID: String?) {
        guard mediaDetails.type == .episode,
              let viewer = viewerProfileID?.trimmingCharacters(in: .whitespacesAndNewlines), !viewer.isEmpty,
              let server = mediaDetails.serverID?.trimmingCharacters(in: .whitespacesAndNewlines), !server.isEmpty,
              let season = mediaDetails.parentRatingKey?.trimmingCharacters(in: .whitespacesAndNewlines), !season.isEmpty else { return nil }
        self.init(viewerProfileID: viewer, serverID: server, seasonRatingKey: season)
    }
}
#endif

@MainActor
final class IntroFingerprintStore {
    static let shared = IntroFingerprintStore(defaults: .standard)
    private static let defaultsKey = "Dusk.IntroOpeningFingerprints"
    private static let schemaVersion = 3
    private static let maximumReferencesPerSeason = 16
    private static let maximumArchiveBytes = 2 * 1_024 * 1_024
    private static let maximumSeasonContexts = 256
    private static let maximumEpisodeSnapshotSize = 512
    private static let minimumWatchedEpisodesForRemoteReset = 2

    private struct SeasonContext: Codable {
        let key: IntroFingerprintSeasonKey
        var showRatingKey: String?
        var accountProfileID: String?
        var episodeIDs: Set<String>?
        var watchedEpisodeIDs: Set<String>?
        var localEpisodeStates: [String: Bool]?
        var ignoresNextRemoteReset: Bool?
        var updatedAt: Date
    }

    private struct Record: Codable {
        let key: IntroFingerprintSeasonKey
        var fingerprint: IntroOpeningFingerprint
        var updatedAt: Date
        var showRatingKey: String?
        var accountProfileID: String?
    }
    private struct Archive: Codable {
        let schemaVersion: Int
        let records: [Record]
        var seasons: [SeasonContext]?
    }
    private let defaults: UserDefaults
    private var records: [Record] = []
    private var seasons: [IntroFingerprintSeasonKey: SeasonContext] = [:]
    private var generations: [IntroFingerprintSeasonKey: UUID] = [:]
    /// Reject metadata requests that began before a local mutation/reset.
    private(set) var metadataGeneration = UUID()

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        guard data.count <= Self.maximumArchiveBytes,
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.schemaVersion == Self.schemaVersion else {
            introFingerprintStoreLogger.notice("Fingerprint archive ignored: obsolete, invalid, or oversized; openings will be relearned")
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        // Validate persisted input as strictly as newly captured observations.
        records = archive.records.filter { $0.fingerprint.isEligibleReference && Self.isOrdered($0.fingerprint.points) }
            .sorted { $0.updatedAt < $1.updatedAt }
        enforceSeasonLimits()
        for season in (archive.seasons ?? []).filter({
            !$0.key.viewerProfileID.isEmpty && !$0.key.serverID.isEmpty && !$0.key.seasonRatingKey.isEmpty
                && ($0.episodeIDs?.count ?? 0) <= Self.maximumEpisodeSnapshotSize
                && ($0.localEpisodeStates?.count ?? 0) <= Self.maximumEpisodeSnapshotSize
        }).sorted(by: { $0.updatedAt < $1.updatedAt }).suffix(Self.maximumSeasonContexts) {
            seasons[season.key] = season
        }
        introFingerprintStoreLogger.notice("Fingerprint archive loaded records=\(self.records.count) bytes=\(data.count)")
    }

    func generation(for key: IntroFingerprintSeasonKey) -> UUID {
        if let generation = generations[key] { return generation }
        let generation = UUID()
        generations[key] = generation
        return generation
    }

    func registerSeason(_ key: IntroFingerprintSeasonKey, showRatingKey: String?, accountProfileID: String? = nil) {
        guard !key.viewerProfileID.isEmpty, !key.serverID.isEmpty, !key.seasonRatingKey.isEmpty else { return }
        let previous = seasons[key]
        var context = seasons[key] ?? SeasonContext(key: key, updatedAt: Date())
        if let showRatingKey { context.showRatingKey = showRatingKey }
        if let accountProfileID { context.accountProfileID = accountProfileID }
        context.updatedAt = Date()
        seasons[key] = context
        trimSeasonContexts()
        var ownershipChanged = false
        for index in records.indices where records[index].key == key {
            if let show = context.showRatingKey, records[index].showRatingKey != show {
                records[index].showRatingKey = show
                ownershipChanged = true
            }
            if let account = context.accountProfileID, records[index].accountProfileID != account {
                records[index].accountProfileID = account
                ownershipChanged = true
            }
        }
        if ownershipChanged || previous == nil || previous?.showRatingKey != context.showRatingKey || previous?.accountProfileID != context.accountProfileID {
            persist()
        }
    }

    func removeSeason(_ key: IntroFingerprintSeasonKey) {
        invalidate([key])
    }

    /// Also covers seasons removed from the server since they were learned.
    func removeShow(viewerProfileID: String, serverID: String, showRatingKey: String, seasonRatingKeys: [String] = []) {
        let knownKeys = Set(seasons.values.filter {
            $0.key.viewerProfileID == viewerProfileID && $0.key.serverID == serverID && $0.showRatingKey == showRatingKey
        }.map(\.key)).union(records.filter {
            $0.key.viewerProfileID == viewerProfileID && $0.key.serverID == serverID && $0.showRatingKey == showRatingKey
        }.map(\.key))
        invalidate(knownKeys.union(seasonRatingKeys.map {
            IntroFingerprintSeasonKey(viewerProfileID: viewerProfileID, serverID: serverID, seasonRatingKey: $0)
        }))
    }

    func removeItem(viewerProfileID: String, serverID: String, ratingKey: String) {
        let knownKeys = Set(records.map(\.key)).union(seasons.keys).union(generations.keys)
        let showKeys = Set(records.filter { $0.showRatingKey == ratingKey }.map(\.key))
        invalidate(Set(knownKeys.filter {
            $0.viewerProfileID == viewerProfileID && $0.serverID == serverID
                && ($0.seasonRatingKey == ratingKey || seasons[$0]?.showRatingKey == ratingKey || showKeys.contains($0))
        }))
    }

    func removeProfiles(_ profileIDs: Set<String>, accountProfileID: String?) {
        var profiles = profileIDs
        for context in seasons.values where accountProfileID != nil && context.accountProfileID == accountProfileID {
            profiles.insert(context.key.viewerProfileID)
        }
        for record in records where accountProfileID != nil && record.accountProfileID == accountProfileID {
            profiles.insert(record.key.viewerProfileID)
        }
        let keys = Set(records.map(\.key)).union(seasons.keys).union(generations.keys)
            .filter { profiles.contains($0.viewerProfileID) }
        invalidate(Set(keys))
        seasons = seasons.filter { !profiles.contains($0.key.viewerProfileID) }
        persist()
    }

    /// Local episode edits change the baseline but never reset the season.
    /// Overlays survive offline retries and are retired when Plex agrees.
    func noteEpisodeWatchState(viewerProfileID: String, serverID: String, episodeRatingKey: String, watched: Bool, confirmed: Bool = false) {
        metadataGeneration = UUID()
        for key in Array(seasons.keys) where key.viewerProfileID == viewerProfileID && key.serverID == serverID {
            guard var context = seasons[key], context.episodeIDs?.contains(episodeRatingKey) == true else { continue }
            context.localEpisodeStates = context.localEpisodeStates ?? [:]
            context.localEpisodeStates?[episodeRatingKey] = confirmed ? nil : watched
            if watched { context.watchedEpisodeIDs?.insert(episodeRatingKey) }
            else { context.watchedEpisodeIDs?.remove(episodeRatingKey) }
            seasons[key] = context
        }
        persist()
    }

    /// An already-applied offline aggregate reset may reach Plex much later.
    /// Its resulting snapshot must not erase recordings learned in the meantime.
    func noteUnwatchReplay(viewerProfileID: String, serverID: String, ratingKey: String) {
        metadataGeneration = UUID()
        for key in Array(seasons.keys) where key.viewerProfileID == viewerProfileID && key.serverID == serverID {
            guard var context = seasons[key], key.seasonRatingKey == ratingKey || context.showRatingKey == ratingKey else { continue }
            context.ignoresNextRemoteReset = true
            seasons[key] = context
        }
        persist()
    }

    /// Infer resets elsewhere only from a complete, unchanged membership list.
    /// A single episode toggle or a shrinking/empty library is inconclusive.
    func observeSeason(_ key: IntroFingerprintSeasonKey, episodeIDs: Set<String>, watchedEpisodeIDs: Set<String>) {
        guard !episodeIDs.isEmpty, episodeIDs.count <= Self.maximumEpisodeSnapshotSize else { return }
        var context = seasons[key] ?? SeasonContext(key: key, updatedAt: Date())
        var watched = watchedEpisodeIDs.intersection(episodeIDs)
        for (episode, localWatched) in context.localEpisodeStates ?? [:] {
            guard episodeIDs.contains(episode) else { continue }
            if watched.contains(episode) == localWatched { context.localEpisodeStates?[episode] = nil }
            if localWatched { watched.insert(episode) } else { watched.remove(episode) }
        }
        if context.episodeIDs == episodeIDs,
           (context.watchedEpisodeIDs?.count ?? 0) >= Self.minimumWatchedEpisodesForRemoteReset, watched.isEmpty,
           context.ignoresNextRemoteReset != true {
            invalidate([key])
        }
        if watchedEpisodeIDs.isEmpty { context.ignoresNextRemoteReset = nil }
        context.episodeIDs = episodeIDs
        context.watchedEpisodeIDs = watched
        context.updatedAt = Date()
        seasons[key] = context
        trimSeasonContexts()
        metadataGeneration = UUID()
        persist()
    }

    private func invalidate(_ keys: Set<IntroFingerprintSeasonKey>) {
        guard !keys.isEmpty else { return }
        metadataGeneration = UUID()
        for key in keys {
            generations[key] = UUID()
            if var context = seasons[key] {
                context.watchedEpisodeIDs = []
                context.localEpisodeStates = Dictionary(uniqueKeysWithValues: (context.episodeIDs ?? []).map { ($0, false) })
                context.ignoresNextRemoteReset = nil
                seasons[key] = context
            }
        }
        records.removeAll { keys.contains($0.key) }
        persist()
        introFingerprintStoreLogger.notice("Fingerprint cache reset seasons=\(keys.count)")
    }

    private func trimSeasonContexts() {
        let excess = seasons.values.sorted { $0.updatedAt > $1.updatedAt }.dropFirst(Self.maximumSeasonContexts)
        for context in excess { seasons[context.key] = nil }
    }

    func fingerprints(for key: IntroFingerprintSeasonKey, excluding playbackSessionID: UUID? = nil) -> [IntroOpeningFingerprint] {
        records.filter {
            $0.key == key && $0.fingerprint.playbackSessionID != playbackSessionID
        }.map(\.fingerprint)
    }

    /// Upserts one factual recording, never a blended or transitively merged
    /// prototype. An ambiguous but adequately watched opening remains learnable.
    @discardableResult
    func insert(_ fingerprint: IntroOpeningFingerprint, for key: IntroFingerprintSeasonKey, generation: UUID? = nil) -> Bool {
        if let generation, generation != self.generation(for: key) { return false }
        guard fingerprint.isEligibleReference, Self.isOrdered(fingerprint.points),
              !key.viewerProfileID.isEmpty, !key.serverID.isEmpty, !key.seasonRatingKey.isEmpty else { return false }
        if let index = records.firstIndex(where: {
            $0.key == key && $0.fingerprint.observationID == fingerprint.observationID
        }) {
            guard fingerprint.points.count > records[index].fingerprint.points.count else { return true }
            records[index].fingerprint = fingerprint
            records[index].updatedAt = Date()
        } else {
            records.append(Record(key: key, fingerprint: fingerprint, updatedAt: Date(),
                                  showRatingKey: seasons[key]?.showRatingKey, accountProfileID: seasons[key]?.accountProfileID))
        }
        enforceSeasonLimits()
        persist()
        introFingerprintStoreLogger.notice("Fingerprint recording saved episode=\(fingerprint.episodeRatingKey, privacy: .public) observation=\(fingerprint.observationID.uuidString, privacy: .public) points=\(fingerprint.points.count) references=\(self.records.count)")
        return true
    }

    private static func isOrdered(_ points: [IntroFingerprintPoint]) -> Bool {
        zip(points, points.dropFirst()).allSatisfy { $0.time < $1.time }
    }

    private func enforceSeasonLimits() {
        var counts: [IntroFingerprintSeasonKey: Int] = [:]
        records = records.reversed().filter { record in
            let count = counts[record.key, default: 0]
            counts[record.key] = count + 1
            return count < Self.maximumReferencesPerSeason
        }.reversed()
    }

    private func persist() {
        do {
            func encode() throws -> Data {
                try JSONEncoder().encode(Archive(schemaVersion: Self.schemaVersion, records: records, seasons: Array(seasons.values)))
            }
            var data = try encode()
            while data.count > Self.maximumArchiveBytes {
                if !records.isEmpty { records.removeFirst() }
                else if let oldest = seasons.values.min(by: { $0.updatedAt < $1.updatedAt }) { seasons[oldest.key] = nil }
                else { break }
                data = try encode()
            }
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            introFingerprintStoreLogger.error("Fingerprint archive could not be encoded: \(String(describing: error), privacy: .public)")
        }
    }
}
