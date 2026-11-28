import Foundation
import Network
import Observation
#if os(iOS)
import UIKit
#endif

private enum DownloadManagerError: LocalizedError {
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64, reserveBytes: Int64)
    case invalidDownloadStatus(statusCode: Int)
    case invalidDownloadContentType(String)
    case emptyDownloadedFile
    case incompleteDownloadedFile(expectedBytes: Int64, actualBytes: Int64)
    case unexpectedDownloadedPayload

    var errorDescription: String? {
        switch self {
        case let .insufficientStorage(requiredBytes, availableBytes, reserveBytes):
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            let reserve = ByteCountFormatter.string(fromByteCount: reserveBytes, countStyle: .file)
            return "Not enough free storage. This download needs \(required), with \(available) available and \(reserve) reserved."
        case let .invalidDownloadStatus(statusCode):
            return "The server returned HTTP \(statusCode) instead of a video file."
        case let .invalidDownloadContentType(contentType):
            return "The server returned \(contentType) instead of a video file."
        case .emptyDownloadedFile:
            return "The downloaded file is empty."
        case let .incompleteDownloadedFile(expectedBytes, actualBytes):
            let expected = ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
            let actual = ByteCountFormatter.string(fromByteCount: actualBytes, countStyle: .file)
            return "The downloaded file is incomplete. Expected \(expected), got \(actual)."
        case .unexpectedDownloadedPayload:
            return "The downloaded file looks like a server error response instead of a video file."
        }
    }
}

private struct SmoothedDownloadSpeed {
    private static let smoothingFactor = 0.18

    private(set) var bytesPerSecond: Double?
    private var lastSampleDate: Date?
    private var lastDownloadedBytes: Int64?

    mutating func update(downloadedBytes: Int64, at date: Date = .now) {
        defer {
            lastSampleDate = date
            lastDownloadedBytes = downloadedBytes
        }

        guard let lastSampleDate, let lastDownloadedBytes else { return }
        let elapsed = date.timeIntervalSince(lastSampleDate)
        let bytesDelta = downloadedBytes - lastDownloadedBytes
        guard elapsed >= 0.25, bytesDelta > 0 else { return }

        let measuredBytesPerSecond = Double(bytesDelta) / elapsed
        guard measuredBytesPerSecond.isFinite, measuredBytesPerSecond > 0 else { return }

        if let current = bytesPerSecond {
            bytesPerSecond = current
                + (measuredBytesPerSecond - current) * Self.smoothingFactor
        } else {
            bytesPerSecond = measuredBytesPerSecond
        }
    }
}

@MainActor
@Observable
final class DownloadManager {
    private static let progressPersistInterval: TimeInterval = 5

    private let media: MediaService
    private let preferences: UserPreferences
    private let fileStore: DownloadFileStore
    private let metadataCache: MetadataSnapshotCache

    private(set) var storedRecords: [DownloadedMediaRecord] = []
    private(set) var isProcessingQueue = false
    private(set) var isQueuePaused = false
    private(set) var deletingDownloadIDs: Set<String> = []
    /// Keep Next N Unwatched rules of every profile; see `SmartDownloads.swift`.
    private(set) var storedSmartDownloadRules: [SmartDownloadRule] = []

    private(set) var isNetworkConstrained = false

    @ObservationIgnored private var isProfileSwitching = false
    @ObservationIgnored private var isReconcilingTransfers = true
    @ObservationIgnored private var hasDeferredProfileActivation = false
    @ObservationIgnored private var pendingProfileSuspensionTaskIDs: Set<Int> = []
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    /// Servers that were connected at the last observation, so only a server
    /// that has just come back re-runs the queue.
    @ObservationIgnored private var connectedServerIDs: Set<String> = []
    @ObservationIgnored private var networkMonitorQueue = DispatchQueue(label: "com.dusk.networkMonitor")
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingQueueRemovals: [DownloadQueueRemoval] = []
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var lastProgressPersistDates: [String: Date] = [:]
    @ObservationIgnored private var speedEstimates: [String: SmoothedDownloadSpeed] = [:]
    /// Records whose external subtitles are being fetched, and the ones a
    /// backfill already tried this launch (a failure waits for the next one).
    @ObservationIgnored private var subtitleCachingKeys: Set<String> = []
    @ObservationIgnored private var subtitleBackfillAttemptedKeys: Set<String> = []
    /// Running refills by rule key, and rules asked to refill again meanwhile.
    @ObservationIgnored private var smartRefillTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var smartRefillReruns: [String: Set<String>] = [:]
    /// Pending local watch state (`OfflinePlaybackSyncManager.effectiveWatched`)
    /// so an episode watched offline counts before Plex has heard about it.
    /// Arguments: server id, rating key, Plex's watched state.
    @ObservationIgnored var effectiveWatchedState: ((String, String, Bool) -> Bool)?
    /// The path monitor has reported at least once, so `isNetworkConstrained`
    /// is real rather than its initial false (matters for a background launch).
    @ObservationIgnored private var hasNetworkPath = false
    /// Records whose current transfer has received bytes since it started.
    /// A handed-off transfer without any is still waiting inside URLSession.
    private var transferBytesReceivedKeys: Set<String> = []
    /// Records requeued once after their transfer failed before any bytes
    /// arrived (`DownloadQueuePolicy.shouldRequeueAfterFailure`).
    @ObservationIgnored private var requeuedAfterFailureKeys: Set<String> = []
    /// Records paused only to restart their transfer with new request flags
    /// (Wi-Fi Only changed, or a live transfer moving to the background
    /// session). Their pause event requeues them instead of pausing.
    @ObservationIgnored private var restartingTransferKeys: Set<String> = []
    /// Downloads finished by a background wake that are still being moved
    /// into place; the wake's completion handler waits for them.
    @ObservationIgnored private var pendingCompletionCount = 0
    /// Relaunch reconciliation ran before a profile was active: transfers it
    /// kept running (global key → task) and in-flight records it left alone.
    /// `judgeRelaunchedTransfersIfNeeded` settles them once a profile is.
    @ObservationIgnored private var unjudgedRelaunchTransfers: [String: Int] = [:]
    @ObservationIgnored private var unjudgedRelaunchRecords: Set<String> = []
    /// Whether the scene is in the background (set by `DuskApp`).
    @ObservationIgnored private(set) var isAppInBackground = false
    #if os(iOS)
    /// The system Live Activity for downloads the user started (iOS 26+).
    @ObservationIgnored private(set) lazy var continuedTask = DownloadContinuedTaskController(downloadManager: self)
    #endif
    /// The Simultaneous Downloads setting is the session's per-host
    /// connection limit, read once when the session is created (a change
    /// applies from the next launch; the background session cannot be
    /// reconfigured while its transfers live on).
    @ObservationIgnored private lazy var transferController = DownloadTransferController(
        maximumConnectionsPerHost: preferences.maximumActiveDownloads.rawValue
    ) { [weak self] event in
        Task { @MainActor [weak self] in
            self?.handleTransferEvent(event)
        }
    }

    init(
        media: MediaService,
        preferences: UserPreferences,
        fileStore: DownloadFileStore = DownloadFileStore()
    ) {
        self.media = media
        self.preferences = preferences
        self.fileStore = fileStore
        self.metadataCache = MetadataSnapshotCache(fileStore: fileStore, formats: media.metadataSnapshotFormats)
        try? fileStore.prepareRootDirectory()
        let snapshot = fileStore.loadSnapshot()
        storedRecords = snapshot.records
        pendingQueueRemovals = snapshot.pendingQueueRemovals ?? []
        storedSmartDownloadRules = snapshot.smartDownloadRules ?? []
        rekeyLegacyServerIdentifiers()
        reconcileCompletedFiles()
        _ = transferController
        startNetworkMonitoring()
        observeServerConnectivity()
        connectedServerIDs = Set(media.pool.connections.map(\.serverID))
        Task { [weak self] in
            await self?.reconcileExistingTransfers()
        }
    }

