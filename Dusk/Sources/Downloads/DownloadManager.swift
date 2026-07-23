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
        reconcileCompletedFiles()
        _ = transferController
        startNetworkMonitoring()
        Task { [weak self] in
            await self?.reconcileExistingTransfers()
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
        let grouped = Dictionary(grouping: downloadedEpisodes) { record in
            record.grandparentRatingKey ?? record.parentRatingKey ?? record.ratingKey
        }

        return grouped.compactMap { showKey, episodes -> DownloadedShowSummary? in
            guard let first = episodes.first,
                  let accountProfileID = first.accountProfileID else {
                return nil
            }
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

    func record(for ratingKey: String) -> DownloadedMediaRecord? {
        records.first { $0.ratingKey == ratingKey }
    }

    func serverID(for ratingKey: String) -> String? {
        record(for: ratingKey)?.serverID
    }

    func canPause(ratingKey: String) -> Bool {
        record(for: ratingKey)?.status.canPause == true
    }

    func canResume(ratingKey: String) -> Bool {
        record(for: ratingKey)?.status.canResume == true
    }

    func status(for ratingKey: String) -> DownloadStatus? {
        record(for: ratingKey)?.status
    }

    func status(for ratingKey: String, type: PlexMediaType) -> DownloadStatus? {
        downloadState(for: DownloadScope(ratingKey: ratingKey, type: type)).status
    }

    func progress(for ratingKey: String) -> Double? {
        record(for: ratingKey)?.progress
    }

    func progress(for ratingKey: String, type: PlexMediaType) -> Double? {
        let state = downloadState(for: DownloadScope(ratingKey: ratingKey, type: type))
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

    func isDownloaded(ratingKey: String) -> Bool {
        record(for: ratingKey)?.status == .completed
    }

    func isDeletingDownload(ratingKey: String) -> Bool {
        guard let record = record(for: ratingKey) else { return false }
        return deletingDownloadIDs.contains(record.globalKey)
    }

    func isDeletingDownload(ratingKey: String, type: PlexMediaType) -> Bool {
        downloadState(for: DownloadScope(ratingKey: ratingKey, type: type)).isDeleting
    }

    func isDeletingDownloads(showKey: String) -> Bool {
        records
            .filter { $0.grandparentRatingKey == showKey || $0.parentRatingKey == showKey }
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

    func isPlayableOffline(ratingKey: String) -> Bool {
        localPlaybackURL(for: ratingKey) != nil
    }

    func hasDownloadedEpisodes(showKey: String) -> Bool {
        downloadedEpisodes.contains { $0.grandparentRatingKey == showKey || $0.parentRatingKey == showKey }
    }

    func hasDownloadedEpisodes(seasonKey: String) -> Bool {
        downloadedEpisodes.contains { $0.parentRatingKey == seasonKey }
    }

    func downloadedEpisodeCount(seasonKey: String) -> Int {
        downloadedEpisodes.filter { $0.parentRatingKey == seasonKey }.count
    }

    func downloadedEpisodeCount(showKey: String) -> Int {
        downloadedEpisodes.filter { $0.grandparentRatingKey == showKey }.count
    }

    func downloadedEpisodeKeys(seasonKey: String) -> Set<String> {
        Set(downloadedEpisodes.filter { $0.parentRatingKey == seasonKey }.map(\.ratingKey))
    }

    func queueDownload(ratingKey: String, type: PlexMediaType, isClip: Bool = false) async {
        do {
            switch type {
            case .movie, .episode, .clip:
                try await queueSingleDownload(ratingKey: ratingKey, type: type, isClip: isClip)
            case .season:
                try await queueSeasonDownload(seasonKey: ratingKey)
            case .show:
                try await queueShowDownload(showKey: ratingKey)
            default:
                break
            }
            removeAggregatePlaceholder(for: DownloadScope(ratingKey: ratingKey, type: type))
            processQueueIfNeeded()
        } catch {
            guard !(error is CancellationError) else { return }
            upsertFailedPlaceholder(ratingKey: ratingKey, type: type, isClip: isClip, error: error)
        }
    }

    func queueDownload(episode: PlexEpisode) async {
        do {
            try await queueEpisodeDownload(episode)
            processQueueIfNeeded()
        } catch {
            guard !(error is CancellationError) else { return }
            upsertFailedPlaceholder(ratingKey: episode.ratingKey, type: .episode, error: error)
        }
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
            pauseDownload(ratingKey: record.ratingKey, forProfileSwitch: true)
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

    func retryDownload(ratingKey: String) {
        guard let index = activeRecordIndex(ratingKey: ratingKey) else { return }
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

    func pauseDownload(ratingKey: String) {
        pauseDownload(ratingKey: ratingKey, forProfileSwitch: false)
    }

    private func pauseDownload(ratingKey: String, forProfileSwitch: Bool) {
        guard let index = activeRecordIndex(ratingKey: ratingKey),
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

    func pauseDownload(ratingKey: String, type: PlexMediaType) {
        pauseDownload(scope: DownloadScope(ratingKey: ratingKey, type: type))
    }

    func pauseDownload(scope: DownloadScope) {
        performOnRelatedRecords(scope) { record in
            guard record.status.canPause else { return }
            pauseDownload(ratingKey: record.ratingKey)
        }
    }

    func resumeDownload(ratingKey: String) {
        guard let index = activeRecordIndex(ratingKey: ratingKey),
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

    func resumeDownload(ratingKey: String, type: PlexMediaType) {
        resumeDownload(scope: DownloadScope(ratingKey: ratingKey, type: type))
    }

    func resumeDownload(scope: DownloadScope) {
        performOnRelatedRecords(scope) { record in
            guard record.status.canResume else { return }
            resumeDownload(ratingKey: record.ratingKey)
        }
    }

    func cancelDownload(ratingKey: String) {
        guard let record = record(for: ratingKey),
              record.status != .completed else {
            return
        }
        deleteRecords([record])
    }

    func cancelDownload(ratingKey: String, type: PlexMediaType) {
        cancelDownload(scope: DownloadScope(ratingKey: ratingKey, type: type))
    }

    func cancelDownload(scope: DownloadScope) {
        performOnRelatedRecords(scope) { record in
            cancelDownload(ratingKey: record.ratingKey)
        }
    }

    func pauseAllDownloads() {
        isQueuePaused = true
        let pausableRatingKeys = records
            .filter { $0.status.canPause && !deletingDownloadIDs.contains($0.globalKey) }
            .map(\.ratingKey)
        for ratingKey in pausableRatingKeys {
            pauseDownload(ratingKey: ratingKey)
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

    func deleteDownload(ratingKey: String) {
        guard let record = record(for: ratingKey) else { return }
        deleteRecords([record])
    }

    func deleteDownload(ratingKey: String, type: PlexMediaType) {
        deleteDownload(scope: DownloadScope(ratingKey: ratingKey, type: type))
    }

    func deleteDownload(scope: DownloadScope) {
        deleteRecords(relatedRecords(for: scope))
    }

    func deleteDownloads(showKey: String) {
        deleteDownload(scope: DownloadScope(ratingKey: showKey, type: .show))
    }

    func deleteAllDownloads() {
        deleteRecords(records)
    }

    func localPlaybackURL(for ratingKey: String, selectedMediaID: Int? = nil) -> URL? {
        guard let record = record(for: ratingKey),
              record.status == .completed,
              selectedMediaID == nil || selectedMediaID == record.mediaID else {
            return nil
        }
        return fileStore.existingFileURL(for: record.relativeVideoPath)
    }

    func downloadedMediaVersion(
        for ratingKey: String,
        in details: PlexMediaDetails,
        selectedMediaID: Int? = nil
    ) -> (media: PlexMedia, part: PlexMediaPart)? {
        guard let record = record(for: ratingKey),
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

    func cachedMediaDetails(ratingKey: String) -> PlexMediaDetails? {
        guard let accountProfileID = plexService.activeProfileID?.nilIfEmpty else { return nil }
        return metadataCache.firstCachedMediaDetails(
            accountProfileID: accountProfileID,
            ratingKey: ratingKey,
            serverIDs: preferredServerIDs
        )
    }

    func cachedSeasons(showKey: String) -> [PlexSeason]? {
        guard let accountProfileID = plexService.activeProfileID?.nilIfEmpty else { return nil }
        return metadataCache.firstCachedSeasons(
            accountProfileID: accountProfileID,
            showKey: showKey,
            serverIDs: preferredServerIDs
        )
    }

    func cachedEpisodes(seasonKey: String) -> [PlexEpisode]? {
        guard let accountProfileID = plexService.activeProfileID?.nilIfEmpty else { return nil }
        return metadataCache.firstCachedEpisodes(
            accountProfileID: accountProfileID,
            seasonKey: seasonKey,
            serverIDs: preferredServerIDs
        )
    }

    func cachedNextDownloadedEpisode(after episode: PlexMediaDetails) -> PlexEpisode? {
        guard episode.type == .episode,
              let seasonKey = episode.parentRatingKey,
              let showKey = episode.grandparentRatingKey else {
            return nil
        }

        let currentSeasonEpisodes = (cachedEpisodes(seasonKey: seasonKey) ?? [])
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

        if let currentEpisodeIndex = currentSeasonEpisodes.firstIndex(where: { $0.ratingKey == episode.ratingKey }) {
            let remainingEpisodes = currentSeasonEpisodes[currentSeasonEpisodes.index(after: currentEpisodeIndex)...]
            if let nextDownloadedEpisode = remainingEpisodes.first(where: { isPlayableOffline(ratingKey: $0.ratingKey) }) {
                return nextDownloadedEpisode
            }
        } else if let currentEpisodeNumber = episode.index,
                  let nextDownloadedEpisode = currentSeasonEpisodes.first(where: {
                      ($0.index ?? 0) > currentEpisodeNumber
                      && isPlayableOffline(ratingKey: $0.ratingKey)
                  }) {
            return nextDownloadedEpisode
        }

        let seasons = (cachedSeasons(showKey: showKey) ?? [])
            .sorted { $0.index < $1.index }
        let currentSeasonIndex = episode.parentIndex
            ?? seasons.first(where: { $0.ratingKey == seasonKey })?.index

        guard let currentSeasonIndex else { return nil }

        for season in seasons where season.index > currentSeasonIndex {
            let episodes = (cachedEpisodes(seasonKey: season.ratingKey) ?? [])
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            if let firstDownloadedEpisode = episodes.first(where: { isPlayableOffline(ratingKey: $0.ratingKey) }) {
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

    private var preferredServerIDs: [String] {
        var ids: [String] = []
        if let currentServerID {
            ids.append(currentServerID)
        }
        for id in records.map(\.serverID) where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    private var currentServerID: String? {
        if let id = plexService.connectedServer?.clientIdentifier.nilIfEmpty {
            return id
        }
        return plexService.serverBaseURL?.absoluteString.nilIfEmpty
    }

    private var currentServerName: String? {
        plexService.connectedServer?.name
    }

    private func queueSingleDownload(ratingKey: String, type: PlexMediaType, isClip: Bool = false) async throws {
        guard type == .movie || type == .episode || type == .clip else { return }
        guard !isProfileSwitching,
              plexService.isSessionReady,
              let accountProfileID = plexService.activeProfileID?.nilIfEmpty else {
            throw PlexServiceError.notAuthenticated
        }
        guard let serverID = currentServerID else {
            throw PlexServiceError.noServerConnected
        }

        if let existing = record(for: ratingKey),
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
            serverName: currentServerName,
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
        guard let serverID = currentServerID else {
            throw PlexServiceError.noServerConnected
        }

        if let existing = record(for: episode.ratingKey),
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
            serverName: currentServerName,
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

    private func queueSeasonDownload(seasonKey: String) async throws {
        let seasonDetails = try await fetchAndCacheDetails(ratingKey: seasonKey)
        if let showKey = seasonDetails.parentRatingKey {
            _ = try? await fetchAndCacheDetails(ratingKey: showKey)
            if let seasons = try? await fetchAndCacheChildren(PlexSeason.self, ratingKey: showKey) {
                await cacheArtwork(for: seasons)
            }
        }

        let episodes = try await fetchAndCacheChildren(PlexEpisode.self, ratingKey: seasonKey)
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        await cacheArtwork(for: episodes)

        for episode in episodes {
            try await queueSingleDownload(ratingKey: episode.ratingKey, type: .episode)
        }
    }

    private func queueShowDownload(showKey: String) async throws {
        _ = try await fetchAndCacheDetails(ratingKey: showKey)
        let seasons = try await fetchAndCacheChildren(PlexSeason.self, ratingKey: showKey)
            .sorted { $0.index < $1.index }
        await cacheArtwork(for: seasons)

        for season in seasons {
            try await queueSeasonDownload(seasonKey: season.ratingKey)
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
              plexService.isConnected,
              plexService.activeProfileID?.nilIfEmpty != nil,
              !isProfileSwitching,
              !isQueuePaused,
              activeDownloadCount < preferences.maximumActiveDownloads.rawValue else {
            return
        }

        while plexService.isSessionReady,
              plexService.isConnected,
              !isProfileSwitching,
              !isQueuePaused,
              activeDownloadCount < preferences.maximumActiveDownloads.rawValue,
              let next = records.first(where: { $0.status == .queued && !deletingDownloadIDs.contains($0.globalKey) }) {
            await startDownload(record: next)
        }
    }

    private func startDownload(record: DownloadedMediaRecord) async {
        guard !Task.isCancelled,
              record.accountProfileID == plexService.activeProfileID,
              plexService.isSessionReady,
              plexService.isConnected else {
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
                details = try await fetchAndCacheDetails(ratingKey: record.ratingKey)
            }

            guard !Task.isCancelled,
                  record.accountProfileID == plexService.activeProfileID,
                  plexService.isSessionReady,
                  plexService.isConnected else {
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
                try await cacheEpisodeContext(details)
            }

            guard !Task.isCancelled,
                  !isProfileSwitching,
                  record.accountProfileID == plexService.activeProfileID,
                  plexService.isSessionReady,
                  plexService.isConnected else {
                throw CancellationError()
            }

            let media = details.media.first(where: { $0.id == record.mediaID })
                ?? StreamResolver.selectMediaVersion(from: details.media, preferredMaxResolution: preferences.downloadMaxResolution)
            guard let media,
                  let part = media.parts.first(where: { $0.id == record.partID }) ?? media.parts.first else {
                throw PlexServiceError.decodingError("Cached media part missing for \(record.title)")
            }

            guard let sourceURL = plexService.directPlayURL(for: part) else {
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
            plexService.applyHeaders(to: &request, token: plexService.preferredServerToken)
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
                await cacheArtwork(for: details)
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

    private func fetchAndCacheDetails(ratingKey: String) async throws -> PlexMediaDetails {
        guard !isProfileSwitching,
              let accountProfileID = plexService.activeProfileID?.nilIfEmpty,
              let serverID = currentServerID else {
            throw PlexServiceError.noServerConnected
        }

        let data = try await plexService.getMediaDetailsPayload(ratingKey: ratingKey)
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
        let response = try plexService.decodeJSON(MetadataResponse<PlexMediaDetails>.self, from: data)
        guard let details = response.MediaContainer.Metadata?.first else {
            throw PlexServiceError.decodingError("No metadata found for \(ratingKey)")
        }
        await cacheArtwork(for: details)
        return details
    }

    @discardableResult
    private func fetchAndCacheChildren(ratingKey: String) async throws -> Data {
        guard !isProfileSwitching,
              let accountProfileID = plexService.activeProfileID?.nilIfEmpty,
              let serverID = currentServerID else {
            throw PlexServiceError.noServerConnected
        }

        let data = try await plexService.getChildrenPayload(ratingKey: ratingKey)
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

    private func fetchAndCacheChildren<T: Decodable>(_ type: T.Type, ratingKey: String) async throws -> [T] {
        let data = try await fetchAndCacheChildren(ratingKey: ratingKey)
        let response = try plexService.decodeJSON(MetadataResponse<T>.self, from: data)
        return response.MediaContainer.Metadata ?? []
    }

    private func cacheEpisodeContext(_ details: PlexMediaDetails) async throws {
        if let seasonKey = details.parentRatingKey {
            _ = try? await fetchAndCacheDetails(ratingKey: seasonKey)
            if let episodes = try? await fetchAndCacheChildren(PlexEpisode.self, ratingKey: seasonKey) {
                await cacheArtwork(for: episodes)
            }
        }

        if let showKey = details.grandparentRatingKey {
            _ = try? await fetchAndCacheDetails(ratingKey: showKey)
            if let seasons = try? await fetchAndCacheChildren(PlexSeason.self, ratingKey: showKey) {
                await cacheArtwork(for: seasons)
            }
        }
    }

    private func cacheArtwork(for details: PlexMediaDetails) async {
        let expectedProfileID = plexService.activeProfileID
        // A clip's thumb and art are 16:9 frame grabs; requesting the poster
        // box would crop them server-side before they ever reach the cache.
        if details.isClip {
            await cacheArtwork(
                paths: [details.thumb, details.art].compactMap { $0 },
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
            expectedProfileID: expectedProfileID
        )
    }

    private func cacheArtwork(for seasons: [PlexSeason]) async {
        let expectedProfileID = plexService.activeProfileID
        await cacheArtwork(paths: seasons.flatMap { season in
            [
                season.thumb,
                season.art,
                season.parentThumb,
            ].compactMap { $0 }
        }, expectedProfileID: expectedProfileID)
    }

    private func cacheArtwork(for episodes: [PlexEpisode]) async {
        let expectedProfileID = plexService.activeProfileID
        await cacheArtwork(paths: episodes.flatMap { episode in
            [
                episode.thumb,
                episode.art,
                episode.grandparentThumb,
            ].compactMap { $0 }
        }, expectedProfileID: expectedProfileID)
    }

    private func cacheArtwork(
        paths: [String],
        width: Int = 900,
        height: Int = 1350,
        expectedProfileID: String?
    ) async {
        for path in Set(paths) {
            guard !isProfileSwitching,
                  plexService.activeProfileID == expectedProfileID,
                  let targetURL = fileStore.artworkURL(for: path),
                  !FileManager.default.fileExists(atPath: targetURL.path),
                  let sourceURL = plexService.imageURL(for: path, width: width, height: height) else {
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
        switch scope.type {
        case .season:
            let episodeRecords = records.filter {
                $0.type == .episode && $0.parentRatingKey == scope.ratingKey
            }
            return episodeRecords.isEmpty ? records.filter { $0.ratingKey == scope.ratingKey } : episodeRecords
        case .show:
            let episodeRecords = records.filter {
                $0.type == .episode && ($0.grandparentRatingKey == scope.ratingKey || $0.parentRatingKey == scope.ratingKey)
            }
            return episodeRecords.isEmpty ? records.filter { $0.ratingKey == scope.ratingKey } : episodeRecords
        default:
            return records.filter { $0.ratingKey == scope.ratingKey }
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

    private func activeRecordIndex(ratingKey: String) -> Int? {
        let activeProfileID = plexService.activeProfileID
        return storedRecords.firstIndex {
            $0.accountProfileID == activeProfileID && $0.ratingKey == ratingKey
        }
    }

    private func update(_ ratingKey: String, mutate: (inout DownloadedMediaRecord) -> Void) {
        guard let index = activeRecordIndex(ratingKey: ratingKey) else { return }
        mutate(&storedRecords[index])
        persist()
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

    private func upsertFailedPlaceholder(ratingKey: String, type: PlexMediaType, isClip: Bool = false, error: Error) {
        guard let accountProfileID = plexService.activeProfileID?.nilIfEmpty,
              let serverID = currentServerID else {
            return
        }
        let placeholder = DownloadedMediaRecord(
            accountProfileID: accountProfileID,
            serverID: serverID,
            serverName: currentServerName,
            ratingKey: ratingKey,
            type: type,
            isClip: isClip || type == .clip,
            title: cachedMediaDetails(ratingKey: ratingKey)?.title ?? "Download",
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
