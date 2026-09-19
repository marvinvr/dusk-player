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
        storedRecords = fileStore.loadSnapshot().records
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

    func queueDownload(id: PlexItemID, type: PlexMediaType, isClip: Bool = false) async {
        do {
            switch type {
            case .movie, .episode, .clip:
                try await queueSingleDownload(id: id, type: type, isClip: isClip)
            case .season:
                try await queueSeasonDownload(season: id)
            case .show:
                try await queueShowDownload(show: id)
            default:
                break
            }
            removeAggregatePlaceholder(for: DownloadScope(id: id, type: type))
            processQueueIfNeeded()
        } catch {
            guard !(error is CancellationError) else { return }
            upsertFailedPlaceholder(id: id, type: type, isClip: isClip, error: error)
        }
    }

    func queueDownload(episode: PlexEpisode) async {
        do {
            try await queueEpisodeDownload(episode)
            processQueueIfNeeded()
        } catch {
            guard !(error is CancellationError) else { return }
            upsertFailedPlaceholder(id: episode.id, type: .episode, error: error)
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
            && storedRecords[index].wasPausedForProfileSwitch {
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
              selectedMediaID == nil || selectedMediaID == record.mediaID,
              let mediaID = record.mediaID,
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

    private func queueSingleDownload(id: PlexItemID, type: PlexMediaType, isClip: Bool = false) async throws {
        guard type == .movie || type == .episode || type == .clip else { return }
        guard !isProfileSwitching,
              plexService.isSessionReady,
              let accountProfileID = plexService.activeProfileID?.nilIfEmpty else {
            throw PlexServiceError.notAuthenticated
        }
        let serverID = try downloadServerID(for: id)
        let ratingKey = id.ratingKey

        if let existing = record(for: PlexItemID(serverID: serverID, ratingKey: ratingKey)),
           existing.status == .completed || existing.status.isActive {
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

    private func queueEpisodeDownload(_ episode: PlexEpisode) async throws {
        guard !isProfileSwitching,
              plexService.isSessionReady,
              let accountProfileID = plexService.activeProfileID?.nilIfEmpty else {
            throw PlexServiceError.notAuthenticated
        }
        let serverID = try downloadServerID(for: episode.id)

        if let existing = record(for: PlexItemID(serverID: serverID, ratingKey: episode.ratingKey)),
           existing.status == .completed || existing.status.isActive {
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
    private func queueSeasonDownload(season: PlexItemID) async throws {
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
            try await queueSingleDownload(
                id: PlexItemID(serverID: serverID, ratingKey: episode.ratingKey),
                type: .episode
            )
        }
    }

    private func queueShowDownload(show: PlexItemID) async throws {
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
            try await queueSeasonDownload(
                season: PlexItemID(serverID: serverID, ratingKey: season.ratingKey)
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

        guard plexService.isSessionReady,
              plexService.activeProfileID?.nilIfEmpty != nil,
              !isProfileSwitching,
              !isQueuePaused,
              activeDownloadCount < preferences.maximumActiveDownloads.rawValue else {
            return
        }

        // A record whose server is offline or switched off is not an error: it
        // stays queued (and its completed siblings stay playable) until that
        // server connects again, which re-runs the queue.
        while plexService.isSessionReady,
              !isProfileSwitching,
              !isQueuePaused,
              activeDownloadCount < preferences.maximumActiveDownloads.rawValue,
              let next = records.first(where: {
                  $0.status == .queued
                      && !deletingDownloadIDs.contains($0.globalKey)
                      && isServerConnected($0.serverID)
              }) {
            await startDownload(record: next)
        }
    }

    private func isServerConnected(_ serverID: String) -> Bool {
        plexService.pool.connection(for: serverID) != nil
    }

    private func startDownload(record: DownloadedMediaRecord) async {
        guard !Task.isCancelled,
              record.accountProfileID == plexService.activeProfileID,
              plexService.isSessionReady,
              let connection = plexService.pool.connection(for: record.serverID) else {
            return
        }
        update(globalKey: record.globalKey) { item in
            item.status = .preparing
            item.errorMessage = nil
            item.updatedAt = .now
        }

        do {
            let details: PlexMediaDetails
            if let accountProfileID = record.accountProfileID,
               let cachedDetails = metadataCache.mediaDetails(
                    accountProfileID: accountProfileID,
                    serverID: record.serverID,
                    ratingKey: record.ratingKey
               ) {
                details = cachedDetails
            } else {
                details = try await fetchAndCacheDetails(
                    ratingKey: record.ratingKey,
                    serverID: record.serverID
                )
            }

            guard !Task.isCancelled,
                  record.accountProfileID == plexService.activeProfileID,
                  plexService.isSessionReady,
                  isServerConnected(record.serverID) else {
                update(globalKey: record.globalKey) { item in
                    item.status = .queued
                    item.downloadTaskIdentifier = nil
                    item.updatedAt = .now
                }
                return
            }

            guard details.type == .movie || details.type == .episode || details.type == .clip else {
                throw PlexServiceError.decodingError("Downloads are only supported for movies, episodes, and videos.")
            }

            if details.type == .episode {
                try await cacheEpisodeContext(details, serverID: record.serverID)
            }

            guard !Task.isCancelled,
                  !isProfileSwitching,
                  record.accountProfileID == plexService.activeProfileID,
                  plexService.isSessionReady,
                  isServerConnected(record.serverID) else {
                throw CancellationError()
            }

            let media = details.media.first(where: { $0.id == record.mediaID })
                ?? StreamResolver.selectMediaVersion(from: details.media, preferredMaxResolution: preferences.downloadMaxResolution)
            guard let media,
                  let part = media.parts.first(where: { $0.id == record.partID }) ?? media.parts.first else {
                throw PlexServiceError.decodingError("Cached media part missing for \(record.title)")
            }

            guard let sourceURL = plexService.directPlayURL(for: part, serverID: record.serverID) else {
                throw PlexServiceError.invalidURL
            }

            guard let latestRecord = self.record(globalKey: record.globalKey),
                  latestRecord.status == .preparing,
                  !deletingDownloadIDs.contains(record.globalKey) else {
                return
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
                item.totalBytes = part.size.map(Int64.init) ?? item.totalBytes
                item.updatedAt = .now
            }

            guard let accountProfileID = record.accountProfileID else {
                throw PlexServiceError.notAuthenticated
            }
            _ = try fileStore.targetVideoURL(
                accountProfileID: accountProfileID,
                for: details,
                part: part
            )
            var request = URLRequest(url: sourceURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.allowsExpensiveNetworkAccess = !preferences.downloadsWifiOnly
            request.allowsConstrainedNetworkAccess = !preferences.downloadsWifiOnly
            // The token belongs to the record's own server; the primary one's
            // would be rejected (or, worse, accepted for a different title).
            plexService.applyHeaders(to: &request, token: connection.token)
            try validateAvailableStorage(for: part)

            let resumeData = fileStore.resumeData(relativePath: latestRecord.resumeDataPath)
            let taskIdentifier = transferController.start(
                request: request,
                resumeData: resumeData,
                globalKey: record.globalKey
            )

            if resumeData != nil {
                fileStore.deleteResumeData(relativePath: latestRecord.resumeDataPath)
            }

            update(globalKey: record.globalKey) { item in
                item.status = .downloading
                item.downloadTaskIdentifier = taskIdentifier
                item.resumeDataPath = nil
                item.totalBytes = part.size.map(Int64.init) ?? item.totalBytes
                item.updatedAt = .now
            }
        } catch {
            if error is CancellationError
                || isProfileSwitching
                || record.accountProfileID != plexService.activeProfileID {
                update(globalKey: record.globalKey) { item in
                    item.status = .queued
                    item.downloadTaskIdentifier = nil
                    item.updatedAt = .now
                }
                return
            }
            update(globalKey: record.globalKey) { item in
                item.status = .failed
                item.downloadTaskIdentifier = nil
                item.errorMessage = downloadErrorMessage(for: error)
                item.updatedAt = .now
            }
            processQueueIfNeeded()
        }
    }

    private func completeDownload(
        globalKey: String,
        taskIdentifier: Int,
        temporaryURL: URL,
        response: DownloadTransferResponse?
    ) async {
        guard let record = record(globalKey: globalKey) else {
            try? FileManager.default.removeItem(at: temporaryURL)
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

            let media = details.media.first(where: { $0.id == record.mediaID })
                ?? StreamResolver.selectMediaVersion(from: details.media, preferredMaxResolution: preferences.downloadMaxResolution)
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
            if record.accountProfileID == plexService.activeProfileID,
               plexService.isSessionReady {
                await cacheArtwork(for: details, serverID: record.serverID)
            }

            update(globalKey: globalKey) { item in
                item.status = .completed
                item.progress = 1
                item.downloadedBytes = item.totalBytes ?? item.downloadedBytes
                item.relativeVideoPath = fileStore.relativePath(for: targetURL)
                item.resumeDataPath = nil
                item.downloadTaskIdentifier = nil
                item.mediaID = media.id
                item.partID = part.id
                item.errorMessage = nil
                item.updatedAt = .now
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            update(globalKey: globalKey) { item in
                item.status = .failed
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
        guard let expectedSize = part.size.map(Int64.init),
              expectedSize > 0,
              let availableBytes = fileStore.availableStorageBytes() else {
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
            return record.globalKey
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

    private func upsertFailedPlaceholder(id: PlexItemID, type: PlexMediaType, isClip: Bool = false, error: Error) {
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
        try? fileStore.saveSnapshot(DownloadStoreSnapshot(records: storedRecords))
    }
}