    /// Downloads waiting on a server that was offline or switched off resume as
    /// soon as that server comes back, without the user touching anything.
    private func observeServerConnectivity() {
        withObservationTracking {
            _ = media.pool.connections.map(\.serverID)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.serverConnectivityDidChange()
            }
        }
    }

    private func serverConnectivityDidChange() {
        observeServerConnectivity()
        rekeyLegacyServerIdentifiers()
        let current = Set(media.pool.connections.map(\.serverID))
        let appeared = current.subtracting(connectedServerIDs)
        connectedServerIDs = current
        guard !appeared.isEmpty else { return }
        processQueueIfNeeded()
        backfillExternalSubtitles(serverIDs: appeared)
        refillSmartDownloads(serverIDs: appeared)
    }

    /// Records written before servers were identified by machine identifier can
    /// carry the server's base URL instead. Those records match no connection,
    /// so their downloads would wait forever; re-key them once the server they
    /// belong to is known. A URL that resolves to nothing is left untouched —
    /// the record stays listed and its completed file stays playable offline.
    private func rekeyLegacyServerIdentifiers() {
        var changed = false
        for index in storedRecords.indices {
            let legacyServerID = storedRecords[index].serverID
            guard !media.isKnownServerID(legacyServerID),
                  let resolved = media.serverID(forLegacyConnectionURI: legacyServerID),
                  resolved != legacyServerID else {
                continue
            }
            if let accountProfileID = storedRecords[index].accountProfileID {
                // The cached metadata lives in a per-server directory, so it has
                // to travel with the record or the item loses its offline detail.
                fileStore.relocateMetadata(
                    accountProfileID: accountProfileID,
                    fromServerID: legacyServerID,
                    toServerID: resolved
                )
            }
            storedRecords[index].serverID = resolved
            storedRecords[index].serverName = serverName(for: resolved)
                ?? storedRecords[index].serverName
            storedRecords[index].updatedAt = .now
            changed = true
        }
        guard changed else { return }
        persist()
    }

    /// Why a queued download is not moving: its server is switched off or not
    /// reachable right now. Nil while the queue is actually able to run.
    func queueWaitReason(for record: DownloadedMediaRecord) -> String? {
        if DownloadQueuePolicy.isWaitingForWiFi(
            status: record.status,
            wifiOnly: preferences.downloadsWifiOnly,
            isNetworkConstrained: isNetworkConstrained
        ) {
            return "Waiting for Wi-Fi"
        }
        guard record.status == .queued else { return nil }
        let name = serverName(for: record.serverID) ?? record.serverName ?? "the server"
        switch media.pool.state(for: record.serverID) {
        case .connected:
            return nil
        case .disabled:
            return "\(name) is turned off"
        case .unauthorized:
            return "\(name) did not accept this device"
        case .idle, .connecting, .offline:
            return "Waiting for \(name)"
        }
    }

    /// The active Plex Home profile's downloads. Other profiles remain
    /// persisted but are deliberately invisible to UI and playback lookups.
    var records: [DownloadedMediaRecord] {
        storedRecords.filter { $0.accountProfileID == media.activeProfileID }
    }

    var queuedRecords: [DownloadedMediaRecord] {
        records
            .filter { $0.status != .completed }
            .sorted { $0.addedAt < $1.addedAt }
    }

    var storageUsageBytes: Int64 {
        fileStore.storageUsageBytes()
    }

    var availableStorageBytes: Int64? {
        fileStore.availableStorageBytes()
    }

    /// Preparing or transferring right now; a transfer still waiting inside
    /// URLSession for a free slot counts as queued.
    var activeDownloadCount: Int {
        records.filter {
            $0.status == .preparing || ($0.status == .downloading && !isAwaitingTransfer($0))
        }.count
    }

    var downloadedMovies: [DownloadedMediaRecord] {
        records
            .filter { ($0.type == .movie || $0.type == .clip) && $0.status == .completed }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var downloadedEpisodes: [DownloadedMediaRecord] {
        records
            .filter { $0.type == .episode && $0.status == .completed }
            .sorted { lhs, rhs in
                let leftShow = lhs.grandparentTitle ?? lhs.title
                let rightShow = rhs.grandparentTitle ?? rhs.title
                if leftShow != rightShow {
                    return leftShow.localizedStandardCompare(rightShow) == .orderedAscending
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    var downloadedShows: [DownloadedShowSummary] {
        // Grouped on (server, show rating key): show keys are per-server
        // counters, so grouping on the key alone would fold two unrelated shows
        // from two servers into one row — with the wrong server's artwork and a
        // combined episode count.
        let grouped = Dictionary(grouping: downloadedEpisodes) { record in
            MediaItemID(
                serverID: record.serverID,
                itemID: record.grandparentID ?? record.parentID ?? record.itemID
            )
        }

        let rules = activeSmartDownloadRules
        var summaries = grouped.compactMap { showID, episodes -> DownloadedShowSummary? in
            guard let first = episodes.first,
                  let accountProfileID = first.accountProfileID else {
                return nil
            }
            let showKey = showID.itemID
            // Every record in the group shares the server the key was grouped on.
            let serverID = first.serverID
            let cachedShow = metadataCache.mediaDetails(
                accountProfileID: accountProfileID,
                serverID: serverID,
                itemID: showKey,
                kind: first.providerKind
            )
            let title = cachedShow?.title ?? first.grandparentTitle ?? "TV Show"
            return DownloadedShowSummary(
                serverID: serverID,
                itemID: showKey,
                title: title,
                thumbPath: cachedShow?.thumb ?? first.thumbPath,
                artPath: cachedShow?.art ?? first.artPath,
                downloadedEpisodeCount: episodes.count,
                totalEpisodeCount: cachedShow?.episodeCount,
                smartRule: rules.first { $0.showID == MediaItemID(serverID: serverID, itemID: showKey) }
            )
        }
        // A smart show stays listed while its next episodes are still on the
        // way or it is fully watched, so the rule can always be found and
        // turned off.
        for rule in rules where !summaries.contains(where: { $0.mediaItemID == rule.showID }) {
            let cachedShow = metadataCache.mediaDetails(
                accountProfileID: rule.accountProfileID,
                serverID: rule.serverID,
                itemID: rule.showRatingKey,
                kind: snapshotKind(for: rule.serverID)
            )
            summaries.append(DownloadedShowSummary(
                serverID: rule.serverID,
                itemID: rule.showRatingKey,
                title: cachedShow?.title ?? rule.showTitle ?? "TV Show",
                thumbPath: cachedShow?.thumb ?? rule.thumbPath,
                artPath: cachedShow?.art ?? rule.artPath,
                downloadedEpisodeCount: 0,
                totalEpisodeCount: cachedShow?.episodeCount,
                smartRule: rule,
                pendingEpisodeCount: records.filter {
                    $0.type == .episode && $0.status != .completed && matchesBranch($0, of: rule.showID)
                }.count
            ))
        }
        return summaries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The record for one item.
    ///
    /// Strict by design: the answer feeds `localPlaybackURL` and
    /// `downloadedMediaVersion`, so matching the wrong server's record would
    /// play a different file. An `id` without a server (an unstamped offline
    /// cache, a legacy route) is only resolved when exactly one record carries
    /// that rating key — an ambiguous match is no match.
    func record(for id: MediaItemID) -> DownloadedMediaRecord? {
        guard let serverID = id.serverID else {
            let matches = records.filter { $0.itemID == id.itemID }
            return matches.count == 1 ? matches.first : nil
        }
        return records.first { $0.itemID == id.itemID && $0.serverID == serverID }
    }

    func serverID(for id: MediaItemID) -> String? {
        record(for: id)?.serverID
    }

    func canPause(id: MediaItemID) -> Bool {
        record(for: id)?.status.canPause == true
    }

    func canResume(id: MediaItemID) -> Bool {
        record(for: id)?.status.canResume == true
    }

    func status(for id: MediaItemID) -> DownloadStatus? {
        record(for: id)?.status
    }

    func status(for id: MediaItemID, type: MediaKind) -> DownloadStatus? {
        downloadState(for: DownloadScope(id: id, type: type)).status
    }

    func progress(for id: MediaItemID) -> Double? {
        record(for: id)?.progress
    }

    func progress(for id: MediaItemID, type: MediaKind) -> Double? {
        let state = downloadState(for: DownloadScope(id: id, type: type))
        return state.hasRecords ? state.progress : nil
    }

    func estimatedTimeRemaining(for record: DownloadedMediaRecord) -> TimeInterval? {
        estimatedTimeRemaining(globalKey: record.globalKey, remainingBytes: remainingBytes(for: record))
    }

    func downloadSpeedBytesPerSecond(for record: DownloadedMediaRecord) -> Double? {
        speedEstimates[record.globalKey]?.bytesPerSecond
    }

    var queueDownloadSpeedBytesPerSecond: Double? {
        let bytesPerSecond = records.reduce(0) { total, record in
            guard record.status == .downloading else { return total }
            return total + (speedEstimates[record.globalKey]?.bytesPerSecond ?? 0)
        }
        return bytesPerSecond > 0 ? bytesPerSecond : nil
    }

    var estimatedQueueTimeRemaining: TimeInterval? {
        let records = queuedRecords
        guard !records.isEmpty,
              records.allSatisfy({ $0.totalBytes != nil }),
              let bytesPerSecond = queueDownloadSpeedBytesPerSecond else {
            return nil
        }

        let remainingBytes = records
            .map(remainingBytes(for:))
            .reduce(Int64(0), +)
        guard remainingBytes > 0 else { return nil }

        return TimeInterval(Double(remainingBytes) / bytesPerSecond)
    }

    func isDownloaded(id: MediaItemID) -> Bool {
        record(for: id)?.status == .completed
    }

    func isDeletingDownload(id: MediaItemID) -> Bool {
        guard let record = record(for: id) else { return false }
        return deletingDownloadIDs.contains(record.globalKey)
    }

    func isDeletingDownload(id: MediaItemID, type: MediaKind) -> Bool {
        downloadState(for: DownloadScope(id: id, type: type)).isDeleting
    }

    func isDeletingDownloads(show: MediaItemID) -> Bool {
        records
            .filter { matchesBranch($0, of: show) }
            .contains { deletingDownloadIDs.contains($0.globalKey) }
    }

    func downloadState(for scope: DownloadScope) -> DownloadControlState {
        let records = relatedRecords(for: scope)
        return DownloadControlState(
            scope: scope,
            status: aggregateStatus(for: records),
            progress: aggregateProgress(for: records) ?? 0,
            isDeleting: records.contains { deletingDownloadIDs.contains($0.globalKey) },
            records: records
        )
    }

    func isPlayableOffline(id: MediaItemID) -> Bool {
        localPlaybackURL(for: id) != nil
    }

    func hasDownloadedEpisodes(show: MediaItemID) -> Bool {
        downloadedEpisodes.contains { matchesBranch($0, of: show) }
    }

    func hasDownloadedEpisodes(season: MediaItemID) -> Bool {
        downloadedEpisodes.contains { matchesSeason($0, of: season) }
    }

    func downloadedEpisodeCount(season: MediaItemID) -> Int {
        downloadedEpisodes.filter { matchesSeason($0, of: season) }.count
    }

    func downloadedEpisodeCount(show: MediaItemID) -> Int {
        downloadedEpisodes.filter { record in
            record.grandparentID == show.itemID && matchesServer(record, of: show)
        }.count
    }

    func queueDownload(id: MediaItemID, type: MediaKind, isClip: Bool = false, quality: DownloadQuality? = nil) async {
        let initiatingProfileID = media.activeProfileID
        let scope = DownloadScope(id: id, type: type)
        let retainedQuality = record(for: id)?.downloadQuality ?? relatedRecords(for: scope).first?.downloadQuality
        let quality = isClip || type == .clip ? .original : (quality ?? retainedQuality ?? .original)
        do {
            switch type {
            case .movie, .episode, .clip:
                try await queueSingleDownload(id: id, type: type, isClip: isClip, quality: quality)
            case .season:
                try await queueSeasonDownload(season: id, quality: quality)
            case .show:
                try await queueShowDownload(show: id, quality: quality)
            default:
                break
            }
            removeAggregatePlaceholder(for: DownloadScope(id: id, type: type))
            processQueueIfNeeded()
            noteUserStartedDownloads()
        } catch {
            guard !(error is CancellationError), !isProfileSwitching,
                  initiatingProfileID == media.activeProfileID else { return }
            upsertFailedPlaceholder(id: id, type: type, isClip: isClip, quality: quality, error: error)
        }
    }

    func queueDownload(episode: Episode, quality: DownloadQuality = .original) async {
        let initiatingProfileID = media.activeProfileID
        do {
            try await queueEpisodeDownload(episode, quality: quality)
            processQueueIfNeeded()
            noteUserStartedDownloads()
        } catch {
            guard !(error is CancellationError), !isProfileSwitching,
                  initiatingProfileID == media.activeProfileID else { return }
            upsertFailedPlaceholder(id: episode.id, type: .episode, quality: quality, error: error)
        }
    }

    /// An episode record belongs to a season when both the key and the server
    /// match; a nil server on the scope means "any server", for callers that
    /// only have a cached key.
    private func matchesSeason(_ record: DownloadedMediaRecord, of season: MediaItemID) -> Bool {
        record.parentID == season.itemID && matchesServer(record, of: season)
    }

    private func matchesBranch(_ record: DownloadedMediaRecord, of show: MediaItemID) -> Bool {
        (record.grandparentID == show.itemID || record.parentID == show.itemID)
            && matchesServer(record, of: show)
    }

    private func matchesServer(_ record: DownloadedMediaRecord, of id: MediaItemID) -> Bool {
        id.serverID == nil || record.serverID == id.serverID
    }

    /// Pauses the outgoing profile before MediaService replaces its credentials.
    /// Call this before changing `activeProfileID`.
    func prepareForProfileSwitch() {
        isProfileSwitching = true
        isQueuePaused = true
        queueTask?.cancel()
        queueTask = nil
        isProcessingQueue = false

        for record in records where record.status.canPause {
            pauseDownload(globalKey: record.globalKey, forProfileSwitch: true)
        }
    }

    /// Refreshes queue ownership after MediaService has installed a profile.
    /// Legacy adoption must only be requested for the original pre-Plex-Home
    /// account, never for an arbitrary user selected from the Home picker.
    func activateProfile() {
        if media.shouldAdoptLegacyProfileData,
           let primaryProfileID = media.primaryProfileID?.nilIfEmpty {
            let legacyServerIDs = Set(
                storedRecords
                    .filter { $0.accountProfileID == nil }
                    .map(\.serverID)
            )
            var changed = false
            for index in storedRecords.indices where storedRecords[index].accountProfileID == nil {
                storedRecords[index].accountProfileID = primaryProfileID
                changed = true
            }
            if changed {
                fileStore.adoptLegacyMetadata(
                    accountProfileID: primaryProfileID,
                    serverIDs: legacyServerIDs
                )
                persist()
            }
        }

        guard !isReconcilingTransfers,
              pendingProfileSuspensionTaskIDs.isEmpty else {
            hasDeferredProfileActivation = true
            return
        }
        completeProfileActivation()
    }

    /// The deferred half of relaunch reconciliation: running transfers of
    /// another profile pause, in-flight records without a transfer (and
    /// without a finished event since launch) go back to the queue.
    private func judgeRelaunchedTransfersIfNeeded() {
        guard !unjudgedRelaunchTransfers.isEmpty || !unjudgedRelaunchRecords.isEmpty,
              media.isSessionReady, let activeProfileID = media.activeProfileID else { return }
        let transfers = unjudgedRelaunchTransfers
        let orphans = unjudgedRelaunchRecords
        unjudgedRelaunchTransfers = [:]
        unjudgedRelaunchRecords = []
        var changed = false
        for (key, taskIdentifier) in transfers {
            guard let index = storedRecords.firstIndex(where: { $0.globalKey == key }),
                  storedRecords[index].status == .downloading,
                  storedRecords[index].downloadTaskIdentifier == taskIdentifier,
                  storedRecords[index].accountProfileID != activeProfileID else { continue }
            storedRecords[index].status = .paused
            storedRecords[index].wasPausedForProfileSwitch = true
            storedRecords[index].updatedAt = .now
            pendingProfileSuspensionTaskIDs.insert(taskIdentifier)
            transferController.pause(taskIdentifier: taskIdentifier)
            changed = true
        }
        for key in orphans {
            guard let index = storedRecords.firstIndex(where: { $0.globalKey == key }),
                  storedRecords[index].status == .preparing || storedRecords[index].status == .downloading
            else { continue }
            if storedRecords[index].accountProfileID == activeProfileID {
                storedRecords[index].status = .queued
                storedRecords[index].wasPausedForProfileSwitch = false
            } else {
                storedRecords[index].status = .paused
                storedRecords[index].wasPausedForProfileSwitch = true
            }
            storedRecords[index].downloadTaskIdentifier = nil
            storedRecords[index].updatedAt = .now
            changed = true
        }
        if changed { persist() }
    }

    private func completeProfileActivation() {
        judgeRelaunchedTransfersIfNeeded()
        hasDeferredProfileActivation = false
        lastProgressPersistDates.removeAll()
        speedEstimates.removeAll()
        let activeProfileID = media.activeProfileID
        var resumedProfileQueue = false
        for index in storedRecords.indices
        where storedRecords[index].accountProfileID == activeProfileID
            && storedRecords[index].wasPausedForProfileSwitch
            && storedRecords[index].status == .paused {
            storedRecords[index].wasPausedForProfileSwitch = false
            storedRecords[index].status = .queued
            storedRecords[index].downloadTaskIdentifier = nil
            storedRecords[index].errorMessage = nil
            storedRecords[index].updatedAt = .now
            resumedProfileQueue = true
        }
        if resumedProfileQueue {
            persist()
        }
        isProfileSwitching = false
        isQueuePaused = false
        processQueueIfNeeded()
        backfillExternalSubtitles(serverIDs: Set(media.pool.connections.map(\.serverID)))
        refillSmartDownloads()
    }

    private func completeDeferredProfileActivationIfPossible() {
        guard hasDeferredProfileActivation,
              !isReconcilingTransfers,
              pendingProfileSuspensionTaskIDs.isEmpty else {
            return
        }
        completeProfileActivation()
    }

    func retryDownload(id: MediaItemID) {
        guard let record = record(for: id) else { return }
        retryDownload(globalKey: record.globalKey)
        noteUserStartedDownloads()
    }

    private func retryDownload(globalKey: String) {
        guard let index = storedRecords.firstIndex(where: { $0.globalKey == globalKey }) else { return }
        fileStore.deleteResumeData(relativePath: storedRecords[index].resumeDataPath)
        enqueueQueueRemoval(for: storedRecords[index])
        storedRecords[index].queueClientIdentifier = nil
        storedRecords[index].plexDownloadQueueID = nil
        storedRecords[index].plexDownloadItemID = nil
        storedRecords[index].convertedMediaData = nil
        storedRecords[index].preparationProgress = nil
        storedRecords[index].preparationRetryCount = 0
        storedRecords[index].status = .queued
        storedRecords[index].progress = 0
        storedRecords[index].downloadedBytes = 0
        storedRecords[index].resumeDataPath = nil
        storedRecords[index].downloadTaskIdentifier = nil
        storedRecords[index].wasPausedForProfileSwitch = false
        storedRecords[index].errorMessage = nil
        storedRecords[index].updatedAt = .now
        speedEstimates.removeValue(forKey: storedRecords[index].globalKey)
        persist()
        processQueueIfNeeded()
    }

    func pauseDownload(id: MediaItemID) {
        guard let record = record(for: id) else { return }
        pauseDownload(globalKey: record.globalKey, forProfileSwitch: false)
    }

    private func pauseDownload(globalKey: String, forProfileSwitch: Bool) {
        guard let index = storedRecords.firstIndex(where: { $0.globalKey == globalKey }),
              storedRecords[index].status.canPause else {
            return
        }

        preparationTasks[globalKey]?.cancel()
        storedRecords[index].wasPausedForProfileSwitch = forProfileSwitch
        if let taskIdentifier = storedRecords[index].downloadTaskIdentifier {
            if forProfileSwitch {
                pendingProfileSuspensionTaskIDs.insert(taskIdentifier)
            }
            storedRecords[index].status = .paused
            storedRecords[index].updatedAt = .now
            persist()
            transferController.pause(taskIdentifier: taskIdentifier)
        } else {
            storedRecords[index].status = .paused
            storedRecords[index].downloadTaskIdentifier = nil
            storedRecords[index].updatedAt = .now
            persist()
            processQueueIfNeeded()
        }
    }

    func pauseDownload(id: MediaItemID, type: MediaKind) {
        pauseDownload(scope: DownloadScope(id: id, type: type))
    }

    func pauseDownload(scope: DownloadScope) {
        performOnRelatedRecords(scope) { record in
            guard record.status.canPause else { return }
            pauseDownload(globalKey: record.globalKey, forProfileSwitch: false)
        }
    }

    func resumeDownload(id: MediaItemID) {
        guard let record = record(for: id) else { return }
        resumeDownload(globalKey: record.globalKey)
        noteUserStartedDownloads()
    }

    private func resumeDownload(globalKey: String) {
        guard let index = storedRecords.firstIndex(where: { $0.globalKey == globalKey }),
              storedRecords[index].status.canResume else {
            return
        }
        if storedRecords[index].status == .failed {
            retryDownload(globalKey: globalKey)
            return
        }
        storedRecords[index].status = .queued
        storedRecords[index].wasPausedForProfileSwitch = false
        storedRecords[index].downloadTaskIdentifier = nil
        storedRecords[index].errorMessage = nil
        storedRecords[index].updatedAt = .now
        persist()
        processQueueIfNeeded()
    }

    func resumeDownload(id: MediaItemID, type: MediaKind) {
        resumeDownload(scope: DownloadScope(id: id, type: type))
    }

    func resumeDownload(scope: DownloadScope) {
        performOnRelatedRecords(scope) { record in
            guard record.status.canResume else { return }
            resumeDownload(globalKey: record.globalKey)
        }
        noteUserStartedDownloads()
    }

    func cancelDownload(id: MediaItemID) {
        guard let record = record(for: id) else { return }
        cancelDownload(record)
    }

    private func cancelDownload(_ record: DownloadedMediaRecord) {
        guard record.status != .completed else { return }
        deleteRecords([record])
    }

    func cancelDownload(id: MediaItemID, type: MediaKind) {
        cancelDownload(scope: DownloadScope(id: id, type: type))
    }

    func cancelDownload(scope: DownloadScope) {
        performOnRelatedRecords(scope) { record in
            cancelDownload(record)
        }
    }

    func pauseAllDownloads() {
        isQueuePaused = true
        let pausableKeys = records
            .filter { $0.status.canPause && !deletingDownloadIDs.contains($0.globalKey) }
            .map(\.globalKey)
        for globalKey in pausableKeys {
            pauseDownload(globalKey: globalKey, forProfileSwitch: false)
        }
    }

    func resumeAllDownloads() {
        isQueuePaused = false
        var changed = false
        let activeProfileID = media.activeProfileID
        for index in storedRecords.indices
        where storedRecords[index].accountProfileID == activeProfileID
            && storedRecords[index].status == .paused
            && !deletingDownloadIDs.contains(storedRecords[index].globalKey) {
            storedRecords[index].status = .queued
            storedRecords[index].wasPausedForProfileSwitch = false
            storedRecords[index].downloadTaskIdentifier = nil
            storedRecords[index].errorMessage = nil
            storedRecords[index].updatedAt = .now
            changed = true
        }
        if changed {
            persist()
        }
        processQueueIfNeeded()
        noteUserStartedDownloads()
    }

    func resumePendingWork() {
        processQueueIfNeeded()
        refillSmartDownloads()
    }

    /// Wi-Fi Only is enforced by URLSession, not by pausing: every transfer
    /// request disallows expensive and constrained networks while it is on,
    /// so a transfer on cellular simply waits (even while Dusk is suspended)
    /// and continues on Wi-Fi by itself. Queue rows say "Waiting for Wi-Fi".
    ///
    /// A request's flags are fixed when its task is created, so toggling the
    /// setting restarts the handed-off transfers (keeping their resume data)
    /// with the new flags. Called by `DuskApp` when the setting changes.
    func wifiOnlyPreferenceDidChange() {
        let keys = records
            .filter { $0.status == .downloading && !deletingDownloadIDs.contains($0.globalKey) }
            .map(\.globalKey)
        for globalKey in keys {
            restartTransfer(globalKey: globalKey)
        }
    }

    /// Stops a handed-off transfer (resume data kept) and queues it again, so
    /// the queue creates a new task: new request flags, or the background
    /// session instead of the live one.
    private func restartTransfer(globalKey: String) {
        guard let record = record(globalKey: globalKey), record.status == .downloading,
              let taskIdentifier = record.downloadTaskIdentifier else { return }
        restartingTransferKeys.insert(globalKey)
        // Transient: the pause event turns it back into `.queued`.
        update(globalKey: globalKey) {
            $0.status = .paused
            $0.updatedAt = .now
        }
        transferController.pause(taskIdentifier: taskIdentifier)
    }

    /// The session's start-order hint for a new transfer: its position among
    /// the records still to download (`DownloadQueuePolicy.transferPriority`).
    private func transferPriority(for globalKey: String) -> Float {
        let pending = records
            .filter { $0.status != .completed && $0.status != .failed && $0.status != .cancelled }
            .sorted { $0.addedAt < $1.addedAt }
        let position = pending.firstIndex { $0.globalKey == globalKey } ?? pending.count
        return DownloadQueuePolicy.transferPriority(position: position)
    }

    /// A handed-off transfer that has not received a byte yet: the session
    /// starts it when one of the Simultaneous Downloads slots frees up.
    func isAwaitingTransfer(_ record: DownloadedMediaRecord) -> Bool {
        DownloadQueuePolicy.isAwaitingTransfer(
            status: record.status,
            downloadedBytes: record.downloadedBytes,
            isMoving: transferBytesReceivedKeys.contains(record.globalKey)
        )
    }

    // MARK: - Live Activity

    /// The user started, resumed or retried downloads: show the system Live
    /// Activity for the queue (iOS 26+). Automatic work never calls this.
    private func noteUserStartedDownloads() {
        #if os(iOS)
        continuedTask.userStartedDownloads()
        #endif
    }

    /// The queue as the Live Activity sees it: the active profile's active
    /// records, plus `includingFinished` keys in any state.
    func activityItems(includingFinished keys: Set<String> = []) -> [DownloadActivityItem] {
        records
            .filter { $0.status == .queued || $0.status == .preparing || $0.status == .downloading || keys.contains($0.globalKey) }
            .filter { !deletingDownloadIDs.contains($0.globalKey) }
            .sorted { $0.addedAt < $1.addedAt }
            .map { record in
                DownloadActivityItem(
                    globalKey: record.globalKey,
                    title: record.title,
                    showTitle: record.type == .episode ? record.grandparentTitle?.nilIfEmpty : nil,
                    episodeLabel: record.type == .episode ? (record.subtitle?.nilIfEmpty ?? "Episode") : nil,
                    isConverted: record.downloadQuality != .original,
                    serverName: serverName(for: record.serverID) ?? record.serverName,
                    status: record.status,
                    progress: record.progress,
                    preparationProgress: record.preparationProgress,
                    downloadedBytes: record.downloadedBytes,
                    totalBytes: record.totalBytes,
                    isAwaitingTransfer: isAwaitingTransfer(record),
                    waitReason: queueWaitReason(for: record)
                )
            }
    }

    /// The continued task ended (queue done, everything waiting, or expired).
    /// Live transfers must not be left in a process iOS may now suspend.
    func continuedTaskDidEnd() {
        if isAppInBackground {
            moveLiveTransfersToBackgroundSession()
        }
    }

    // MARK: - Background

    /// New transfers go to the in-process session only while the downloads
    /// continued-processing task keeps Dusk running in the background (see
    /// `DownloadTransferController`).
    private var usesLiveTransfers: Bool {
        #if os(iOS)
        #if DEBUG
        // `-DuskDebugLiveTransfers 1`: foreground transfers use the live
        // session, so the move to the background session on leaving the app
        // can be exercised in the simulator (which has no BGTaskScheduler).
        if UserDefaults.standard.string(forKey: "DuskDebugLiveTransfers") == "1" { return !isAppInBackground }
        #endif
        return isAppInBackground && continuedTask.isRunning
        #else
        return false
        #endif
    }

    func sceneDidEnterBackground() {
        isAppInBackground = true
        #if os(iOS)
        if !continuedTask.isRunning {
            moveLiveTransfersToBackgroundSession()
        }
        #endif
    }

    func sceneDidBecomeActive() {
        isAppInBackground = false
    }

    /// Live transfers stop when Dusk is suspended. Before that can happen
    /// (the continued task ended, or Dusk left the foreground without one),
    /// they restart in the background session from their resume data.
    func moveLiveTransfersToBackgroundSession() {
        let keys = storedRecords
            .filter {
                $0.status == .downloading
                    && $0.downloadTaskIdentifier.map(DownloadTransferController.isLiveIdentifier) == true
            }
            .map(\.globalKey)
        guard !keys.isEmpty else { return }
        for globalKey in keys {
            restartTransfer(globalKey: globalKey)
        }
        #if os(iOS)
        // Pausing (resume data) and re-creating the tasks takes a moment;
        // keep Dusk running until they are in the background session.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "Move live downloads")
        Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            while ContinuousClock.now < deadline, let self, self.hasPendingLiveMove(keys) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            UIApplication.shared.endBackgroundTask(assertion)
        }
        #endif
    }

    /// Whether any of `keys` is still paused for its restart, queued, being
    /// prepared, or on a live task.
    private func hasPendingLiveMove(_ keys: [String]) -> Bool {
        keys.contains { key in
            guard let record = record(globalKey: key) else { return false }
            switch record.status {
            case .queued, .preparing:
                return true
            case .paused:
                return restartingTransferKeys.contains(key)
            case .downloading:
                return record.downloadTaskIdentifier.map(DownloadTransferController.isLiveIdentifier) ?? true
            case .completed, .failed, .cancelled:
                return false
            }
        }
    }

    /// A background wake delivered its events. Calling iOS's completion
    /// handler lets it suspend Dusk, so first let the queue hand off what
    /// it can (finished files moved into place, the next transfers created),
    /// up to `DownloadQueuePolicy.backgroundWakeSettleLimit`.
    private func completeBackgroundEventsWhenSettled(sessionIdentifier: String) {
        Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: DownloadQueuePolicy.backgroundWakeSettleLimit)
            var isPrepared = false
            // A cold background launch has no Plex session yet; bringing it up
            // is bounded by the same deadline as the rest.
            let preparation = Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.media.isSessionReady {
                    _ = await self.prepareSessionForBackgroundWork()
                }
                self.processQueueIfNeeded()
                // One beat so `processQueue` can mark records `.preparing`.
                try? await Task.sleep(for: .milliseconds(200))
                isPrepared = true
            }
            while clock.now < deadline {
                if isPrepared, self?.isSettledForBackgroundSuspension ?? true { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            // `preparation` is left to finish if iOS keeps Dusk running.
            _ = preparation
            DownloadBackgroundSessionRegistry.completeEvents(for: sessionIdentifier)
        }
    }

    private var isSettledForBackgroundSuspension: Bool {
        queueTask == nil
            && pendingCompletionCount == 0
            && !storedRecords.contains { $0.status == .preparing && $0.downloadQuality == .original }
    }

    /// Brings the Plex session up when iOS launched Dusk in the background
    /// without a scene (background URLSession wake, BGTask). Returns whether
    /// the session is ready.
    func prepareSessionForBackgroundWork() async -> Bool {
        guard media.isAuthenticated else { return false }
        if !media.homeBootstrapCompleted {
            try? await media.bootstrapHomeSession()
        }
        guard media.isSessionReady, !Task.isCancelled else { return false }
        // The scene's `.task` does this on a normal launch.
        activateProfile()
        // Wait for the first network path so Wi-Fi Only state is real.
        for _ in 0..<20 where !hasNetworkPath {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if media.pool.connections.isEmpty {
            _ = try? await media.connectAllServers(trigger: "Background")
        }
        return !Task.isCancelled
    }

    func deleteDownload(id: MediaItemID) {
        guard let record = record(for: id) else { return }
        deleteRecords([record])
    }

    func deleteDownload(id: MediaItemID, type: MediaKind) {
        deleteDownload(scope: DownloadScope(id: id, type: type))
    }

    func deleteDownload(scope: DownloadScope) {
        // Deleting a whole show also ends its rule, or the next refill would
        // bring the episodes straight back.
        if scope.type == .show {
            removeSmartDownloadRule(show: scope.id)
        }
        deleteRecords(relatedRecords(for: scope))
    }

    func deleteDownloads(show: MediaItemID) {
        deleteDownload(scope: DownloadScope(id: show, type: .show))
    }

    func deleteAllDownloads() {
        let activeProfileID = media.activeProfileID
        storedSmartDownloadRules.removeAll { $0.accountProfileID == activeProfileID }
        persist()
        deleteRecords(records)
    }

    func localPlaybackURL(for id: MediaItemID, selectedMediaID: String? = nil) -> URL? {
        guard let record = record(for: id),
              record.status == .completed,
              selectedMediaID == nil || selectedMediaID == record.mediaID else {
            return nil
        }
        return fileStore.existingFileURL(for: record.relativeVideoPath)
    }

    /// The saved copy of one of the download's external subtitles, if any.
    func localSubtitleURL(for id: MediaItemID, streamID: String) -> URL? {
        guard let record = record(for: id), record.status == .completed else { return nil }
        return fileStore.existingFileURL(for: record.externalSubtitlePaths?[streamID])
    }

    func downloadedMediaVersion(
        for id: MediaItemID,
        in details: MediaDetails,
        selectedMediaID: String? = nil
    ) -> (media: MediaVersion, part: MediaPart)? {
        guard let record = record(for: id),
              record.status == .completed,
              selectedMediaID == nil || selectedMediaID == record.mediaID else {
            return nil
        }
        if record.downloadQuality != .original {
            return record.convertedMediaVersion(sourcePart: sourcePart(for: record, in: details))
        }
        guard let mediaID = record.mediaID,
              let partID = record.partID,
              let media = details.media.first(where: { $0.id == mediaID }),
              let part = media.parts.first(where: { $0.id == partID }) else {
            return nil
        }
        return (media, part)
    }

    func cachedMediaDetails(for id: MediaItemID) -> MediaDetails? {
        guard let accountProfileID = media.activeProfileID?.nilIfEmpty else { return nil }
        return metadataCache.firstCachedMediaDetails(
            accountProfileID: accountProfileID,
            itemID: id.itemID,
            serverIDs: candidateServerIDs(for: id),
            kind: snapshotKind(for:)
        )
    }

    func cachedSeasons(show: MediaItemID) -> [Season]? {
        guard let accountProfileID = media.activeProfileID?.nilIfEmpty else { return nil }
        return metadataCache.firstCachedSeasons(
            accountProfileID: accountProfileID,
            showKey: show.itemID,
            serverIDs: candidateServerIDs(for: show),
            kind: snapshotKind(for:)
        )
    }

    func cachedEpisodes(season: MediaItemID) -> [Episode]? {
        guard let accountProfileID = media.activeProfileID?.nilIfEmpty else { return nil }
        return metadataCache.firstCachedEpisodes(
            accountProfileID: accountProfileID,
            seasonKey: season.itemID,
            serverIDs: candidateServerIDs(for: season),
            kind: snapshotKind(for:)
        )
    }

    func cachedNextDownloadedEpisode(after episode: MediaDetails) -> Episode? {
        guard episode.type == .episode,
              let seasonKey = episode.parentID,
              let showKey = episode.grandparentID else {
            return nil
        }

        let serverID = episode.serverID
        let currentSeasonEpisodes = (cachedEpisodes(season: MediaItemID(serverID: serverID, itemID: seasonKey)) ?? [])
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

        if let currentEpisodeIndex = currentSeasonEpisodes.firstIndex(where: { $0.itemID == episode.itemID }) {
            let remainingEpisodes = currentSeasonEpisodes[currentSeasonEpisodes.index(after: currentEpisodeIndex)...]
            if let nextDownloadedEpisode = remainingEpisodes.first(where: { isPlayableOffline(id: $0.id) }) {
                return nextDownloadedEpisode
            }
        } else if let currentEpisodeNumber = episode.index,
                  let nextDownloadedEpisode = currentSeasonEpisodes.first(where: {
                      ($0.index ?? 0) > currentEpisodeNumber
                      && isPlayableOffline(id: $0.id)
                  }) {
            return nextDownloadedEpisode
        }

        let seasons = (cachedSeasons(show: MediaItemID(serverID: serverID, itemID: showKey)) ?? [])
            .sorted { $0.index < $1.index }
        let currentSeasonIndex = episode.parentIndex
            ?? seasons.first(where: { $0.itemID == seasonKey })?.index

        guard let currentSeasonIndex else { return nil }

        for season in seasons where season.index > currentSeasonIndex {
            let episodes = (cachedEpisodes(season: season.id) ?? [])
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            if let firstDownloadedEpisode = episodes.first(where: { isPlayableOffline(id: $0.id) }) {
                return firstDownloadedEpisode
            }
        }

        return nil
    }

    /// `MediaService.getAdjacentEpisodes` over the metadata cache, limited to
    /// episodes that play offline: the neighbours a download-only session can
    /// actually reach.
    func cachedAdjacentDownloadedEpisodes(around episode: MediaDetails) -> AdjacentEpisodes {
        guard episode.type == .episode,
              let seasonKey = episode.parentID,
              let showKey = episode.grandparentID else {
            return AdjacentEpisodes()
        }

        let serverID = episode.serverID
        let isDownloaded: (Episode) -> Bool = { [self] in isPlayableOffline(id: $0.id) }
        let currentSeasonEpisodes = (cachedEpisodes(season: MediaItemID(serverID: serverID, itemID: seasonKey)) ?? [])
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        var adjacent = AdjacentEpisodes.inSeason(
            currentSeasonEpisodes,
            around: episode,
            isEligible: isDownloaded
        )
        guard adjacent.previous == nil || adjacent.next == nil else { return adjacent }

        let seasons = (cachedSeasons(show: MediaItemID(serverID: serverID, itemID: showKey)) ?? [])
            .sorted { $0.index < $1.index }
        let currentSeasonIndex = episode.parentIndex
            ?? seasons.first(where: { $0.itemID == seasonKey })?.index
        guard let currentSeasonIndex else { return adjacent }

        func downloadedEpisodes(in season: Season) -> [Episode] {
            (cachedEpisodes(season: season.id) ?? [])
                .filter(isDownloaded)
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        }

        if adjacent.next == nil {
            adjacent.next = seasons
                .filter { $0.index > currentSeasonIndex }
                .lazy
                .compactMap { downloadedEpisodes(in: $0).first }
                .first
        }

        if adjacent.previous == nil {
            adjacent.previous = seasons
                .filter { $0.index < currentSeasonIndex && $0.index > 0 }
                .reversed()
                .lazy
                .compactMap { downloadedEpisodes(in: $0).last }
                .first
        }

        return adjacent
    }

    func localArtworkURL(for path: String?) -> URL? {
        guard let url = fileStore.artworkURL(for: path),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Where to look for one item's cached metadata: its own server first, then
    /// the connected servers in priority order, then every server that already
    /// holds a record. A cache hit on the wrong server would be a different
    /// title, so the item's own server always wins.
    private func candidateServerIDs(for id: MediaItemID) -> [String] {
        var ids: [String] = []
        if let serverID = id.serverID {
            ids.append(serverID)
        }
        for serverID in media.pool.connections.map(\.serverID) where !ids.contains(serverID) {
            ids.append(serverID)
        }
        for serverID in records.map(\.serverID) where !ids.contains(serverID) {
            ids.append(serverID)
        }
        return ids
    }

    /// The server a new download belongs to: the item's own, or the primary one
    /// when the caller could not say (an unstamped item from a cache).
    private func downloadServerID(for id: MediaItemID) throws -> String {
        guard let serverID = id.serverID ?? media.pool.primary?.serverID else {
            throw MediaServiceError.noServerConnected
        }
        return serverID
    }

    private func serverName(for serverID: String) -> String? {
        media.pool.server(for: serverID)?.name
            ?? media.pool.connection(for: serverID)?.name
    }

    private func queueSingleDownload(id: MediaItemID, type: MediaKind, isClip: Bool = false, quality: DownloadQuality = .original) async throws {
        guard type == .movie || type == .episode || type == .clip else { return }
        guard !isProfileSwitching,
              media.isSessionReady,
              let accountProfileID = media.activeProfileID?.nilIfEmpty else {
            throw MediaServiceError.notAuthenticated
        }
        let serverID = try downloadServerID(for: id)
        let itemID = id.itemID

        if let existing = record(for: MediaItemID(serverID: serverID, itemID: itemID)),
           existing.status != .cancelled {
            if existing.status.canResume { resumeDownload(globalKey: existing.globalKey) }
            return
        }

        let cachedDetails = metadataCache.mediaDetails(
            accountProfileID: accountProfileID,
            serverID: serverID,
            itemID: itemID,
            kind: snapshotKind(for: serverID)
        )
        let record = DownloadedMediaRecord(
            accountProfileID: accountProfileID,
            serverID: serverID,
            serverName: serverName(for: serverID),
            provider: providerTag(for: serverID),
            itemID: itemID,
            type: cachedDetails?.type ?? type,
            isClip: isClip || type == .clip || cachedDetails?.isClip == true,
            title: cachedDetails?.title ?? "Download",
            subtitle: cachedDetails.flatMap(subtitle),
            parentID: cachedDetails?.parentID,
            parentTitle: nil,
            grandparentID: cachedDetails?.grandparentID,
            grandparentTitle: cachedDetails?.grandparentTitle,
            thumbPath: cachedDetails.flatMap { $0.thumb ?? $0.parentThumb ?? $0.grandparentThumb },
            artPath: cachedDetails?.art,
            mediaID: nil,
            partID: nil,
            downloadQuality: quality,
            relativeVideoPath: nil,
            resumeDataPath: nil,
            downloadTaskIdentifier: nil,
            status: .queued,
            progress: 0,
            downloadedBytes: 0,
            totalBytes: nil,
            errorMessage: nil,
            addedAt: .now,
            updatedAt: .now
        )

        upsert(record)
    }

    private func queueEpisodeDownload(
        _ episode: Episode,
        quality: DownloadQuality = .original,
        isSmartDownload: Bool = false
    ) async throws {
        guard !isProfileSwitching,
              media.isSessionReady,
              let accountProfileID = media.activeProfileID?.nilIfEmpty else {
            throw MediaServiceError.notAuthenticated
        }
        let serverID = try downloadServerID(for: episode.id)

        if let existing = record(for: MediaItemID(serverID: serverID, itemID: episode.itemID)),
           existing.status != .cancelled {
            if existing.status.canResume { resumeDownload(globalKey: existing.globalKey) }
            return
        }

        let cachedDetails = metadataCache.mediaDetails(
            accountProfileID: accountProfileID,
            serverID: serverID,
            itemID: episode.itemID,
            kind: snapshotKind(for: serverID)
        )
        let record = DownloadedMediaRecord(
            accountProfileID: accountProfileID,
            serverID: serverID,
            serverName: serverName(for: serverID),
            provider: providerTag(for: serverID),
            itemID: episode.itemID,
            type: .episode,
            title: cachedDetails?.title ?? episode.title,
            subtitle: cachedDetails.map(subtitle) ?? MediaTextFormatter.seasonEpisodeLabel(
                season: episode.parentIndex,
                episode: episode.index
            ),
            parentID: cachedDetails?.parentID ?? episode.parentID,
            parentTitle: episode.parentTitle,
            grandparentID: cachedDetails?.grandparentID ?? episode.grandparentID,
            grandparentTitle: cachedDetails?.grandparentTitle ?? episode.grandparentTitle,
            thumbPath: cachedDetails.flatMap { $0.thumb ?? $0.parentThumb ?? $0.grandparentThumb }
                ?? episode.thumb
                ?? episode.grandparentThumb,
            artPath: cachedDetails?.art ?? episode.art,
            mediaID: nil,
            partID: nil,
            downloadQuality: quality,
            isSmartDownload: isSmartDownload,
            relativeVideoPath: nil,
            resumeDataPath: nil,
            downloadTaskIdentifier: nil,
            status: .queued,
            progress: 0,
            downloadedBytes: 0,
            totalBytes: nil,
            errorMessage: nil,
            addedAt: .now,
            updatedAt: .now
        )

        upsert(record)
    }

    /// Season and show downloads expand into per-episode records on the SAME
    /// server the season/show was opened from; children never inherit the
    /// primary server.
    private func queueSeasonDownload(season: MediaItemID, quality: DownloadQuality) async throws {
        let profileID = media.activeProfileID
        let serverID = try downloadServerID(for: season)
        let seasonDetails = try await fetchAndCacheDetails(itemID: season.itemID, serverID: serverID)
        if let showKey = seasonDetails.parentID {
            _ = try? await fetchAndCacheDetails(itemID: showKey, serverID: serverID)
            if let seasons = try? await fetchAndCacheChildren(
                Season.self,
                itemID: showKey,
                serverID: serverID
            ) {
                await cacheArtwork(for: seasons, serverID: serverID)
            }
        }

        let episodes = try await fetchAndCacheChildren(
            Episode.self,
            itemID: season.itemID,
            serverID: serverID
        )
        .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        await cacheArtwork(for: episodes, serverID: serverID)

        for episode in episodes {
            guard profileID == media.activeProfileID, !isProfileSwitching else { throw CancellationError() }
            try await queueEpisodeDownload(episode, quality: quality)
        }
    }

    private func queueShowDownload(show: MediaItemID, quality: DownloadQuality) async throws {
        let profileID = media.activeProfileID
        let serverID = try downloadServerID(for: show)
        _ = try await fetchAndCacheDetails(itemID: show.itemID, serverID: serverID)
        let seasons = try await fetchAndCacheChildren(
            Season.self,
            itemID: show.itemID,
            serverID: serverID
        )
        .sorted { $0.index < $1.index }
        await cacheArtwork(for: seasons, serverID: serverID)

        for season in seasons {
            guard profileID == media.activeProfileID, !isProfileSwitching else { throw CancellationError() }
            try await queueSeasonDownload(
                season: MediaItemID(serverID: serverID, itemID: season.itemID),
                quality: quality
            )
        }
    }

    private func processQueueIfNeeded() {
        guard queueTask == nil else { return }
        queueTask = Task { [weak self] in
            guard let self else { return }
            await self.processQueue()
        }
    }


    private func processQueue() async {
        isProcessingQueue = true
        defer {
            isProcessingQueue = false
            queueTask = nil
        }
        processPendingQueueRemovals()
        guard media.isSessionReady,
              media.activeProfileID?.nilIfEmpty != nil,
              !isReconcilingTransfers, !isProfileSwitching, !isQueuePaused else { return }
        judgeRelaunchedTransfersIfNeeded()

        // Every queued Original download is handed to the background session
        // right away (the session runs `maximumActiveDownloads` of them at a
        // time), so the queue keeps moving while Dusk is suspended. Server
        // conversions stay limited to two at a time.
        for next in records.sorted(by: { $0.addedAt < $1.addedAt }) where next.status == .queued {
            guard preparationTasks[next.globalKey] == nil,
                  !deletingDownloadIDs.contains(next.globalKey),
                  isServerConnected(next.serverID) else { continue }
            let counts = DownloadQueuePolicy.Counts(records: records)
            guard DownloadQueuePolicy.canStart(isOriginal: next.downloadQuality == .original, counts: counts) else {
                continue
            }
            update(globalKey: next.globalKey) {
                $0.status = .preparing
                $0.errorMessage = nil
                $0.updatedAt = .now
            }
            preparationTasks[next.globalKey] = Task { [weak self] in
                guard let self else { return }
                await self.startDownload(record: next)
                self.preparationTasks.removeValue(forKey: next.globalKey)
                self.processQueueIfNeeded()
            }
        }
    }

    private func isServerConnected(_ serverID: String) -> Bool {
        media.pool.connection(for: serverID) != nil
    }

    /// Rechecked after every suspension, before changing state or handing off
    /// a file. A late response must never restart a paused/cancelled request.
    private func checkPreparation(_ record: DownloadedMediaRecord) throws {
        try Task.checkCancellation()
        guard !isProfileSwitching, !isQueuePaused,
              record.accountProfileID == media.activeProfileID,
              media.isSessionReady,
              self.record(globalKey: record.globalKey)?.status == .preparing,
              !deletingDownloadIDs.contains(record.globalKey) else { throw CancellationError() }
        guard isServerConnected(record.serverID) else { throw MediaServiceError.noServerConnected }
    }

    private func startDownload(record: DownloadedMediaRecord) async {
        do {
            try checkPreparation(record)
            let details: MediaDetails
            // Conversion needs live ordering: mediaIndex is positional, while
            // the persisted source mediaID identifies the chosen version.
            if record.downloadQuality == .original,
               let accountProfileID = record.accountProfileID,
               let cached = metadataCache.mediaDetails(accountProfileID: accountProfileID,
                                                       serverID: record.serverID, itemID: record.itemID,
                                                       kind: record.providerKind) {
                details = cached
            } else {
                details = try await fetchAndCacheDetails(itemID: record.itemID, serverID: record.serverID)
            }
            try checkPreparation(record)
            guard details.type == .movie || details.type == .episode || details.type == .clip else {
                throw MediaServiceError.decodingError("Downloads are only supported for movies, episodes, and videos.")
            }
            if details.type == .episode {
                try await cacheEpisodeContext(details, serverID: record.serverID)
                try checkPreparation(record)
            }
            let media: MediaVersion?
            if let sourceID = record.mediaID, record.downloadQuality != .original {
                media = details.media.first { $0.id == sourceID }
            } else {
                media = details.media.first(where: { $0.id == record.mediaID })
                    ?? StreamResolver.selectMediaVersion(from: details.media, preferredMaxResolution: preferences.downloadMaxResolution)
            }
            guard let media, let part = media.parts.first(where: { $0.id == record.partID }) ?? media.firstAvailablePart else {
                throw MediaServiceError.decodingError("The selected source version is no longer available. Cancel and download again to choose another version.")
            }
            update(globalKey: record.globalKey) { item in
                item.title = details.title
                item.isClip = item.isClip || details.isClip
                item.subtitle = subtitle(for: details)
                item.parentID = details.parentID
                item.grandparentID = details.grandparentID
                item.grandparentTitle = details.grandparentTitle
                item.thumbPath = details.thumb ?? details.parentThumb ?? details.grandparentThumb
                item.artPath = details.art
                item.mediaID = media.id
                item.partID = part.id
                item.updatedAt = .now
            }
            var request: URLRequest
            let transferPart: MediaPart
            if record.downloadQuality != .original {
                guard let mediaIndex = details.media.firstIndex(where: { $0.id == media.id }) else {
                    throw MediaServiceError.invalidURL
                }
                let prepared = try await prepareConvertedDownload(record: record, sourceMedia: media, mediaIndex: mediaIndex)
                try checkPreparation(record)
                guard let preparedPart = prepared.media.parts.first else { throw MediaServiceError.invalidURL }
                transferPart = preparedPart
                request = prepared.request
                let encodedMedia = try JSONEncoder().encode(prepared.media)
                update(globalKey: record.globalKey) {
                    $0.convertedMediaData = encodedMedia
                    $0.preparationProgress = 1
                    $0.totalBytes = prepared.expectedBytes
                }
                // A background transfer may outlive this process. Its output
                // metadata must be durable before URLSession takes ownership.
                try fileStore.saveSnapshot(currentSnapshot)
            } else {
                guard let original = self.media.originalDownloadRequest(for: part, serverID: record.serverID) else {
                    throw MediaServiceError.invalidURL
                }
                request = original
                transferPart = part
            }
            try checkPreparation(record)
            guard let latest = self.record(globalKey: record.globalKey), let profileID = record.accountProfileID else {
                throw CancellationError()
            }
            _ = try fileStore.targetVideoURL(accountProfileID: profileID, for: details, part: transferPart)
            try validateAvailableStorage(for: transferPart, globalKey: record.globalKey)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.allowsExpensiveNetworkAccess = !preferences.downloadsWifiOnly
            request.allowsConstrainedNetworkAccess = !preferences.downloadsWifiOnly
            let resumeData = fileStore.resumeData(relativePath: latest.resumeDataPath)
            transferBytesReceivedKeys.remove(record.globalKey)
            let taskIdentifier = try transferController.start(
                request: request,
                resumeData: resumeData,
                globalKey: record.globalKey,
                live: usesLiveTransfers,
                priority: transferPriority(for: record.globalKey)
            )
            if resumeData != nil { fileStore.deleteResumeData(relativePath: latest.resumeDataPath) }
            update(globalKey: record.globalKey) {
                $0.status = .downloading
                $0.downloadTaskIdentifier = taskIdentifier
                $0.resumeDataPath = nil
                $0.totalBytes = transferPart.size.map(Int64.init)
                $0.updatedAt = .now
            }
        } catch {
            // Pause/profile switch owns its state; leave it untouched even if
            // URLSession reports cancellation as a generic network error.
            guard let latest = self.record(globalKey: record.globalKey), latest.status == .preparing,
                  !deletingDownloadIDs.contains(record.globalKey) else { return }
            // Still preparing means nothing else claimed the record: requeue it
            // (keeping any Plex queue IDs) so it continues once the session or
            // its offline/switched-off server is back, instead of staying stuck.
            if error is CancellationError || Task.isCancelled || isProfileSwitching
                || record.accountProfileID != media.activeProfileID
                || !isServerConnected(record.serverID) {
                update(globalKey: record.globalKey) {
                    $0.status = .queued
                    $0.downloadTaskIdentifier = nil
                    $0.updatedAt = .now
                }
                return
            }
            ErrorReporter.report(.downloadFailed, reason: .prepare, error: error)
            update(globalKey: record.globalKey) {
                $0.status = .failed
                $0.downloadTaskIdentifier = nil
                $0.errorMessage = downloadErrorMessage(for: error)
                $0.updatedAt = .now
            }
        }
    }

    private func prepareConvertedDownload(
        record: DownloadedMediaRecord, sourceMedia: MediaVersion, mediaIndex: Int
    ) async throws -> ConvertedDownload {
        guard let profileID = record.accountProfileID else { throw MediaServiceError.notAuthenticated }
        try checkPreparation(record)
        guard var latest = self.record(globalKey: record.globalKey) else { throw CancellationError() }
        if latest.queueClientIdentifier == nil {
            latest.queueClientIdentifier = UUID().uuidString
            upsert(latest)
        }
        // Retry this checked write even if a previous persistence attempt
        // failed after assigning the in-memory identity.
        try fileStore.saveSnapshot(currentSnapshot)
        let context = try media.captureConversionContext(
            serverID: record.serverID, profileID: profileID, clientIdentifier: latest.queueClientIdentifier!
        )
        do {
            let queueID: String
            if let existing = latest.plexDownloadQueueID {
                queueID = existing
            } else {
                queueID = try await media.createConversionQueue(context: context)
                update(globalKey: record.globalKey) { $0.plexDownloadQueueID = queueID }
                try checkPreparation(record)
            }
            try fileStore.saveSnapshot(currentSnapshot)
            let queueItemID: String
            if let existing = latest.plexDownloadItemID {
                queueItemID = existing
            } else {
                queueItemID = try await media.addConversionJob(
                    context: context, queueID: queueID, itemID: record.itemID,
                    mediaIndex: mediaIndex, quality: record.downloadQuality
                )
                // Save a late add even after a pause. If cancelled, remember
                // cleanup independently of the deleted download record.
                if self.record(globalKey: record.globalKey) == nil || deletingDownloadIDs.contains(record.globalKey) {
                    enqueueQueueRemoval(DownloadQueueRemoval(profileID: profileID, serverID: record.serverID,
                        clientIdentifier: latest.queueClientIdentifier!, itemID: record.itemID, queueID: queueID, queueItemID: queueItemID))
                } else {
                    update(globalKey: record.globalKey) { $0.plexDownloadItemID = queueItemID }
                }
                try checkPreparation(record)
            }
            var failedPolls = 0
            while true {
                try checkPreparation(record)
                // Conversion can outlive a LAN/remote endpoint change or token
                // refresh. Capture the current connection for each poll, while
                // keeping the durable client and owning profile unchanged.
                let pollContext = try media.captureConversionContext(
                    serverID: record.serverID, profileID: profileID, clientIdentifier: latest.queueClientIdentifier!
                )
                let job: ConversionJob
                do {
                    job = try await media.conversionJob(context: pollContext, queueID: queueID, jobID: queueItemID)
                    failedPolls = 0
                } catch MediaServiceError.networkError where failedPolls < 10 {
                    // A poll dropped by a network blip or app suspension must not
                    // fail the download; a retry would restart the conversion.
                    failedPolls += 1
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                try checkPreparation(record)
                guard job.itemID == record.itemID else {
                    throw DownloadPreparationError.invalidResponse("Plex returned a different item for this download.")
                }
                update(globalKey: record.globalKey) { $0.preparationProgress = job.progress }
                switch job.state {
                case .ready:
                    // Hand off right away: the session's connection limit
                    // queues it behind running transfers. If the prepared file
                    // expires before the session gets to it, the transfer
                    // fails without bytes and is requeued once, which
                    // regenerates it here.
                    if DownloadQueuePolicy.Counts(records: records).handedOff < DownloadQueuePolicy.maximumHandedOffTransfers {
                        let prepared = try await media.preparedConversion(
                            context: pollContext, queueID: queueID, jobID: queueItemID, sourceMedia: sourceMedia
                        )
                        try checkPreparation(record)
                        return prepared
                    }
                case .expired:
                    throw DownloadPreparationError.expired
                case .failed:
                    throw DownloadPreparationError.preparationFailed(job.failureReason ?? "Plex could not prepare this quality. Try Original or check server transcoding permissions.")
                case .preparing:
                    break
                }
                try await Task.sleep(for: .seconds(2))
            }
        } catch DownloadPreparationError.expired {
            try checkPreparation(record)
            guard resetExpiredPreparation(globalKey: record.globalKey) else { throw DownloadPreparationError.expired }
            // Re-enter through startDownload to resolve the saved media ID
            // against fresh ordering before adding another server job.
            update(globalKey: record.globalKey) { $0.status = .queued }
            throw CancellationError()
        }
    }

    /// Bounded recovery also applies when a prepared file expires during a
    /// paused/background transfer. Source identity and selected quality survive.
    @discardableResult
    private func resetExpiredPreparation(globalKey: String) -> Bool {
        guard let record = record(globalKey: globalKey), record.downloadQuality != .original,
              record.preparationRetryCount < 2 else { return false }
        enqueueQueueRemoval(for: record)
        fileStore.deleteResumeData(relativePath: record.resumeDataPath)
        update(globalKey: globalKey) {
            $0.queueClientIdentifier = nil
            $0.plexDownloadQueueID = nil
            $0.plexDownloadItemID = nil
            $0.convertedMediaData = nil
            $0.preparationProgress = nil
            $0.preparationRetryCount += 1
            $0.resumeDataPath = nil
            $0.downloadTaskIdentifier = nil
            $0.progress = 0
            $0.downloadedBytes = 0
            $0.totalBytes = nil
        }
        return true
    }

    private func enqueueQueueRemoval(for record: DownloadedMediaRecord) {
        guard let profileID = record.accountProfileID, let clientID = record.queueClientIdentifier else { return }
        enqueueQueueRemoval(DownloadQueueRemoval(profileID: profileID, serverID: record.serverID,
            clientIdentifier: clientID, itemID: record.itemID,
            queueID: record.plexDownloadQueueID, queueItemID: record.plexDownloadItemID))
    }

    private func enqueueQueueRemoval(_ removal: DownloadQueueRemoval) {
        if !pendingQueueRemovals.contains(removal) {
            pendingQueueRemovals.append(removal)
            persist()
        }
        processPendingQueueRemovals()
    }

    private func processPendingQueueRemovals() {
        guard cleanupTask == nil, !isProfileSwitching else { return }
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            let batch = self.pendingQueueRemovals
            defer {
                self.cleanupTask = nil
                // Process newly appended entries without spinning on failures.
                if self.pendingQueueRemovals.contains(where: { !batch.contains($0) }) {
                    self.processPendingQueueRemovals()
                }
            }
            for removal in batch {
                let globalKey = DownloadedMediaRecord.globalKey(accountProfileID: removal.profileID,
                    serverID: removal.serverID, itemID: removal.itemID)
                guard self.preparationTasks[globalKey] == nil,
                      removal.profileID == self.media.activeProfileID,
                      let context = try? self.media.captureConversionContext(
                        serverID: removal.serverID, profileID: removal.profileID, clientIdentifier: removal.clientIdentifier
                      ) else { continue }
                do {
                    let queueID: String
                    if let existing = removal.queueID { queueID = existing }
                    else { queueID = try await self.media.createConversionQueue(context: context) }
                    if let queueItemID = removal.queueItemID {
                        try await self.media.removeConversionJob(context: context, queueID: queueID, jobID: queueItemID)
                    } else {
                        // Covers cancellation/termination after the server
                        // accepted add but before its response could be persisted.
                        let jobs = try await self.media.conversionJobs(context: context, queueID: queueID)
                        for job in jobs where job.itemID == removal.itemID {
                            try await self.media.removeConversionJob(context: context, queueID: queueID, jobID: job.id)
                        }
                    }
                    self.pendingQueueRemovals.removeAll { $0 == removal }
                    self.persist()
                } catch DownloadPreparationError.expired {
                    self.pendingQueueRemovals.removeAll { $0 == removal }
                    self.persist()
                } catch {
                    // Retry only under the owning profile when it reconnects.
                }
            }
        }
    }

    private func completeDownload(
        globalKey: String,
        taskIdentifier: Int,
        temporaryURL: URL,
        response: DownloadTransferResponse?
    ) async {
        guard let record = record(globalKey: globalKey),
              record.downloadTaskIdentifier == taskIdentifier,
              !deletingDownloadIDs.contains(globalKey),
              record.status == .downloading || record.status == .paused else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }

        if record.downloadQuality != .original,
           let status = response?.statusCode, [404, 410].contains(status),
           resetExpiredPreparation(globalKey: globalKey) {
            try? FileManager.default.removeItem(at: temporaryURL)
            update(globalKey: globalKey) { $0.status = record.status == .paused ? .paused : .queued }
            processQueueIfNeeded()
            return
        }

        do {
            guard let accountProfileID = record.accountProfileID,
                  let details = metadataCache.mediaDetails(
                    accountProfileID: accountProfileID,
                    serverID: record.serverID,
                    itemID: record.itemID,
                    kind: record.providerKind
                  ) else {
                throw MediaServiceError.decodingError("Cached metadata missing for \(record.title)")
            }

            let media = record.downloadQuality != .original ? record.convertedMedia
                : (details.media.first(where: { $0.id == record.mediaID })
                    ?? StreamResolver.selectMediaVersion(from: details.media, preferredMaxResolution: preferences.downloadMaxResolution))
            guard let media,
                  let part = media.parts.first(where: { $0.id == record.partID }) ?? media.parts.first else {
                throw MediaServiceError.decodingError("Cached media part missing for \(record.title)")
            }

            let targetURL = try fileStore.targetVideoURL(
                accountProfileID: accountProfileID,
                for: details,
                part: part
            )
            try validateDownloadedFile(
                at: temporaryURL,
                response: response,
                expectedSize: part.size.map(Int64.init)
            )
            try? FileManager.default.removeItem(at: targetURL)
            try FileManager.default.moveItem(at: temporaryURL, to: targetURL)
            fileStore.deleteResumeData(relativePath: record.resumeDataPath)
            update(globalKey: globalKey) { item in
                item.status = .completed
                item.wasPausedForProfileSwitch = false
                item.progress = 1
                item.downloadedBytes = item.totalBytes ?? item.downloadedBytes
                item.relativeVideoPath = fileStore.relativePath(for: targetURL)
                item.resumeDataPath = nil
                item.downloadTaskIdentifier = nil
                // Keep original media/part identity for version selection.
                item.errorMessage = nil
                item.updatedAt = .now
            }
            enqueueQueueRemoval(for: record)
            update(globalKey: globalKey) {
                $0.plexDownloadQueueID = nil
                $0.plexDownloadItemID = nil
                $0.queueClientIdentifier = nil
            }
            if record.accountProfileID == self.media.activeProfileID, self.media.isSessionReady {
                await cacheArtwork(for: details, serverID: record.serverID)
                await cacheExternalSubtitles(globalKey: globalKey, details: details)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            ErrorReporter.report(.downloadFailed, reason: .finalize, error: error)
            update(globalKey: globalKey) { item in
                item.status = .failed
                item.wasPausedForProfileSwitch = false
                item.downloadTaskIdentifier = nil
                item.errorMessage = downloadErrorMessage(for: error)
                item.updatedAt = .now
            }
        }

        lastProgressPersistDates.removeValue(forKey: globalKey)
        processQueueIfNeeded()
    }

    private func fetchAndCacheDetails(
        itemID: String,
        serverID: String
    ) async throws -> MediaDetails {
        guard !isProfileSwitching,
              let accountProfileID = media.activeProfileID?.nilIfEmpty else {
            throw MediaServiceError.noServerConnected
        }

        let kind = snapshotKind(for: serverID)
        let data = try await media.metadataSnapshot(.details(itemID: itemID), serverID: serverID)
        guard !Task.isCancelled,
              !isProfileSwitching,
              media.activeProfileID == accountProfileID else {
            throw CancellationError()
        }
        try metadataCache.storePayload(
            data,
            for: .details(itemID: itemID),
            accountProfileID: accountProfileID,
            serverID: serverID,
            kind: kind
        )
        let decoded = try decodeSnapshot(data, serverID: serverID, kind: kind) { try $0.details(from: data, serverID: serverID) }
        guard let details = decoded.first else {
            throw MediaServiceError.decodingError("No metadata found for \(itemID)")
        }
        await cacheArtwork(for: details, serverID: serverID)
        return details
    }

    @discardableResult
    private func fetchAndCacheChildren(itemID: String, serverID: String) async throws -> Data {
        guard !isProfileSwitching,
              let accountProfileID = media.activeProfileID?.nilIfEmpty else {
            throw MediaServiceError.noServerConnected
        }

        let data = try await media.metadataSnapshot(.children(itemID: itemID), serverID: serverID)
        guard !Task.isCancelled,
              !isProfileSwitching,
              media.activeProfileID == accountProfileID else {
            throw CancellationError()
        }
        try metadataCache.storePayload(
            data,
            for: .children(itemID: itemID),
            accountProfileID: accountProfileID,
            serverID: serverID,
            kind: snapshotKind(for: serverID)
        )
        return data
    }

    private func fetchAndCacheChildren(
        _ type: Season.Type,
        itemID: String,
        serverID: String
    ) async throws -> [Season] {
        let data = try await fetchAndCacheChildren(itemID: itemID, serverID: serverID)
        return try decodeSnapshot(data, serverID: serverID, kind: snapshotKind(for: serverID)) {
            try $0.seasons(from: data, serverID: serverID)
        }
    }

    private func fetchAndCacheChildren(
        _ type: Episode.Type,
        itemID: String,
        serverID: String
    ) async throws -> [Episode] {
        let data = try await fetchAndCacheChildren(itemID: itemID, serverID: serverID)
        return try decodeSnapshot(data, serverID: serverID, kind: snapshotKind(for: serverID)) {
            try $0.episodes(from: data, serverID: serverID)
        }
    }

    /// Decodes a just-fetched snapshot with its provider's format. A failure
    /// reads exactly as the online decode's (`MediaServiceError.decodingError`).
    private func decodeSnapshot<T>(
        _ data: Data,
        serverID: String,
        kind: ProviderKind,
        _ decode: (any MetadataSnapshotFormat) throws -> [T]
    ) throws -> [T] {
        guard let format = metadataCache.formats.format(for: kind) else {
            throw MediaServiceError.decodingError("No metadata format for this server")
        }
        do {
            return try decode(format)
        } catch {
            throw MediaServiceError.decodingError(String(describing: error))
        }
    }

    /// Which provider's snapshot format reads a server's cached metadata: its
    /// live session's, else a stored record's, else Plex (a server with no
    /// record is Plex).
    private func snapshotKind(for serverID: String) -> ProviderKind {
        if media.pool.connection(for: serverID) != nil {
            return media.downloadProviderKind(for: serverID)
        }
        return storedRecords.first { $0.serverID == serverID }?.providerKind ?? .plex
    }

    /// The `provider` tag a new record on this server stores (none for Plex).
    private func providerTag(for serverID: String) -> ProviderKind? {
        DownloadedMediaRecord.providerTag(for: snapshotKind(for: serverID))
    }

    private func cacheEpisodeContext(_ details: MediaDetails, serverID: String) async throws {
        if let seasonKey = details.parentID {
            _ = try? await fetchAndCacheDetails(itemID: seasonKey, serverID: serverID)
            if let episodes = try? await fetchAndCacheChildren(
                Episode.self,
                itemID: seasonKey,
                serverID: serverID
            ) {
                await cacheArtwork(for: episodes, serverID: serverID)
            }
        }

        if let showKey = details.grandparentID {
            _ = try? await fetchAndCacheDetails(itemID: showKey, serverID: serverID)
            if let seasons = try? await fetchAndCacheChildren(
                Season.self,
                itemID: showKey,
                serverID: serverID
            ) {
                await cacheArtwork(for: seasons, serverID: serverID)
            }
        }
    }

    private func cacheArtwork(for details: MediaDetails, serverID: String) async {
        let expectedProfileID = media.activeProfileID
        // A clip's thumb and art are 16:9 frame grabs; requesting the poster
        // box would crop them server-side before they ever reach the cache.
        if details.isClip {
            await cacheArtwork(
                paths: [details.thumb, details.art].compactMap { $0 },
                serverID: serverID,
                width: 1280,
                height: 720,
                expectedProfileID: expectedProfileID
            )
            return
        }

        var paths = [
            details.thumb,
            details.art,
            details.clearLogo,
            details.parentThumb,
            details.grandparentThumb,
        ]

        if let roles = details.roles {
            paths.append(contentsOf: roles.map(\.thumb))
        }

        await cacheArtwork(
            paths: paths.compactMap { $0 },
            serverID: serverID,
            expectedProfileID: expectedProfileID
        )
    }

    private func cacheArtwork(for seasons: [Season], serverID: String) async {
        let expectedProfileID = media.activeProfileID
        await cacheArtwork(paths: seasons.flatMap { season in
            [
                season.thumb,
                season.art,
                season.parentThumb,
            ].compactMap { $0 }
        }, serverID: serverID, expectedProfileID: expectedProfileID)
    }

    private func cacheArtwork(for episodes: [Episode], serverID: String) async {
        let expectedProfileID = media.activeProfileID
        await cacheArtwork(paths: episodes.flatMap { episode in
            [
                episode.thumb,
                episode.art,
                episode.grandparentThumb,
            ].compactMap { $0 }
        }, serverID: serverID, expectedProfileID: expectedProfileID)
    }

    private func cacheArtwork(
        paths: [String],
        serverID: String,
        width: Int = 900,
        height: Int = 1350,
        expectedProfileID: String?
    ) async {
        for path in Set(paths) {
            guard !isProfileSwitching,
                  media.activeProfileID == expectedProfileID,
                  let targetURL = fileStore.artworkURL(for: path),
                  !FileManager.default.fileExists(atPath: targetURL.path),
                  let sourceURL = media.imageURL(
                      for: ArtworkRef(serverID: serverID, path: path),
                      size: ImageSize(width: width, height: height)
                  ) else {
                continue
            }

            do {
                let data = try await media.imageData(for: sourceURL)
                guard !isProfileSwitching,
                      media.activeProfileID == expectedProfileID else {
                    return
                }
                try FileManager.default.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: targetURL, options: [.atomic])
            } catch {
                continue
            }
        }
    }

    /// The original file's part. Converted downloads still use it: the external
    /// subtitles belong to the source, not to the prepared MKV.
    private func sourcePart(for record: DownloadedMediaRecord, in details: MediaDetails) -> MediaPart? {
        details.media.first { $0.id == record.mediaID }?.parts.first { $0.id == record.partID }
    }

    /// Completed downloads whose external subtitles were never saved (made
    /// before Dusk saved them) or partly failed get them once their server
    /// is reachable. Only text sidecars are saved; see `offlineSubtitleStreams`.
    private func backfillExternalSubtitles(serverIDs: Set<String>) {
        guard !isProfileSwitching, media.isSessionReady,
              let activeProfileID = media.activeProfileID else { return }
        let pending = storedRecords.filter {
            $0.status == .completed && ($0.externalSubtitlePaths == nil || $0.hasMissingExternalSubtitles)
                && $0.accountProfileID == activeProfileID && serverIDs.contains($0.serverID)
                && !subtitleBackfillAttemptedKeys.contains($0.globalKey)
        }
        guard !pending.isEmpty else { return }
        subtitleBackfillAttemptedKeys.formUnion(pending.map(\.globalKey))
        Task { [weak self] in
            for record in pending {
                guard let self, let details = self.metadataCache.mediaDetails(
                    accountProfileID: activeProfileID,
                    serverID: record.serverID,
                    itemID: record.itemID,
                    kind: record.providerKind
                ) else { continue }
                await self.cacheExternalSubtitles(globalKey: record.globalKey, details: details)
            }
        }
    }

    /// Saves the source part's external text subtitles, normalized to UTF-8,
    /// next to a completed download. Best effort: a failed sidecar never fails
    /// the download, it only marks the record for the next backfill.
    private func cacheExternalSubtitles(globalKey: String, details: MediaDetails) async {
        guard let record = record(globalKey: globalKey), record.status == .completed,
              !subtitleCachingKeys.contains(globalKey) else { return }
        subtitleCachingKeys.insert(globalKey)
        defer { subtitleCachingKeys.remove(globalKey) }

        let expectedProfileID = record.accountProfileID
        var paths = record.externalSubtitlePaths ?? [:]
        var failed = false
        for stream in DownloadedMediaRecord.offlineSubtitleStreams(in: sourcePart(for: record, in: details))
        where fileStore.existingFileURL(for: paths[stream.id]) == nil {
            guard !isProfileSwitching, media.activeProfileID == expectedProfileID,
                  let fileExtension = SubtitleTextDecoder.fileExtension(for: stream.codec),
                  var sidecar = media.offlineSidecar(for: stream, serverID: record.serverID) else {
                failed = true
                continue
            }
            sidecar.request.timeoutInterval = 30
            sidecar.request.allowsExpensiveNetworkAccess = !preferences.downloadsWifiOnly
            sidecar.request.allowsConstrainedNetworkAccess = !preferences.downloadsWifiOnly
            do {
                let (data, response) = try await sidecar.fetch(sidecar.request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let normalized = SubtitleTextDecoder.normalizedFileData(data) else {
                    failed = true
                    continue
                }
                guard self.record(globalKey: globalKey)?.status == .completed,
                      !deletingDownloadIDs.contains(globalKey) else { return }
                paths[stream.id] = try fileStore.saveSubtitle(
                    normalized, globalKey: globalKey, streamID: stream.id, fileExtension: fileExtension
                )
            } catch {
                // Never log the error: URLSession errors can include server tokens.
                failed = true
            }
        }

        guard self.record(globalKey: globalKey)?.status == .completed,
              !deletingDownloadIDs.contains(globalKey) else { return }
        let savedPaths = paths
        update(globalKey: globalKey) { item in
            item.externalSubtitlePaths = savedPaths
            item.hasMissingExternalSubtitles = failed
            item.updatedAt = .now
        }
    }

    private func validateAvailableStorage(for part: MediaPart, globalKey: String) throws {
        let expectedSize = max(0, part.size.map(Int64.init) ?? 0)
        guard let availableBytes = fileStore.availableStorageBytes() else {
            return
        }

        let reserveBytes = preferences.downloadFreeSpaceReserve.bytes
        // Handed-off transfers (possibly many, all at once) have not written
        // their files yet; count what they still need.
        let otherPendingBytes = storedRecords
            .filter { $0.status == .downloading && $0.globalKey != globalKey }
            .reduce(Int64(0)) { $0 + remainingBytes(for: $1) }
        if !DownloadQueuePolicy.hasRoom(
            availableBytes: availableBytes,
            expectedBytes: expectedSize,
            reserveBytes: reserveBytes,
            otherPendingBytes: otherPendingBytes
        ) {
            throw DownloadManagerError.insufficientStorage(
                requiredBytes: expectedSize,
                availableBytes: availableBytes,
                reserveBytes: reserveBytes
            )
        }
    }

    private func validateDownloadedFile(
        at url: URL,
        response: DownloadTransferResponse?,
        expectedSize: Int64?
    ) throws {
        if let statusCode = response?.statusCode,
           !(200...299).contains(statusCode) {
            throw DownloadManagerError.invalidDownloadStatus(statusCode: statusCode)
        }

        if let mimeType = response?.mimeType?.lowercased(),
           isRejectedDownloadContentType(mimeType) {
            throw DownloadManagerError.invalidDownloadContentType(mimeType)
        }

        let responseExpectedSize = response?.expectedContentLength ?? -1
        let effectiveExpectedSize = expectedSize ?? (responseExpectedSize > 0 ? responseExpectedSize : nil)
        try validateDownloadedFileContents(at: url, expectedSize: effectiveExpectedSize)
    }

    private func validateDownloadedFileContents(at url: URL, expectedSize: Int64?) throws {
        let actualSize = try downloadedFileSize(at: url)
        guard actualSize > 0 else {
            throw DownloadManagerError.emptyDownloadedFile
        }

        if let expectedSize,
           expectedSize > 0,
           actualSize < expectedSize {
            throw DownloadManagerError.incompleteDownloadedFile(
                expectedBytes: expectedSize,
                actualBytes: actualSize
            )
        }

        if looksLikeServerErrorPayload(at: url, size: actualSize) {
            throw DownloadManagerError.unexpectedDownloadedPayload
        }
    }

    private func isRejectedDownloadContentType(_ mimeType: String) -> Bool {
        if mimeType.hasPrefix("text/") {
            return true
        }

        return [
            "application/json",
            "application/problem+json",
            "application/xml",
            "application/xhtml+xml",
        ].contains(mimeType)
    }

    private func downloadedFileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func looksLikeServerErrorPayload(at url: URL, size: Int64) -> Bool {
        guard size <= 1_048_576,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer {
            try? handle.close()
        }

        guard let data = try? handle.read(upToCount: 512),
              let prefix = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              !prefix.isEmpty else {
            return false
        }

        return prefix.hasPrefix("<!doctype html")
            || prefix.hasPrefix("<html")
            || prefix.hasPrefix("<?xml")
            || prefix.hasPrefix("{")
            || prefix.hasPrefix("[")
    }

    private func subtitle(for details: MediaDetails) -> String? {
        if details.isClip {
            return MediaTextFormatter.clipCardSubtitle(
                originallyAvailableAt: details.originallyAvailableAt,
                duration: details.duration,
                fallbackYear: details.year
            )
        }

        switch details.type {
        case .episode:
            return MediaTextFormatter.seasonEpisodeLabel(
                season: details.parentIndex,
                episode: details.index
            )
        case .movie:
            return MediaTextFormatter.joinedWithEdition(details.year.map(String.init), edition: details.editionTitle)
        default:
            return nil
        }
    }

    private func relatedRecords(for scope: DownloadScope) -> [DownloadedMediaRecord] {
        let ownRecords = records.filter {
            $0.itemID == scope.itemID && matchesServer($0, of: scope.id)
        }
        switch scope.type {
        case .season:
            let episodeRecords = records.filter {
                $0.type == .episode && matchesSeason($0, of: scope.id)
            }
            return episodeRecords.isEmpty ? ownRecords : episodeRecords
        case .show:
            let episodeRecords = records.filter {
                $0.type == .episode && matchesBranch($0, of: scope.id)
            }
            return episodeRecords.isEmpty ? ownRecords : episodeRecords
        default:
            return ownRecords
        }
    }

    private func performOnRelatedRecords(_ scope: DownloadScope, action: (DownloadedMediaRecord) -> Void) {
        let related = relatedRecords(for: scope)
        for record in related {
            action(record)
        }
    }

    private func aggregateStatus(for records: [DownloadedMediaRecord]) -> DownloadStatus? {
        guard !records.isEmpty else { return nil }

        if records.contains(where: { $0.status == .downloading }) { return .downloading }
        if records.contains(where: { $0.status == .preparing }) { return .preparing }
        if records.contains(where: { $0.status == .queued }) { return .queued }
        if records.contains(where: { $0.status == .paused }) { return .paused }
        if records.contains(where: { $0.status == .failed }) { return .failed }
        if records.allSatisfy({ $0.status == .completed }) { return .completed }
        if records.contains(where: { $0.status == .cancelled }) { return .cancelled }

        return records.first?.status
    }

    private func aggregateProgress(for records: [DownloadedMediaRecord]) -> Double? {
        guard !records.isEmpty else { return nil }

        let totalBytes = records.compactMap(\.totalBytes).reduce(Int64(0), +)
        if totalBytes > 0 {
            let downloadedBytes = records.reduce(Int64(0)) { $0 + $1.downloadedBytes }
            return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
        }

        let totalProgress = records.reduce(0) { $0 + $1.progress }
        return min(max(totalProgress / Double(records.count), 0), 1)
    }

    private func upsert(_ record: DownloadedMediaRecord) {
        if let index = storedRecords.firstIndex(where: { $0.globalKey == record.globalKey }) {
            storedRecords[index] = record
        } else {
            storedRecords.append(record)
        }
        persist()
    }

    private func record(globalKey: String) -> DownloadedMediaRecord? {
        storedRecords.first { $0.globalKey == globalKey }
    }

    private func update(globalKey: String, persist shouldPersist: Bool = true, mutate: (inout DownloadedMediaRecord) -> Void) {
        guard let index = storedRecords.firstIndex(where: { $0.globalKey == globalKey }) else {
            return
        }
        mutate(&storedRecords[index])
        if shouldPersist {
            persist()
        }
    }

    private func handleTransferEvent(_ event: DownloadTransferEvent) {
        switch event {
        case let .progress(taskIdentifier, globalKey, progress, downloadedBytes, totalBytes):
            guard let globalKey = resolvedGlobalKey(globalKey, taskIdentifier: taskIdentifier) else { return }
            guard !deletingDownloadIDs.contains(globalKey) else { return }
            if downloadedBytes > 0, !transferBytesReceivedKeys.contains(globalKey) {
                transferBytesReceivedKeys.insert(globalKey)
                requeuedAfterFailureKeys.remove(globalKey)
            }
            updateSpeedEstimate(globalKey: globalKey, downloadedBytes: downloadedBytes)
            update(globalKey: globalKey, persist: shouldPersistProgress(globalKey: globalKey, progress: progress)) { item in
                guard item.status != .paused && item.status != .cancelled else { return }
                item.status = .downloading
                item.downloadTaskIdentifier = taskIdentifier
                item.progress = progress
                item.downloadedBytes = downloadedBytes
                item.totalBytes = totalBytes > 0 ? totalBytes : item.totalBytes
                item.updatedAt = .now
            }
        case let .paused(taskIdentifier, globalKey, resumeData):
            guard let globalKey = resolvedGlobalKey(globalKey, taskIdentifier: taskIdentifier) else {
                finishProfileSuspension(taskIdentifier: taskIdentifier)
                return
            }
            guard !deletingDownloadIDs.contains(globalKey) else {
                finishProfileSuspension(taskIdentifier: taskIdentifier)
                return
            }
            let resumeDataPath = resumeData.flatMap { try? fileStore.saveResumeData($0, globalKey: globalKey) }
            let isRestart = restartingTransferKeys.remove(globalKey) != nil
            transferBytesReceivedKeys.remove(globalKey)
            update(globalKey: globalKey) { item in
                item.status = isRestart && item.status == .paused ? .queued : .paused
                item.resumeDataPath = resumeDataPath ?? item.resumeDataPath
                item.downloadTaskIdentifier = nil
                item.errorMessage = resumeDataPath == nil && resumeData != nil
                    ? "Could not save pause data. Resume will restart this download."
                    : nil
                item.updatedAt = .now
            }
            lastProgressPersistDates.removeValue(forKey: globalKey)
            speedEstimates.removeValue(forKey: globalKey)
            finishProfileSuspension(taskIdentifier: taskIdentifier)
            processQueueIfNeeded()
        case let .cancelled(taskIdentifier, globalKey):
            guard let globalKey = resolvedGlobalKey(globalKey, taskIdentifier: taskIdentifier) else {
                finishProfileSuspension(taskIdentifier: taskIdentifier)
                return
            }
            guard !deletingDownloadIDs.contains(globalKey) else {
                finishProfileSuspension(taskIdentifier: taskIdentifier)
                return
            }
            update(globalKey: globalKey) { item in
                item.status = .cancelled
                item.resumeDataPath = nil
                item.downloadTaskIdentifier = nil
                item.errorMessage = nil
                item.updatedAt = .now
            }
            lastProgressPersistDates.removeValue(forKey: globalKey)
            speedEstimates.removeValue(forKey: globalKey)
            finishProfileSuspension(taskIdentifier: taskIdentifier)
            processQueueIfNeeded()
        case let .finished(taskIdentifier, globalKey, temporaryURL, response):
            guard let globalKey = resolvedGlobalKey(globalKey, taskIdentifier: taskIdentifier) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                finishProfileSuspension(taskIdentifier: taskIdentifier)
                return
            }
            guard !deletingDownloadIDs.contains(globalKey) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                finishProfileSuspension(taskIdentifier: taskIdentifier)
                return
            }
            transferBytesReceivedKeys.remove(globalKey)
            pendingCompletionCount += 1
            Task {
                await completeDownload(
                    globalKey: globalKey,
                    taskIdentifier: taskIdentifier,
                    temporaryURL: temporaryURL,
                    response: response
                )
                pendingCompletionCount -= 1
                finishProfileSuspension(taskIdentifier: taskIdentifier)
            }
        case let .backgroundEventsFinished(sessionIdentifier):
            completeBackgroundEventsWhenSettled(sessionIdentifier: sessionIdentifier)
        case let .failed(taskIdentifier, globalKey, error):
            guard let globalKey = resolvedGlobalKey(globalKey, taskIdentifier: taskIdentifier) else {
                finishProfileSuspension(taskIdentifier: taskIdentifier)
                return
            }
            guard !deletingDownloadIDs.contains(globalKey) else {
                finishProfileSuspension(taskIdentifier: taskIdentifier)
                return
            }
            if record(globalKey: globalKey)?.status == .paused {
                finishProfileSuspension(taskIdentifier: taskIdentifier)
                return
            }
            let receivedBytes = transferBytesReceivedKeys.remove(globalKey) != nil
            if record(globalKey: globalKey)?.status == .downloading,
               DownloadQueuePolicy.shouldRequeueAfterFailure(
                   receivedBytes: receivedBytes,
                   alreadyRequeued: requeuedAfterFailureKeys.contains(globalKey),
                   error: error
               ) {
                requeuedAfterFailureKeys.insert(globalKey)
                update(globalKey: globalKey) { item in
                    item.status = .queued
                    item.downloadTaskIdentifier = nil
                    item.updatedAt = .now
                }
                speedEstimates.removeValue(forKey: globalKey)
                finishProfileSuspension(taskIdentifier: taskIdentifier)
                processQueueIfNeeded()
                return
            }
            if let status = record(globalKey: globalKey)?.status, status != .completed, status != .cancelled {
                ErrorReporter.report(.downloadFailed, reason: .transfer, error: error)
            }
            update(globalKey: globalKey) { item in
                guard item.status != .completed && item.status != .cancelled else { return }
                item.status = .failed
                item.wasPausedForProfileSwitch = false
                item.downloadTaskIdentifier = nil
                item.errorMessage = downloadErrorMessage(for: error)
                item.updatedAt = .now
            }
            lastProgressPersistDates.removeValue(forKey: globalKey)
            speedEstimates.removeValue(forKey: globalKey)
            finishProfileSuspension(taskIdentifier: taskIdentifier)
            processQueueIfNeeded()
        }
    }

    private func finishProfileSuspension(taskIdentifier: Int) {
        pendingProfileSuspensionTaskIDs.remove(taskIdentifier)
        completeDeferredProfileActivationIfPossible()
    }

    private func remainingBytes(for record: DownloadedMediaRecord) -> Int64 {
        guard let totalBytes = record.totalBytes, totalBytes > 0 else { return 0 }
        return max(totalBytes - record.downloadedBytes, 0)
    }

    private func estimatedTimeRemaining(globalKey: String, remainingBytes: Int64) -> TimeInterval? {
        guard remainingBytes > 0,
              let bytesPerSecond = speedEstimates[globalKey]?.bytesPerSecond,
              bytesPerSecond > 0 else {
            return nil
        }
        return TimeInterval(Double(remainingBytes) / bytesPerSecond)
    }

    private func updateSpeedEstimate(globalKey: String, downloadedBytes: Int64) {
        speedEstimates[globalKey, default: SmoothedDownloadSpeed()]
            .update(downloadedBytes: downloadedBytes)
    }

    private func shouldPersistProgress(globalKey: String, progress: Double) -> Bool {
        if progress >= 1 {
            lastProgressPersistDates[globalKey] = .now
            return true
        }

        let now = Date()
        if let lastPersistDate = lastProgressPersistDates[globalKey],
           now.timeIntervalSince(lastPersistDate) < Self.progressPersistInterval {
            return false
        }

        lastProgressPersistDates[globalKey] = now
        return true
    }

    private func resolvedGlobalKey(_ globalKey: String?, taskIdentifier: Int) -> String? {
        if let globalKey,
           let record = storedRecords.first(where: { $0.globalKey == globalKey }) {
            return record.downloadTaskIdentifier == taskIdentifier ? record.globalKey : nil
        }
        if let record = storedRecords.first(where: { $0.downloadTaskIdentifier == taskIdentifier }) {
            return record.globalKey
        }
        if let globalKey {
            let legacyMatches = storedRecords.filter {
                $0.legacyGlobalKey == globalKey
                    && ($0.status == .preparing || $0.status == .downloading || $0.status == .paused)
            }
            if legacyMatches.count == 1 {
                return legacyMatches[0].globalKey
            }
        }
        return nil
    }

    private func reconcileExistingTransfers() async {
        defer {
            isReconcilingTransfers = false
            completeDeferredProfileActivationIfPossible()
        }
        let activeTasks = await transferController.existingTasks()
        let activeProfileID = media.activeProfileID
        // A background relaunch (URLSession wake, BGTask) starts before the
        // Plex session and profile exist. Pausing or requeueing then would
        // treat every running transfer as another profile's and drop the
        // finished-file events that iOS is about to deliver. Keep transfers
        // running and decide per profile once one is active.
        let canJudgeProfiles = media.isSessionReady && activeProfileID != nil
        var matchedRecordKeys: Set<String> = []
        var changed = false

        for task in activeTasks {
            let recordIndex: Int?
            if let globalKey = task.globalKey,
               let exactIndex = storedRecords.firstIndex(where: { $0.globalKey == globalKey }) {
                recordIndex = exactIndex
            } else if let taskIndex = storedRecords.firstIndex(where: {
                $0.downloadTaskIdentifier == task.identifier
            }) {
                recordIndex = taskIndex
            } else if let globalKey = task.globalKey {
                let legacyIndices = storedRecords.indices.filter {
                    storedRecords[$0].legacyGlobalKey == globalKey
                        && (storedRecords[$0].status == .preparing
                            || storedRecords[$0].status == .downloading
                            || storedRecords[$0].status == .paused)
                }
                recordIndex = legacyIndices.count == 1 ? legacyIndices[0] : nil
            } else {
                recordIndex = nil
            }

            guard let recordIndex else {
                transferController.cancel(taskIdentifier: task.identifier)
                continue
            }

            matchedRecordKeys.insert(storedRecords[recordIndex].globalKey)
            storedRecords[recordIndex].downloadTaskIdentifier = task.identifier
            storedRecords[recordIndex].updatedAt = .now

            if !canJudgeProfiles {
                storedRecords[recordIndex].status = .downloading
                unjudgedRelaunchTransfers[storedRecords[recordIndex].globalKey] = task.identifier
            } else if storedRecords[recordIndex].accountProfileID == activeProfileID,
               media.isSessionReady {
                storedRecords[recordIndex].status = .downloading
            } else {
                storedRecords[recordIndex].status = .paused
                storedRecords[recordIndex].wasPausedForProfileSwitch = true
                pendingProfileSuspensionTaskIDs.insert(task.identifier)
                transferController.pause(taskIdentifier: task.identifier)
            }
            changed = true
        }

        for index in storedRecords.indices
        where storedRecords[index].status == .preparing || storedRecords[index].status == .downloading {
            if matchedRecordKeys.contains(storedRecords[index].globalKey) {
                continue
            }
            if !canJudgeProfiles {
                // Possibly finished while Dusk was not running: its event
                // still needs the record's task identifier.
                unjudgedRelaunchRecords.insert(storedRecords[index].globalKey)
                continue
            }

            if storedRecords[index].accountProfileID == activeProfileID,
               media.isSessionReady {
                storedRecords[index].status = .queued
                storedRecords[index].wasPausedForProfileSwitch = false
            } else {
                storedRecords[index].status = .paused
                storedRecords[index].wasPausedForProfileSwitch = true
            }
            storedRecords[index].downloadTaskIdentifier = nil
            storedRecords[index].updatedAt = .now
            changed = true
        }

        if changed {
            persist()
        }
        processQueueIfNeeded()
    }

    private func reconcileCompletedFiles() {
        var changed = false
        var reconciledRecords: [DownloadedMediaRecord] = []

        for var record in storedRecords {
            guard record.status == .completed else {
                reconciledRecords.append(record)
                continue
            }

            guard let fileURL = fileStore.existingFileURL(for: record.relativeVideoPath) else {
                changed = true
                continue
            }

            do {
                try validateDownloadedFileContents(
                    at: fileURL,
                    expectedSize: expectedVideoSize(for: record)
                )
                reconciledRecords.append(record)
            } catch {
                ErrorReporter.report(.downloadFailed, reason: .validate, error: error)
                record.status = .failed
                record.errorMessage = downloadErrorMessage(for: error)
                record.downloadTaskIdentifier = nil
                record.resumeDataPath = nil
                record.updatedAt = .now
                reconciledRecords.append(record)
                changed = true
            }
        }

        if changed {
            storedRecords = reconciledRecords
            persist()
        }
    }

    private func expectedVideoSize(for record: DownloadedMediaRecord) -> Int64? {
        if record.downloadQuality != .original {
            return record.convertedMedia?.parts.first?.size.map(Int64.init) ?? record.totalBytes
        }
        guard let accountProfileID = record.accountProfileID,
              let details = metadataCache.mediaDetails(
                accountProfileID: accountProfileID,
                serverID: record.serverID,
                itemID: record.itemID,
                kind: record.providerKind
              ) else {
            return record.totalBytes
        }

        let media = details.media.first(where: { $0.id == record.mediaID })
            ?? StreamResolver.selectMediaVersion(from: details.media, preferredMaxResolution: preferences.downloadMaxResolution)
        let part = media?.parts.first(where: { $0.id == record.partID }) ?? media?.parts.first
        return part?.size.map(Int64.init) ?? record.totalBytes
    }

    private func downloadErrorMessage(for error: Error) -> String {
        if let downloadError = error as? DownloadManagerError {
            return downloadError.localizedDescription
        }

        if let plexError = error as? MediaServiceError {
            switch plexError {
            case .notAuthenticated, .unauthorized:
                return "Plex authentication expired. Sign in again, then retry the download."
            case .noServerConnected:
                return "No Plex server is connected."
            case .invalidURL:
                return "The server did not provide a downloadable file URL."
            case .httpError(let statusCode):
                return "The Plex server rejected the download with HTTP \(statusCode)."
            case .networkError:
                return "The network connection was interrupted."
            default:
                return plexError.localizedDescription
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection."
            case NSURLErrorTimedOut:
                return "The download timed out."
            case NSURLErrorNetworkConnectionLost:
                return "The network connection was interrupted."
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "Could not reach the Plex server."
            default:
                return error.localizedDescription
            }
        }

        return error.localizedDescription
    }

    private func upsertFailedPlaceholder(id: MediaItemID, type: MediaKind, isClip: Bool = false, quality: DownloadQuality = .original, error: Error) {
        guard let accountProfileID = media.activeProfileID?.nilIfEmpty,
              let serverID = try? downloadServerID(for: id) else {
            return
        }
        let itemID = id.itemID
        let placeholder = DownloadedMediaRecord(
            accountProfileID: accountProfileID,
            serverID: serverID,
            serverName: serverName(for: serverID),
            provider: providerTag(for: serverID),
            itemID: itemID,
            type: type,
            isClip: isClip || type == .clip,
            title: cachedMediaDetails(for: MediaItemID(serverID: serverID, itemID: itemID))?.title ?? "Download",
            subtitle: nil,
            parentID: nil,
            parentTitle: nil,
            grandparentID: nil,
            grandparentTitle: nil,
            thumbPath: nil,
            artPath: nil,
            mediaID: nil,
            partID: nil,
            downloadQuality: quality,
            relativeVideoPath: nil,
            resumeDataPath: nil,
            downloadTaskIdentifier: nil,
            status: .failed,
            progress: 0,
            downloadedBytes: 0,
            totalBytes: nil,
            errorMessage: downloadErrorMessage(for: error),
            addedAt: .now,
            updatedAt: .now
        )
        upsert(placeholder)
    }

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(path)
            }
        }
        monitor.start(queue: networkMonitorQueue)
        networkMonitor = monitor
    }

    private func handleNetworkPathUpdate(_ path: NWPath) {
        let constrained = path.isExpensive || path.isConstrained
        hasNetworkPath = true
        guard constrained != isNetworkConstrained else { return }
        isNetworkConstrained = constrained
        // Transfers wait for Wi-Fi inside URLSession; only queue work that
        // was skipped needs a nudge.
        processQueueIfNeeded()
    }

    private func removeAggregatePlaceholder(for scope: DownloadScope) {
        guard scope.type == .season || scope.type == .show else { return }
        let activeProfileID = media.activeProfileID
        let originalCount = storedRecords.count
        storedRecords.removeAll {
            $0.accountProfileID == activeProfileID
                && $0.itemID == scope.itemID
                && (scope.serverID == nil || $0.serverID == scope.serverID)
                && $0.type == scope.type
                && $0.mediaID == nil
                && $0.partID == nil
        }
        if storedRecords.count != originalCount {
            persist()
        }
    }

    private func deleteRecords(_ targetRecords: [DownloadedMediaRecord]) {
        let recordsToDelete = targetRecords.filter { !deletingDownloadIDs.contains($0.globalKey) }
        guard !recordsToDelete.isEmpty else { return }

        for record in recordsToDelete {
            preparationTasks[record.globalKey]?.cancel()
            enqueueQueueRemoval(for: record)
            deletingDownloadIDs.insert(record.globalKey)
            if let taskIdentifier = record.downloadTaskIdentifier {
                transferController.cancel(taskIdentifier: taskIdentifier)
            }
        }

        Task.detached(priority: .utility) { [fileStore, recordsToDelete, weak self] in
            for record in recordsToDelete {
                fileStore.deleteVideo(relativePath: record.relativeVideoPath)
                fileStore.deleteResumeData(relativePath: record.resumeDataPath)
                fileStore.deleteSubtitles(
                    relativePaths: Array((record.externalSubtitlePaths ?? [:]).values),
                    globalKey: record.globalKey
                )
            }
            let globalKeys = Set(recordsToDelete.map(\.globalKey))
            await self?.finishDeleting(globalKeys: globalKeys)
        }
    }

    private func finishDeleting(globalKeys: Set<String>) {
        storedRecords.removeAll { globalKeys.contains($0.globalKey) }
        for globalKey in globalKeys {
            lastProgressPersistDates.removeValue(forKey: globalKey)
            speedEstimates.removeValue(forKey: globalKey)
            deletingDownloadIDs.remove(globalKey)
        }
        persist()
        processQueueIfNeeded()
    }

    private var currentSnapshot: DownloadStoreSnapshot {
        DownloadStoreSnapshot(
            records: storedRecords,
            pendingQueueRemovals: pendingQueueRemovals,
            smartDownloadRules: storedSmartDownloadRules.isEmpty ? nil : storedSmartDownloadRules
        )
    }

    private func persist() {
        try? fileStore.saveSnapshot(currentSnapshot)
    }
}

