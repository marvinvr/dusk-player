import Foundation
import Network
import Observation

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

    private let plexService: PlexService
    private let preferences: UserPreferences
    private let fileStore: DownloadFileStore
    private let metadataCache: PlexMetadataCache

    private(set) var storedRecords: [DownloadedMediaRecord] = []
    private(set) var isProcessingQueue = false
    private(set) var isQueuePaused = false
    private(set) var deletingDownloadIDs: Set<String> = []

    private(set) var isNetworkConstrained = false

    @ObservationIgnored private var isNetworkPaused = false
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
    @ObservationIgnored private lazy var transferController = DownloadTransferController { [weak self] event in
        Task { @MainActor [weak self] in
            self?.handleTransferEvent(event)
        }
    }

    init(
        plexService: PlexService,
        preferences: UserPreferences,
        fileStore: DownloadFileStore = DownloadFileStore()
    ) {
        self.plexService = plexService
        self.preferences = preferences
        self.fileStore = fileStore
        self.metadataCache = PlexMetadataCache(fileStore: fileStore)
        try? fileStore.prepareRootDirectory()
        let snapshot = fileStore.loadSnapshot()
        storedRecords = snapshot.records
        pendingQueueRemovals = snapshot.pendingQueueRemovals ?? []
        rekeyLegacyServerIdentifiers()
        reconcileCompletedFiles()
        _ = transferController
        startNetworkMonitoring()
        observeServerConnectivity()
        connectedServerIDs = Set(plexService.pool.connections.map(\.serverID))
        Task { [weak self] in
            await self?.reconcileExistingTransfers()
        }
    }

    /// Downloads waiting on a server that was offline or switched off resume as
    /// soon as that server comes back, without the user touching anything.
    private func observeServerConnectivity() {
        withObservationTracking {
            _ = plexService.pool.connections.map(\.serverID)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.serverConnectivityDidChange()
            }
        }
    }

    private func serverConnectivityDidChange() {
        observeServerConnectivity()
        rekeyLegacyServerIdentifiers()
        let current = Set(plexService.pool.connections.map(\.serverID))
        let appeared = current.subtracting(connectedServerIDs)
        connectedServerIDs = current
        guard !appeared.isEmpty else { return }
        processQueueIfNeeded()
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
            guard !plexService.isKnownServerID(legacyServerID),
                  let resolved = plexService.serverID(forLegacyConnectionURI: legacyServerID),
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
        guard record.status == .queued else { return nil }
        let name = serverName(for: record.serverID) ?? record.serverName ?? "the server"
        switch plexService.pool.state(for: record.serverID) {
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
        storedRecords.filter { $0.accountProfileID == plexService.activeProfileID }
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

    var activeDownloadCount: Int {
        records.filter { $0.status == .preparing || $0.status == .downloading }.count
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
            PlexItemID(
                serverID: record.serverID,
                ratingKey: record.grandparentRatingKey ?? record.parentRatingKey ?? record.ratingKey
            )
        }

        return grouped.compactMap { showID, episodes -> DownloadedShowSummary? in
            guard let first = episodes.first,
                  let accountProfileID = first.accountProfileID else {
                return nil
            }
            let showKey = showID.ratingKey
            // Every record in the group shares the server the key was grouped on.
            let serverID = first.serverID
            let cachedShow = metadataCache.mediaDetails(
                accountProfileID: accountProfileID,
                serverID: serverID,
                ratingKey: showKey
            )
            let title = cachedShow?.title ?? first.grandparentTitle ?? "TV Show"
            return DownloadedShowSummary(
                serverID: serverID,
                ratingKey: showKey,
                title: title,
                thumbPath: cachedShow?.thumb ?? first.thumbPath,
                artPath: cachedShow?.art ?? first.artPath,
                downloadedEpisodeCount: episodes.count,
                totalEpisodeCount: cachedShow?.leafCount
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The record for one item.
    ///
    /// Strict by design: the answer feeds `localPlaybackURL` and
    /// `downloadedMediaVersion`, so matching the wrong server's record would
    /// play a different file. An `id` without a server (an unstamped offline
    /// cache, a legacy route) is only resolved when exactly one record carries
    /// that rating key — an ambiguous match is no match.
    func record(for id: PlexItemID) -> DownloadedMediaRecord? {
        guard let serverID = id.serverID else {
            let matches = records.filter { $0.ratingKey == id.ratingKey }
            return matches.count == 1 ? matches.first : nil
        }
        return records.first { $0.ratingKey == id.ratingKey && $0.serverID == serverID }
    }

    func serverID(for id: PlexItemID) -> String? {
        record(for: id)?.serverID
    }

    func canPause(id: PlexItemID) -> Bool {
        record(for: id)?.status.canPause == true
    }

    func canResume(id: PlexItemID) -> Bool {
        record(for: id)?.status.canResume == true
    }

    func status(for id: PlexItemID) -> DownloadStatus? {
        record(for: id)?.status
    }

    func status(for id: PlexItemID, type: PlexMediaType) -> DownloadStatus? {
        downloadState(for: DownloadScope(id: id, type: type)).status
    }

    func progress(for id: PlexItemID) -> Double? {
        record(for: id)?.progress
    }

    func progress(for id: PlexItemID, type: PlexMediaType) -> Double? {
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

    func isDownloaded(id: PlexItemID) -> Bool {
        record(for: id)?.status == .completed
    }

    func isDeletingDownload(id: PlexItemID) -> Bool {
        guard let record = record(for: id) else { return false }
        return deletingDownloadIDs.contains(record.globalKey)
    }

    func isDeletingDownload(id: PlexItemID, type: PlexMediaType) -> Bool {
        downloadState(for: DownloadScope(id: id, type: type)).isDeleting
    }

    func isDeletingDownloads(show: PlexItemID) -> Bool {
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

    func isPlayableOffline(id: PlexItemID) -> Bool {
        localPlaybackURL(for: id) != nil
    }

    func hasDownloadedEpisodes(show: PlexItemID) -> Bool {
        downloadedEpisodes.contains { matchesBranch($0, of: show) }
    }

    func hasDownloadedEpisodes(season: PlexItemID) -> Bool {
        downloadedEpisodes.contains { matchesSeason($0, of: season) }
    }

    func downloadedEpisodeCount(season: PlexItemID) -> Int {
        downloadedEpisodes.filter { matchesSeason($0, of: season) }.count
    }

    func downloadedEpisodeCount(show: PlexItemID) -> Int {
        downloadedEpisodes.filter { record in
            record.grandparentRatingKey == show.ratingKey && matchesServer(record, of: show)
        }.count
    }

    func queueDownload(id: PlexItemID, type: PlexMediaType, isClip: Bool = false, quality: DownloadQuality? = nil) async {
        let initiatingProfileID = plexService.activeProfileID
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
        } catch {
            guard !(error is CancellationError), !isProfileSwitching,
                  initiatingProfileID == plexService.activeProfileID else { return }
            upsertFailedPlaceholder(id: id, type: type, isClip: isClip, quality: quality, error: error)
        }
    }

    func queueDownload(episode: PlexEpisode, quality: DownloadQuality = .original) async {
        let initiatingProfileID = plexService.activeProfileID
        do {
            try await queueEpisodeDownload(episode, quality: quality)
            processQueueIfNeeded()
        } catch {
            guard !(error is CancellationError), !isProfileSwitching,
                  initiatingProfileID == plexService.activeProfileID else { return }
            upsertFailedPlaceholder(id: episode.id, type: .episode, quality: quality, error: error)
        }
    }

    /// An episode record belongs to a season when both the key and the server
    /// match; a nil server on the scope means "any server", for callers that
    /// only have a cached key.
    private func matchesSeason(_ record: DownloadedMediaRecord, of season: PlexItemID) -> Bool {
        record.parentRatingKey == season.ratingKey && matchesServer(record, of: season)
    }

    private func matchesBranch(_ record: DownloadedMediaRecord, of show: PlexItemID) -> Bool {
        (record.grandparentRatingKey == show.ratingKey || record.parentRatingKey == show.ratingKey)
            && matchesServer(record, of: show)
    }

    private func matchesServer(_ record: DownloadedMediaRecord, of id: PlexItemID) -> Bool {
        id.serverID == nil || record.serverID == id.serverID
    }

    /// Pauses the outgoing profile before PlexService replaces its credentials.
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

    /// Refreshes queue ownership after PlexService has installed a profile.
    /// Legacy adoption must only be requested for the original pre-Plex-Home
    /// account, never for an arbitrary user selected from the Home picker.
    func activateProfile() {
        if plexService.shouldAdoptLegacyProfileData,
           let primaryProfileID = plexService.primaryProfileID?.nilIfEmpty {
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

    private func completeProfileActivation() {
        hasDeferredProfileActivation = false
        lastProgressPersistDates.removeAll()
        speedEstimates.removeAll()
        let activeProfileID = plexService.activeProfileID
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
        evaluateNetworkConstraints()
        processQueueIfNeeded()
    }

    private func completeDeferredProfileActivationIfPossible() {
        guard hasDeferredProfileActivation,
              !isReconcilingTransfers,
              pendingProfileSuspensionTaskIDs.isEmpty else {
            return
        }
        completeProfileActivation()
    }

    func retryDownload(id: PlexItemID) {
        guard let record = record(for: id) else { return }
        retryDownload(globalKey: record.globalKey)
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

    func pauseDownload(id: PlexItemID) {
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

    func pauseDownload(id: PlexItemID, type: PlexMediaType) {
        pauseDownload(scope: DownloadScope(id: id, type: type))
    }

    func pauseDownload(scope: DownloadScope) {
        performOnRelatedRecords(scope) { record in
            guard record.status.canPause else { return }
            pauseDownload(globalKey: record.globalKey, forProfileSwitch: false)
        }
    }

    func resumeDownload(id: PlexItemID) {
        guard let record = record(for: id) else { return }
        resumeDownload(globalKey: record.globalKey)
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

    func resumeDownload(id: PlexItemID, type: PlexMediaType) {
        resumeDownload(scope: DownloadScope(id: id, type: type))
    }

    func resumeDownload(scope: DownloadScope) {
        performOnRelatedRecords(scope) { record in
            guard record.status.canResume else { return }
            resumeDownload(globalKey: record.globalKey)
        }
    }

    func cancelDownload(id: PlexItemID) {
        guard let record = record(for: id) else { return }
        cancelDownload(record)
    }

    private func cancelDownload(_ record: DownloadedMediaRecord) {
        guard record.status != .completed else { return }
        deleteRecords([record])
    }

    func cancelDownload(id: PlexItemID, type: PlexMediaType) {
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
        let activeProfileID = plexService.activeProfileID
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
    }

    /// Re-evaluates whether downloads should be paused or resumed based on
    /// the current network state and the Wi-Fi Only preference.
    /// Called automatically when the network path changes and should also be
    /// called externally when `preferences.downloadsWifiOnly` is toggled.
    func resumePendingWork() {
        evaluateNetworkConstraints()
        processQueueIfNeeded()
    }

    func evaluateNetworkConstraints() {
        if preferences.downloadsWifiOnly && isNetworkConstrained {
            if !isQueuePaused {
                isNetworkPaused = true
                pauseAllDownloads()
            }
        } else if isNetworkPaused {
            isNetworkPaused = false
            resumeAllDownloads()
        }
    }

    func deleteDownload(id: PlexItemID) {
        guard let record = record(for: id) else { return }
        deleteRecords([record])
    }

    func deleteDownload(id: PlexItemID, type: PlexMediaType) {
        deleteDownload(scope: DownloadScope(id: id, type: type))
    }

    func deleteDownload(scope: DownloadScope) {
        deleteRecords(relatedRecords(for: scope))
    }

    func deleteDownloads(show: PlexItemID) {
        deleteDownload(scope: DownloadScope(id: show, type: .show))
    }

    func deleteAllDownloads() {
        deleteRecords(records)
    }

    func localPlaybackURL(for id: PlexItemID, selectedMediaID: Int? = nil) -> URL? {
        guard let record = record(for: id),
              record.status == .completed,
              selectedMediaID == nil || selectedMediaID == record.mediaID else {
            return nil
        }
        return fileStore.existingFileURL(for: record.relativeVideoPath)
    }

    func downloadedMediaVersion(
        for id: PlexItemID,
        in details: PlexMediaDetails,
        selectedMediaID: Int? = nil
    ) -> (media: PlexMedia, part: PlexMediaPart)? {
        guard let record = record(for: id),
              record.status == .completed,
              selectedMediaID == nil || selectedMediaID == record.mediaID else {
            return nil
        }
        if record.downloadQuality != .original {
            guard let media = record.convertedMedia, let part = media.parts.first else { return nil }
            return (media, part)
        }
        guard let mediaID = record.mediaID,
              let partID = record.partID,
              let media = details.media.first(where: { $0.id == mediaID }),
              let part = media.parts.first(where: { $0.id == partID }) else {
            return nil
        }
        return (media, part)
    }

    func cachedMediaDetails(for id: PlexItemID) -> PlexMediaDetails? {
        guard let accountProfileID = plexService.activeProfileID?.nilIfEmpty else { return nil }
        return metadataCache.firstCachedMediaDetails(
            accountProfileID: accountProfileID,
            ratingKey: id.ratingKey,
            serverIDs: candidateServerIDs(for: id)
        )
    }

    func cachedSeasons(show: PlexItemID) -> [PlexSeason]? {
        guard let accountProfileID = plexService.activeProfileID?.nilIfEmpty else { return nil }
        return metadataCache.firstCachedSeasons(
            accountProfileID: accountProfileID,
            showKey: show.ratingKey,
            serverIDs: candidateServerIDs(for: show)
        )
    }

    func cachedEpisodes(season: PlexItemID) -> [PlexEpisode]? {
        guard let accountProfileID = plexService.activeProfileID?.nilIfEmpty else { return nil }
        return metadataCache.firstCachedEpisodes(
            accountProfileID: accountProfileID,
            seasonKey: season.ratingKey,
            serverIDs: candidateServerIDs(for: season)
        )
    }

    func cachedNextDownloadedEpisode(after episode: PlexMediaDetails) -> PlexEpisode? {
        guard episode.type == .episode,
              let seasonKey = episode.parentRatingKey,
              let showKey = episode.grandparentRatingKey else {
            return nil
        }

        let serverID = episode.serverID
        let currentSeasonEpisodes = (cachedEpisodes(season: PlexItemID(serverID: serverID, ratingKey: seasonKey)) ?? [])
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

        if let currentEpisodeIndex = currentSeasonEpisodes.firstIndex(where: { $0.ratingKey == episode.ratingKey }) {
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

        let seasons = (cachedSeasons(show: PlexItemID(serverID: serverID, ratingKey: showKey)) ?? [])
            .sorted { $0.index < $1.index }
        let currentSeasonIndex = episode.parentIndex
            ?? seasons.first(where: { $0.ratingKey == seasonKey })?.index

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

    /// `PlexService.getAdjacentEpisodes` over the metadata cache, limited to
    /// episodes that play offline: the neighbours a download-only session can
    /// actually reach.
    func cachedAdjacentDownloadedEpisodes(around episode: PlexMediaDetails) -> PlexAdjacentEpisodes {
        guard episode.type == .episode,
              let seasonKey = episode.parentRatingKey,
              let showKey = episode.grandparentRatingKey else {
            return PlexAdjacentEpisodes()
        }

        let serverID = episode.serverID
        let isDownloaded: (PlexEpisode) -> Bool = { [self] in isPlayableOffline(id: $0.id) }
        let currentSeasonEpisodes = (cachedEpisodes(season: PlexItemID(serverID: serverID, ratingKey: seasonKey)) ?? [])
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        var adjacent = PlexAdjacentEpisodes.inSeason(
            currentSeasonEpisodes,
            around: episode,
            isEligible: isDownloaded
        )
        guard adjacent.previous == nil || adjacent.next == nil else { return adjacent }

        let seasons = (cachedSeasons(show: PlexItemID(serverID: serverID, ratingKey: showKey)) ?? [])
            .sorted { $0.index < $1.index }
        let currentSeasonIndex = episode.parentIndex
            ?? seasons.first(where: { $0.ratingKey == seasonKey })?.index
        guard let currentSeasonIndex else { return adjacent }

        func downloadedEpisodes(in season: PlexSeason) -> [PlexEpisode] {
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
    private func candidateServerIDs(for id: PlexItemID) -> [String] {
        var ids: [String] = []
        if let serverID = id.serverID {
            ids.append(serverID)
        }
        for serverID in plexService.pool.connections.map(\.serverID) where !ids.contains(serverID) {
            ids.append(serverID)
        }
        for serverID in records.map(\.serverID) where !ids.contains(serverID) {
            ids.append(serverID)
        }
        return ids
    }

    /// The server a new download belongs to: the item's own, or the primary one
    /// when the caller could not say (an unstamped item from a cache).
    private func downloadServerID(for id: PlexItemID) throws -> String {
        guard let serverID = id.serverID ?? plexService.pool.primary?.serverID else {
            throw PlexServiceError.noServerConnected
        }
        return serverID
    }

    private func serverName(for serverID: String) -> String? {
        plexService.pool.server(for: serverID)?.name
            ?? plexService.pool.connection(for: serverID)?.name
    }

    private func queueSingleDownload(id: PlexItemID, type: PlexMediaType, isClip: Bool = false, quality: DownloadQuality = .original) async throws {
        guard type == .movie || type == .episode || type == .clip else { return }
        guard !isProfileSwitching,
              plexService.isSessionReady,
              let accountProfileID = plexService.activeProfileID?.nilIfEmpty else {
            throw PlexServiceError.notAuthenticated
        }
        let serverID = try downloadServerID(for: id)
        let ratingKey = id.ratingKey

        if let existing = record(for: PlexItemID(serverID: serverID, ratingKey: ratingKey)),
           existing.status != .cancelled {
            if existing.status.canResume { resumeDownload(globalKey: existing.globalKey) }
            return
        }

        let cachedDetails = metadataCache.mediaDetails(
            accountProfileID: accountProfileID,
            serverID: serverID,
            ratingKey: ratingKey
        )
        let record = DownloadedMediaRecord(
            accountProfileID: accountProfileID,
            serverID: serverID,
            serverName: serverName(for: serverID),
            ratingKey: ratingKey,
            type: cachedDetails?.type ?? type,
            isClip: isClip || type == .clip || cachedDetails?.isClip == true,
            title: cachedDetails?.title ?? "Download",
            subtitle: cachedDetails.flatMap(subtitle),
            parentRatingKey: cachedDetails?.parentRatingKey,
            parentTitle: nil,
            grandparentRatingKey: cachedDetails?.grandparentRatingKey,
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

    private func queueEpisodeDownload(_ episode: PlexEpisode, quality: DownloadQuality = .original) async throws {
        guard !isProfileSwitching,
              plexService.isSessionReady,
              let accountProfileID = plexService.activeProfileID?.nilIfEmpty else {
            throw PlexServiceError.notAuthenticated
        }
        let serverID = try downloadServerID(for: episode.id)

        if let existing = record(for: PlexItemID(serverID: serverID, ratingKey: episode.ratingKey)),
           existing.status != .cancelled {
            if existing.status.canResume { resumeDownload(globalKey: existing.globalKey) }
            return
        }

        let cachedDetails = metadataCache.mediaDetails(
            accountProfileID: accountProfileID,
            serverID: serverID,
            ratingKey: episode.ratingKey
        )
        let record = DownloadedMediaRecord(
            accountProfileID: accountProfileID,
            serverID: serverID,
            serverName: serverName(for: serverID),
            ratingKey: episode.ratingKey,
            type: .episode,
            title: cachedDetails?.title ?? episode.title,
            subtitle: cachedDetails.map(subtitle) ?? MediaTextFormatter.seasonEpisodeLabel(
                season: episode.parentIndex,
                episode: episode.index
            ),
            parentRatingKey: cachedDetails?.parentRatingKey ?? episode.parentRatingKey,
            parentTitle: episode.parentTitle,
            grandparentRatingKey: cachedDetails?.grandparentRatingKey ?? episode.grandparentRatingKey,
            grandparentTitle: cachedDetails?.grandparentTitle ?? episode.grandparentTitle,
            thumbPath: cachedDetails.flatMap { $0.thumb ?? $0.parentThumb ?? $0.grandparentThumb }
                ?? episode.thumb
                ?? episode.grandparentThumb,
            artPath: cachedDetails?.art ?? episode.art,
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

    /// Season and show downloads expand into per-episode records on the SAME
    /// server the season/show was opened from; children never inherit the
    /// primary server.
    private func queueSeasonDownload(season: PlexItemID, quality: DownloadQuality) async throws {
        let profileID = plexService.activeProfileID
        let serverID = try downloadServerID(for: season)
        let seasonDetails = try await fetchAndCacheDetails(ratingKey: season.ratingKey, serverID: serverID)
        if let showKey = seasonDetails.parentRatingKey {
            _ = try? await fetchAndCacheDetails(ratingKey: showKey, serverID: serverID)
            if let seasons = try? await fetchAndCacheChildren(
                PlexSeason.self,
                ratingKey: showKey,
                serverID: serverID
            ) {
                await cacheArtwork(for: seasons, serverID: serverID)
            }
        }

        let episodes = try await fetchAndCacheChildren(
            PlexEpisode.self,
            ratingKey: season.ratingKey,
            serverID: serverID
        )
        .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        await cacheArtwork(for: episodes, serverID: serverID)

        for episode in episodes {
            guard profileID == plexService.activeProfileID, !isProfileSwitching else { throw CancellationError() }
            try await queueEpisodeDownload(episode, quality: quality)
        }
    }

    private func queueShowDownload(show: PlexItemID, quality: DownloadQuality) async throws {
        let profileID = plexService.activeProfileID
        let serverID = try downloadServerID(for: show)
        _ = try await fetchAndCacheDetails(ratingKey: show.ratingKey, serverID: serverID)
        let seasons = try await fetchAndCacheChildren(
            PlexSeason.self,
            ratingKey: show.ratingKey,
            serverID: serverID
        )
        .sorted { $0.index < $1.index }
        await cacheArtwork(for: seasons, serverID: serverID)

        for season in seasons {
            guard profileID == plexService.activeProfileID, !isProfileSwitching else { throw CancellationError() }
            try await queueSeasonDownload(
                season: PlexItemID(serverID: serverID, ratingKey: season.ratingKey),
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

    private var occupiedTransferSlots: Int {
        records.filter {
            $0.status == .downloading || ($0.status == .preparing && $0.downloadQuality == .original)
        }.count
    }

    private func processQueue() async {
        isProcessingQueue = true
        defer {
            isProcessingQueue = false
            queueTask = nil
        }
        processPendingQueueRemovals()
        guard plexService.isSessionReady,
              plexService.activeProfileID?.nilIfEmpty != nil,
              !isReconcilingTransfers, !isProfileSwitching, !isQueuePaused else { return }

        // Limit server conversions separately so preparing a long movie does
        // not prevent an Original download from using a free transfer slot.
        for next in records where next.status == .queued {
            guard preparationTasks[next.globalKey] == nil,
                  !deletingDownloadIDs.contains(next.globalKey),
                  isServerConnected(next.serverID) else { continue }
            if next.downloadQuality == .original {
                guard occupiedTransferSlots < preferences.maximumActiveDownloads.rawValue else { continue }
            } else {
                guard records.filter({ $0.status == .preparing && $0.downloadQuality != .original }).count < 2 else { continue }
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
        plexService.pool.connection(for: serverID) != nil
    }

    /// Rechecked after every suspension, before changing state or handing off
    /// a file. A late response must never restart a paused/cancelled request.
    private func checkPreparation(_ record: DownloadedMediaRecord) throws {
        try Task.checkCancellation()
        guard !isProfileSwitching, !isQueuePaused,
              record.accountProfileID == plexService.activeProfileID,
              plexService.isSessionReady,
              self.record(globalKey: record.globalKey)?.status == .preparing,
              !deletingDownloadIDs.contains(record.globalKey) else { throw CancellationError() }
        guard isServerConnected(record.serverID) else { throw PlexServiceError.noServerConnected }
    }

    private func startDownload(record: DownloadedMediaRecord) async {
        do {
            try checkPreparation(record)
            let details: PlexMediaDetails
            // Conversion needs live ordering: mediaIndex is positional, while
            // the persisted source mediaID identifies the chosen version.
            if record.downloadQuality == .original,
               let accountProfileID = record.accountProfileID,
               let cached = metadataCache.mediaDetails(accountProfileID: accountProfileID,
                                                       serverID: record.serverID, ratingKey: record.ratingKey) {
                details = cached
            } else {
                details = try await fetchAndCacheDetails(ratingKey: record.ratingKey, serverID: record.serverID)
            }
            try checkPreparation(record)
            guard details.type == .movie || details.type == .episode || details.type == .clip else {
                throw PlexServiceError.decodingError("Downloads are only supported for movies, episodes, and videos.")
            }
            if details.type == .episode {
                try await cacheEpisodeContext(details, serverID: record.serverID)
                try checkPreparation(record)
            }
            let media: PlexMedia?
            if let sourceID = record.mediaID, record.downloadQuality != .original {
                media = details.media.first { $0.id == sourceID }
            } else {
                media = details.media.first(where: { $0.id == record.mediaID })
                    ?? StreamResolver.selectMediaVersion(from: details.media, preferredMaxResolution: preferences.downloadMaxResolution)
            }
            guard let media, let part = media.parts.first(where: { $0.id == record.partID }) ?? media.firstAvailablePart else {
                throw PlexServiceError.decodingError("The selected source version is no longer available. Cancel and download again to choose another version.")
            }
            update(globalKey: record.globalKey) { item in
                item.title = details.title
                item.isClip = item.isClip || details.isClip
                item.subtitle = subtitle(for: details)
                item.parentRatingKey = details.parentRatingKey
                item.grandparentRatingKey = details.grandparentRatingKey
                item.grandparentTitle = details.grandparentTitle
                item.thumbPath = details.thumb ?? details.parentThumb ?? details.grandparentThumb
                item.artPath = details.art
                item.mediaID = media.id
                item.partID = part.id
                item.updatedAt = .now
            }
            var request: URLRequest
            let transferPart: PlexMediaPart
            if record.downloadQuality != .original {
                guard let mediaIndex = details.media.firstIndex(where: { $0.id == media.id }) else {
                    throw PlexServiceError.invalidURL
                }
                let prepared = try await prepareConvertedDownload(record: record, sourceMedia: media, mediaIndex: mediaIndex)
                try checkPreparation(record)
                guard let preparedPart = prepared.media.parts.first else { throw PlexServiceError.invalidURL }
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
                try fileStore.saveSnapshot(DownloadStoreSnapshot(records: storedRecords, pendingQueueRemovals: pendingQueueRemovals))
            } else {
                guard let connection = plexService.pool.connection(for: record.serverID),
                      let sourceURL = plexService.directPlayURL(for: part, serverID: record.serverID) else {
                    throw PlexServiceError.invalidURL
                }
                request = URLRequest(url: sourceURL)
                plexService.applyHeaders(to: &request, token: connection.token)
                transferPart = part
            }
            try checkPreparation(record)
            guard let latest = self.record(globalKey: record.globalKey), let profileID = record.accountProfileID else {
                throw CancellationError()
            }
            _ = try fileStore.targetVideoURL(accountProfileID: profileID, for: details, part: transferPart)
            try validateAvailableStorage(for: transferPart)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.allowsExpensiveNetworkAccess = !preferences.downloadsWifiOnly
            request.allowsConstrainedNetworkAccess = !preferences.downloadsWifiOnly
            let resumeData = fileStore.resumeData(relativePath: latest.resumeDataPath)
            let taskIdentifier = transferController.start(request: request, resumeData: resumeData, globalKey: record.globalKey)
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
            if error is CancellationError || Task.isCancelled || isProfileSwitching
                || record.accountProfileID != plexService.activeProfileID {
                return
            }
            update(globalKey: record.globalKey) {
                $0.status = .failed
                $0.downloadTaskIdentifier = nil
                $0.errorMessage = downloadErrorMessage(for: error)
                $0.updatedAt = .now
            }
        }
    }

    private func prepareConvertedDownload(
        record: DownloadedMediaRecord, sourceMedia: PlexMedia, mediaIndex: Int
    ) async throws -> PlexPreparedDownload {
        guard let profileID = record.accountProfileID else { throw PlexServiceError.notAuthenticated }
        try checkPreparation(record)
        guard var latest = self.record(globalKey: record.globalKey) else { throw CancellationError() }
        if latest.queueClientIdentifier == nil {
            latest.queueClientIdentifier = UUID().uuidString
            upsert(latest)
        }
        // Retry this checked write even if a previous persistence attempt
        // failed after assigning the in-memory identity.
        try fileStore.saveSnapshot(DownloadStoreSnapshot(records: storedRecords, pendingQueueRemovals: pendingQueueRemovals))
        let context = try plexService.captureDownloadQueueContext(
            serverID: record.serverID, profileID: profileID, clientIdentifier: latest.queueClientIdentifier!
        )
        do {
            let queueID: String
            if let existing = latest.plexDownloadQueueID {
                queueID = existing
            } else {
                queueID = try await plexService.createDownloadQueue(context: context)
                update(globalKey: record.globalKey) { $0.plexDownloadQueueID = queueID }
                try checkPreparation(record)
            }
            try fileStore.saveSnapshot(DownloadStoreSnapshot(records: storedRecords, pendingQueueRemovals: pendingQueueRemovals))
            let itemID: String
            if let existing = latest.plexDownloadItemID {
                itemID = existing
            } else {
                itemID = try await plexService.addDownloadQueueItem(
                    context: context, queueID: queueID, ratingKey: record.ratingKey,
                    mediaIndex: mediaIndex, quality: record.downloadQuality
                )
                // Save a late add even after a pause. If cancelled, remember
                // cleanup independently of the deleted download record.
                if self.record(globalKey: record.globalKey) == nil || deletingDownloadIDs.contains(record.globalKey) {
                    enqueueQueueRemoval(DownloadQueueRemoval(profileID: profileID, serverID: record.serverID,
                        clientIdentifier: latest.queueClientIdentifier!, ratingKey: record.ratingKey, queueID: queueID, itemID: itemID))
                } else {
                    update(globalKey: record.globalKey) { $0.plexDownloadItemID = itemID }
                }
                try checkPreparation(record)
            }
            while true {
                try checkPreparation(record)
                // Conversion can outlive a LAN/remote endpoint change or token
                // refresh. Capture the current connection for each poll, while
                // keeping the durable client and owning profile unchanged.
                let pollContext = try plexService.captureDownloadQueueContext(
                    serverID: record.serverID, profileID: profileID, clientIdentifier: latest.queueClientIdentifier!
                )
                let item = try await plexService.downloadQueueItem(context: pollContext, queueID: queueID, itemID: itemID)
                try checkPreparation(record)
                guard item.key == "/library/metadata/\(record.ratingKey)" else {
                    throw PlexDownloadQueueError.invalidResponse("Plex returned a different item for this download.")
                }
                update(globalKey: record.globalKey) { $0.preparationProgress = item.progress }
                switch item.status {
                case .available:
                    // Retain the server item until a native slot is free.
                    // Poll again after waiting so expired files are noticed.
                    if occupiedTransferSlots < preferences.maximumActiveDownloads.rawValue {
                        let prepared = try await plexService.preparedDownload(
                            context: pollContext, queueID: queueID, itemID: itemID, sourceMedia: sourceMedia
                        )
                        try checkPreparation(record)
                        // Another preparation may have claimed the last slot
                        // while the decision request was in flight.
                        if occupiedTransferSlots < preferences.maximumActiveDownloads.rawValue { return prepared }
                    }
                case .expired:
                    throw PlexDownloadQueueError.expired
                case .error:
                    throw PlexDownloadQueueError.preparationFailed(item.error ?? "Plex could not prepare this quality. Try Original or check server transcoding permissions.")
                case .deciding, .waiting, .processing:
                    break
                }
                try await Task.sleep(for: .seconds(2))
            }
        } catch PlexDownloadQueueError.expired {
            try checkPreparation(record)
            guard resetExpiredPreparation(globalKey: record.globalKey) else { throw PlexDownloadQueueError.expired }
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
            clientIdentifier: clientID, ratingKey: record.ratingKey,
            queueID: record.plexDownloadQueueID, itemID: record.plexDownloadItemID))
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
                    serverID: removal.serverID, ratingKey: removal.ratingKey)
                guard self.preparationTasks[globalKey] == nil,
                      removal.profileID == self.plexService.activeProfileID,
                      let context = try? self.plexService.captureDownloadQueueContext(
                        serverID: removal.serverID, profileID: removal.profileID, clientIdentifier: removal.clientIdentifier
                      ) else { continue }
                do {
                    let queueID: String
                    if let existing = removal.queueID { queueID = existing }
                    else { queueID = try await self.plexService.createDownloadQueue(context: context) }
                    if let itemID = removal.itemID {
                        try await self.plexService.removeDownloadQueueItem(context: context, queueID: queueID, itemID: itemID)
                    } else {
                        // Covers cancellation/termination after PMS accepted add
                        // but before its response could be persisted.
                        let items = try await self.plexService.downloadQueueItems(context: context, queueID: queueID)
                        for item in items where item.key == "/library/metadata/\(removal.ratingKey)" {
                            try await self.plexService.removeDownloadQueueItem(context: context, queueID: queueID, itemID: item.id)
                        }
                    }
                    self.pendingQueueRemovals.removeAll { $0 == removal }
                    self.persist()
                } catch PlexDownloadQueueError.expired {
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
                    ratingKey: record.ratingKey
                  ) else {
                throw PlexServiceError.decodingError("Cached metadata missing for \(record.title)")
            }

            let media = record.downloadQuality != .original ? record.convertedMedia
                : (details.media.first(where: { $0.id == record.mediaID })
                    ?? StreamResolver.selectMediaVersion(from: details.media, preferredMaxResolution: preferences.downloadMaxResolution))
            guard let media,
                  let part = media.parts.first(where: { $0.id == record.partID }) ?? media.parts.first else {
                throw PlexServiceError.decodingError("Cached media part missing for \(record.title)")
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
            if record.accountProfileID == plexService.activeProfileID, plexService.isSessionReady {
                await cacheArtwork(for: details, serverID: record.serverID)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
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
        ratingKey: String,
        serverID: String
    ) async throws -> PlexMediaDetails {
        guard !isProfileSwitching,
              let accountProfileID = plexService.activeProfileID?.nilIfEmpty else {
            throw PlexServiceError.noServerConnected
        }

        let data = try await plexService.getMediaDetailsPayload(ratingKey: ratingKey, serverID: serverID)
        guard !Task.isCancelled,
              !isProfileSwitching,
              plexService.activeProfileID == accountProfileID else {
            throw CancellationError()
        }
        try metadataCache.storePayload(
            data,
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: PlexMetadataCache.metadataEndpoint(ratingKey)
        )
        let response = try plexService.decodeJSON(
            MetadataResponse<PlexMediaDetails>.self,
            from: data,
            serverID: serverID
        )
        guard let details = response.MediaContainer.Metadata?.first else {
            throw PlexServiceError.decodingError("No metadata found for \(ratingKey)")
        }
        await cacheArtwork(for: details, serverID: serverID)
        return details
    }

    @discardableResult
    private func fetchAndCacheChildren(ratingKey: String, serverID: String) async throws -> Data {
        guard !isProfileSwitching,
              let accountProfileID = plexService.activeProfileID?.nilIfEmpty else {
            throw PlexServiceError.noServerConnected
        }

        let data = try await plexService.getChildrenPayload(ratingKey: ratingKey, serverID: serverID)
        guard !Task.isCancelled,
              !isProfileSwitching,
              plexService.activeProfileID == accountProfileID else {
            throw CancellationError()
        }
        try metadataCache.storePayload(
            data,
            accountProfileID: accountProfileID,
            serverID: serverID,
            endpoint: PlexMetadataCache.childrenEndpoint(ratingKey)
        )
        return data
    }

    private func fetchAndCacheChildren<T: Decodable>(
        _ type: T.Type,
        ratingKey: String,
        serverID: String
    ) async throws -> [T] {
        let data = try await fetchAndCacheChildren(ratingKey: ratingKey, serverID: serverID)
        let response = try plexService.decodeJSON(
            MetadataResponse<T>.self,
            from: data,
            serverID: serverID
        )
        return response.MediaContainer.Metadata ?? []
    }

    private func cacheEpisodeContext(_ details: PlexMediaDetails, serverID: String) async throws {
        if let seasonKey = details.parentRatingKey {
            _ = try? await fetchAndCacheDetails(ratingKey: seasonKey, serverID: serverID)
            if let episodes = try? await fetchAndCacheChildren(
                PlexEpisode.self,
                ratingKey: seasonKey,
                serverID: serverID
            ) {
                await cacheArtwork(for: episodes, serverID: serverID)
            }
        }

        if let showKey = details.grandparentRatingKey {
            _ = try? await fetchAndCacheDetails(ratingKey: showKey, serverID: serverID)
            if let seasons = try? await fetchAndCacheChildren(
                PlexSeason.self,
                ratingKey: showKey,
                serverID: serverID
            ) {
                await cacheArtwork(for: seasons, serverID: serverID)
            }
        }
    }

    private func cacheArtwork(for details: PlexMediaDetails, serverID: String) async {
        let expectedProfileID = plexService.activeProfileID
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

    private func cacheArtwork(for seasons: [PlexSeason], serverID: String) async {
        let expectedProfileID = plexService.activeProfileID
        await cacheArtwork(paths: seasons.flatMap { season in
            [
                season.thumb,
                season.art,
                season.parentThumb,
            ].compactMap { $0 }
        }, serverID: serverID, expectedProfileID: expectedProfileID)
    }

    private func cacheArtwork(for episodes: [PlexEpisode], serverID: String) async {
        let expectedProfileID = plexService.activeProfileID
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
                  plexService.activeProfileID == expectedProfileID,
                  let targetURL = fileStore.artworkURL(for: path),
                  !FileManager.default.fileExists(atPath: targetURL.path),
                  let sourceURL = plexService.imageURL(
                      for: path,
                      serverID: serverID,
                      width: width,
                      height: height
                  ) else {
                continue
            }

            do {
                let data = try await plexService.imageData(for: sourceURL)
                guard !isProfileSwitching,
                      plexService.activeProfileID == expectedProfileID else {
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

    private func validateAvailableStorage(for part: PlexMediaPart) throws {
        let expectedSize = max(0, part.size.map(Int64.init) ?? 0)
        guard let availableBytes = fileStore.availableStorageBytes() else {
            return
        }

        let reserveBytes = preferences.downloadFreeSpaceReserve.bytes
        if availableBytes - expectedSize < reserveBytes {
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

    private func subtitle(for details: PlexMediaDetails) -> String? {
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
            return details.year.map(String.init)
        default:
            return nil
        }
    }

    private func relatedRecords(for scope: DownloadScope) -> [DownloadedMediaRecord] {
        let ownRecords = records.filter {
            $0.ratingKey == scope.ratingKey && matchesServer($0, of: scope.id)
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
            update(globalKey: globalKey) { item in
                item.status = .paused
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
            Task {
                await completeDownload(
                    globalKey: globalKey,
                    taskIdentifier: taskIdentifier,
                    temporaryURL: temporaryURL,
                    response: response
                )
                finishProfileSuspension(taskIdentifier: taskIdentifier)
            }
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
        let activeProfileID = plexService.activeProfileID
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

            if storedRecords[recordIndex].accountProfileID == activeProfileID,
               plexService.isSessionReady {
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

            if storedRecords[index].accountProfileID == activeProfileID,
               plexService.isSessionReady {
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
                ratingKey: record.ratingKey
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

        if let plexError = error as? PlexServiceError {
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

    private func upsertFailedPlaceholder(id: PlexItemID, type: PlexMediaType, isClip: Bool = false, quality: DownloadQuality = .original, error: Error) {
        guard let accountProfileID = plexService.activeProfileID?.nilIfEmpty,
              let serverID = try? downloadServerID(for: id) else {
            return
        }
        let ratingKey = id.ratingKey
        let placeholder = DownloadedMediaRecord(
            accountProfileID: accountProfileID,
            serverID: serverID,
            serverName: serverName(for: serverID),
            ratingKey: ratingKey,
            type: type,
            isClip: isClip || type == .clip,
            title: cachedMediaDetails(for: PlexItemID(serverID: serverID, ratingKey: ratingKey))?.title ?? "Download",
            subtitle: nil,
            parentRatingKey: nil,
            parentTitle: nil,
            grandparentRatingKey: nil,
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
        guard constrained != isNetworkConstrained else { return }
        isNetworkConstrained = constrained
        evaluateNetworkConstraints()
    }

    private func removeAggregatePlaceholder(for scope: DownloadScope) {
        guard scope.type == .season || scope.type == .show else { return }
        let activeProfileID = plexService.activeProfileID
        let originalCount = storedRecords.count
        storedRecords.removeAll {
            $0.accountProfileID == activeProfileID
                && $0.ratingKey == scope.ratingKey
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

    private func persist() {
        try? fileStore.saveSnapshot(DownloadStoreSnapshot(records: storedRecords, pendingQueueRemovals: pendingQueueRemovals))
    }
}

#if DEBUG
extension DownloadManager {
    /// Screenshot mode only (`ScreenshotMode`): records a movie, an episode or
    /// every episode of a season as a finished download. Metadata and artwork
    /// go through the normal cache path; the video is a tiny placeholder,
    /// extended (sparse) to the part's size so the launch-time file check
    /// keeps the record.
    func seedCompletedDownloadForScreenshot(id: PlexItemID, type: PlexMediaType) async {
        guard let serverID = id.serverID,
              plexService.isSessionReady,
              let accountProfileID = plexService.activeProfileID?.nilIfEmpty else { return }

        do {
            if type == .season {
                let episodes = try await fetchAndCacheChildren(
                    PlexEpisode.self,
                    ratingKey: id.ratingKey,
                    serverID: serverID
                )
                for episode in episodes {
                    await seedCompletedDownloadForScreenshot(
                        id: PlexItemID(serverID: serverID, ratingKey: episode.ratingKey),
                        type: .episode
                    )
                }
                return
            }

            guard record(for: id)?.status != .completed else { return }
            let details = try await fetchAndCacheDetails(ratingKey: id.ratingKey, serverID: serverID)
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
                ratingKey: id.ratingKey,
                type: details.type,
                isClip: details.isClip,
                title: details.title,
                subtitle: subtitle(for: details),
                parentRatingKey: details.parentRatingKey,
                parentTitle: nil,
                grandparentRatingKey: details.grandparentRatingKey,
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
            print("Screenshot download seed failed for \(id.ratingKey): \(error)")
        }
    }
}
#endif