// MARK: - Smart Downloads (Keep Next N Unwatched)

extension DownloadManager {
    private static let smartRefillMinimumInterval: TimeInterval = 60

    /// The active profile's rules.
    var activeSmartDownloadRules: [SmartDownloadRule] {
        storedSmartDownloadRules.filter { $0.accountProfileID == media.activeProfileID }
    }

    var hasDownloadsContent: Bool {
        !records.isEmpty || !activeSmartDownloadRules.isEmpty
    }

    func smartDownloadRule(show: MediaItemID) -> SmartDownloadRule? {
        activeSmartDownloadRules.first {
            $0.showRatingKey == show.itemID && (show.serverID == nil || $0.serverID == show.serverID)
        }
    }

    /// Turns on Keep Next `count` Unwatched for a show and fills it right away.
    /// Existing downloads of the show stay manual: they count toward the
    /// window but the rule never removes them.
    func enableSmartDownloads(show: MediaItemID, count: Int, quality: DownloadQuality) async {
        guard !isProfileSwitching, media.isSessionReady,
              let accountProfileID = media.activeProfileID?.nilIfEmpty,
              let serverID = show.serverID ?? media.pool.primary?.serverID else { return }
        let showID = MediaItemID(serverID: serverID, itemID: show.itemID)
        if let existing = smartDownloadRule(show: showID) {
            updateSmartDownloadRule(existing.globalKey) {
                $0.count = count
                $0.quality = quality
            }
        } else {
            storedSmartDownloadRules.append(SmartDownloadRule(
                accountProfileID: accountProfileID,
                serverID: serverID,
                showRatingKey: show.itemID,
                count: count,
                quality: quality,
                createdAt: .now
            ))
            persist()
            // Title and artwork for the Downloads grid before any episode lands.
            if let details = try? await fetchAndCacheDetails(itemID: show.itemID, serverID: serverID),
               let rule = smartDownloadRule(show: showID) {
                updateSmartDownloadRule(rule.globalKey) {
                    $0.showTitle = details.title
                    $0.thumbPath = details.thumb
                    $0.artPath = details.art
                }
            }
        }
        if let rule = smartDownloadRule(show: showID) {
            refillSmartDownloads(rule: rule, force: true, userInitiated: true)
        }
    }

    func setSmartDownloadCount(_ count: Int, show: MediaItemID) {
        guard let rule = smartDownloadRule(show: show), rule.count != count else { return }
        updateSmartDownloadRule(rule.globalKey) { $0.count = count }
        if let updated = smartDownloadRule(show: show) {
            refillSmartDownloads(rule: updated, force: true, userInitiated: true)
        }
    }

    /// Stops the rule. Its downloads stay on the device as ordinary
    /// downloads; deleting them is the existing Delete action.
    func disableSmartDownloads(show: MediaItemID) {
        guard let rule = smartDownloadRule(show: show) else { return }
        removeSmartDownloadRule(show: rule.showID)
        var changed = false
        for index in storedRecords.indices
        where storedRecords[index].isSmartDownload
            && storedRecords[index].accountProfileID == rule.accountProfileID
            && storedRecords[index].type == .episode
            && matchesBranch(storedRecords[index], of: rule.showID) {
            storedRecords[index].isSmartDownload = false
            changed = true
        }
        if changed { persist() }
    }

    /// Called when an episode crossed the watched threshold in Dusk. Plex may
    /// not have the scrobble yet, so the episode counts as watched here.
    func smartDownloadsEpisodeWatched(_ episode: MediaItemID, showRatingKey: String) {
        guard let rule = smartDownloadRule(show: MediaItemID(serverID: episode.serverID, itemID: showRatingKey)) else {
            return
        }
        refillSmartDownloads(rule: rule, force: true, justWatched: [episode.itemID])
    }

    /// Refills every rule of the active profile (optionally only the rules on
    /// some servers). Rules refilled in the last minute are skipped.
    func refillSmartDownloads(serverIDs: Set<String>? = nil, force: Bool = false) {
        for rule in activeSmartDownloadRules where serverIDs?.contains(rule.serverID) ?? true {
            refillSmartDownloads(rule: rule, force: force)
        }
    }

    /// `userInitiated`: the user just turned the rule on or changed it, so
    /// the episodes it queues show the downloads Live Activity. Refills from
    /// watching, reconnects and the background task stay silent.
    private func refillSmartDownloads(
        rule: SmartDownloadRule,
        force: Bool,
        justWatched: Set<String> = [],
        userInitiated: Bool = false
    ) {
        let key = rule.globalKey
        if smartRefillTasks[key] != nil {
            smartRefillReruns[key, default: []].formUnion(justWatched)
            return
        }
        if !force, let last = rule.lastRefillAt,
           Date.now.timeIntervalSince(last) < Self.smartRefillMinimumInterval {
            return
        }
        smartRefillTasks[key] = Task { [weak self] in
            guard let self else { return }
            await self.performSmartRefill(ruleKey: key, justWatched: justWatched)
            self.smartRefillTasks.removeValue(forKey: key)
            if userInitiated {
                self.noteUserStartedDownloads()
            }
            if let rerun = self.smartRefillReruns.removeValue(forKey: key),
               let current = self.storedSmartDownloadRules.first(where: { $0.globalKey == key }) {
                self.refillSmartDownloads(rule: current, force: true, justWatched: rerun)
            }
        }
    }

    /// One refill: read the show's episodes and watch state from its own
    /// server, remove the rule's watched downloads, queue the missing ones.
    /// An unreachable server or a failed request changes nothing; the next
    /// foreground, server reconnect or finished episode tries again.
    private func performSmartRefill(ruleKey: String, justWatched: Set<String>) async {
        guard let rule = storedSmartDownloadRules.first(where: { $0.globalKey == ruleKey }),
              !isProfileSwitching, media.isSessionReady,
              rule.accountProfileID == media.activeProfileID,
              isServerConnected(rule.serverID) else { return }

        let episodes: [Episode]
        do {
            episodes = try await media.getAllEpisodes(showKey: rule.showRatingKey, serverID: rule.serverID)
        } catch {
            return
        }
        // An empty answer is more likely a server hiccup than a show with
        // every episode deleted; never clear the window on it.
        guard !Task.isCancelled, !episodes.isEmpty, !isProfileSwitching,
              rule.accountProfileID == media.activeProfileID,
              let current = storedSmartDownloadRules.first(where: { $0.globalKey == ruleKey }) else { return }

        let showRecords = records.filter { $0.type == .episode && matchesBranch($0, of: current.showID) }
        let plan = SmartDownloadPlanner.plan(
            episodes: episodes.map { episode in
                let plexWatched = episode.isWatched
                let watched = justWatched.contains(episode.itemID)
                    || (effectiveWatchedState?(current.serverID, episode.itemID, plexWatched) ?? plexWatched)
                return SmartDownloadPlanner.Episode(
                    itemID: episode.itemID,
                    seasonIndex: episode.parentIndex,
                    index: episode.index,
                    isWatched: watched
                )
            },
            downloads: showRecords.map {
                SmartDownloadPlanner.Download(globalKey: $0.globalKey, itemID: $0.itemID, isSmart: $0.isSmartDownload)
            },
            count: current.count
        )

        let removals = Set(plan.globalKeysToRemove)
        deleteRecords(showRecords.filter { removals.contains($0.globalKey) })
        updateSmartDownloadRule(ruleKey) {
            $0.remainingUnwatchedCount = plan.remainingUnwatchedCount
            $0.lastRefillAt = .now
            if $0.showTitle == nil { $0.showTitle = episodes.first?.grandparentTitle }
            if $0.thumbPath == nil { $0.thumbPath = episodes.first?.grandparentThumb }
        }

        let episodesByKey = Dictionary(episodes.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        for itemID in plan.ratingKeysToQueue {
            guard let episode = episodesByKey[itemID],
                  storedSmartDownloadRules.contains(where: { $0.globalKey == ruleKey }),
                  rule.accountProfileID == media.activeProfileID else { break }
            try? await queueEpisodeDownload(episode, quality: current.quality, isSmartDownload: true)
        }
        if !plan.ratingKeysToQueue.isEmpty {
            processQueueIfNeeded()
        }
    }

    /// The background refill (`SmartDownloadBackgroundRefill`): brings the
    /// session up if iOS launched Dusk without a scene, refills every rule of
    /// the active profile, then waits until the new episodes are handed to the
    /// background URLSession. Returns false when it could not run.
    func runBackgroundSmartRefill() async -> Bool {
        guard !storedSmartDownloadRules.isEmpty,
              await prepareSessionForBackgroundWork() else { return false }
        // Wi-Fi Only: decided on the real network, not the monitor's default.
        guard SmartDownloadBackgroundPolicy.shouldRun(
            hasRules: !activeSmartDownloadRules.isEmpty,
            wifiOnly: preferences.downloadsWifiOnly,
            isNetworkConstrained: isNetworkConstrained
        ) else { return false }

        refillSmartDownloads(force: true)
        for task in Array(smartRefillTasks.values) {
            await task.value
        }
        processQueueIfNeeded()

        // Original-quality episodes reach URLSession within seconds; a
        // converted copy waits for Plex, as long as iOS lets the task run.
        while !Task.isCancelled {
            let pending = records
                .filter { $0.isSmartDownload && $0.type == .episode }
                .map { (status: $0.status, serverConnected: isServerConnected($0.serverID)) }
            if SmartDownloadBackgroundPolicy.isHandedOff(pending), smartRefillTasks.isEmpty { break }
            // The queue skips a pass while relaunch reconciliation runs.
            processQueueIfNeeded()
            try? await Task.sleep(for: .seconds(1))
        }
        return !Task.isCancelled
    }

    private func removeSmartDownloadRule(show: MediaItemID) {
        guard let rule = smartDownloadRule(show: show) else { return }
        smartRefillTasks.removeValue(forKey: rule.globalKey)?.cancel()
        smartRefillReruns.removeValue(forKey: rule.globalKey)
        storedSmartDownloadRules.removeAll { $0.globalKey == rule.globalKey }
        persist()
    }

    private func updateSmartDownloadRule(_ globalKey: String, mutate: (inout SmartDownloadRule) -> Void) {
        guard let index = storedSmartDownloadRules.firstIndex(where: { $0.globalKey == globalKey }) else { return }
        mutate(&storedSmartDownloadRules[index])
        persist()
    }
}

#if DEBUG
extension DownloadManager {
    /// Screenshot mode only (`ScreenshotMode`): records a movie, an episode or
    /// every episode of a season as a finished download. Metadata and artwork
    /// go through the normal cache path; the video is a tiny placeholder,
    /// extended (sparse) to the part's size so the launch-time file check
    /// keeps the record.
    func seedCompletedDownloadForScreenshot(id: MediaItemID, type: MediaKind) async {
        guard let serverID = id.serverID,
              media.isSessionReady,
              let accountProfileID = media.activeProfileID?.nilIfEmpty else { return }

        do {
            if type == .season {
                let episodes = try await fetchAndCacheChildren(
                    Episode.self,
                    itemID: id.itemID,
                    serverID: serverID
                )
                for episode in episodes {
                    await seedCompletedDownloadForScreenshot(
                        id: MediaItemID(serverID: serverID, itemID: episode.itemID),
                        type: .episode
                    )
                }
                return
            }

            guard record(for: id)?.status != .completed else { return }
            let details = try await fetchAndCacheDetails(itemID: id.itemID, serverID: serverID)
            if details.type == .episode {
                try await cacheEpisodeContext(details, serverID: serverID)
            }
            guard let media = StreamResolver.selectMediaVersion(
                from: details.media,
                preferredMaxResolution: preferences.downloadMaxResolution
            ), let part = media.parts.first else { return }

            let targetURL = try fileStore.targetVideoURL(
                accountProfileID: accountProfileID,
                for: details,
                part: part
            )
            try Data("dusk-screenshot-placeholder".utf8).write(to: targetURL)
            let size = Int64(part.size ?? 0)
            if size > 0 {
                let handle = try FileHandle(forWritingTo: targetURL)
                try handle.truncate(atOffset: UInt64(size))
                try handle.close()
            }
            await cacheArtwork(for: details, serverID: serverID)

            upsert(DownloadedMediaRecord(
                accountProfileID: accountProfileID,
                serverID: serverID,
                serverName: serverName(for: serverID),
                provider: providerTag(for: serverID),
                itemID: id.itemID,
                type: details.type,
                isClip: details.isClip,
                title: details.title,
                subtitle: subtitle(for: details),
                parentID: details.parentID,
                parentTitle: nil,
                grandparentID: details.grandparentID,
                grandparentTitle: details.grandparentTitle,
                thumbPath: details.thumb ?? details.parentThumb ?? details.grandparentThumb,
                artPath: details.art,
                mediaID: media.id,
                partID: part.id,
                relativeVideoPath: fileStore.relativePath(for: targetURL),
                resumeDataPath: nil,
                downloadTaskIdentifier: nil,
                status: .completed,
                progress: 1,
                downloadedBytes: size,
                totalBytes: size > 0 ? size : nil,
                errorMessage: nil,
                addedAt: .now,
                updatedAt: .now
            ))
        } catch {
            print("Screenshot download seed failed for \(id.itemID): \(error)")
        }
    }
}
#endif
