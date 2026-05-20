import Foundation
import Network
import Observation

private enum DownloadManagerError: LocalizedError {
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64, reserveBytes: Int64)

    var errorDescription: String? {
        switch self {
        case let .insufficientStorage(requiredBytes, availableBytes, reserveBytes):
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            let reserve = ByteCountFormatter.string(fromByteCount: reserveBytes, countStyle: .file)
            return "Not enough free storage. This download needs \(required), with \(available) available and \(reserve) reserved."
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

    private(set) var records: [DownloadedMediaRecord] = []
    private(set) var isProcessingQueue = false
    private(set) var isQueuePaused = false
    private(set) var deletingDownloadIDs: Set<String> = []

    private(set) var isNetworkConstrained = false

    @ObservationIgnored private var isNetworkPaused = false
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var networkMonitorQueue = DispatchQueue(label: "com.dusk.networkMonitor")
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var lastProgressPersistDates: [String: Date] = [:]
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
        records = fileStore.loadSnapshot().records
        pruneMissingCompletedFiles()
        _ = transferController
        startNetworkMonitoring()
        Task { [weak self] in
            await self?.reconcileExistingTransfers()
        }
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
            .filter { $0.type == .movie && $0.status == .completed }
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
            guard let first = episodes.first else { return nil }
            let serverID = first.serverID
            let cachedShow = metadataCache.mediaDetails(serverID: serverID, ratingKey: showKey)
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

    func queueDownload(ratingKey: String, type: PlexMediaType) async {
        do {
            switch type {
            case .movie, .episode:
                try await queueSingleDownload(ratingKey: ratingKey, type: type)
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
            upsertFailedPlaceholder(ratingKey: ratingKey, type: type, error: error)
        }
    }

    func queueDownload(episode: PlexEpisode) async {
        do {
            try await queueEpisodeDownload(episode)
            processQueueIfNeeded()
        } catch {
            upsertFailedPlaceholder(ratingKey: episode.ratingKey, type: .episode, error: error)
        }
    }

    func retryDownload(ratingKey: String) {
        guard let index = records.firstIndex(where: { $0.ratingKey == ratingKey }) else { return }
        fileStore.deleteResumeData(relativePath: records[index].resumeDataPath)
        records[index].status = .queued
        records[index].progress = 0
        records[index].downloadedBytes = 0
        records[index].resumeDataPath = nil
        records[index].downloadTaskIdentifier = nil
        records[index].errorMessage = nil
        records[index].updatedAt = .now
        persist()
        processQueueIfNeeded()
    }

    func pauseDownload(ratingKey: String) {
        guard let index = records.firstIndex(where: { $0.ratingKey == ratingKey }),
              records[index].status.canPause else {
            return
        }

        if let taskIdentifier = records[index].downloadTaskIdentifier {
            records[index].status = .paused
            records[index].updatedAt = .now
            persist()
            transferController.pause(taskIdentifier: taskIdentifier)
        } else {
            records[index].status = .paused
            records[index].downloadTaskIdentifier = nil
            records[index].updatedAt = .now
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
        guard let index = records.firstIndex(where: { $0.ratingKey == ratingKey }),
              records[index].status.canResume else {
            return
        }
        records[index].status = .queued
        records[index].downloadTaskIdentifier = nil
        records[index].errorMessage = nil
        records[index].updatedAt = .now
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
        for index in records.indices where records[index].status == .paused && !deletingDownloadIDs.contains(records[index].globalKey) {
            records[index].status = .queued
            records[index].downloadTaskIdentifier = nil
            records[index].errorMessage = nil
            records[index].updatedAt = .now
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
        let taskIdentifiers = records.compactMap(\.downloadTaskIdentifier)
        for taskIdentifier in taskIdentifiers {
            transferController.cancel(taskIdentifier: taskIdentifier)
        }

        records.removeAll()
        lastProgressPersistDates.removeAll()
        deletingDownloadIDs.removeAll()
        isQueuePaused = false
        fileStore.deleteAllStoredData()
        persist()
    }

    func localPlaybackURL(for ratingKey: String, selectedMediaID: Int? = nil) -> URL? {
        guard let record = record(for: ratingKey),
              record.status == .completed,
              selectedMediaID == nil || selectedMediaID == record.mediaID else {
            return nil
        }
        return fileStore.existingFileURL(for: record.relativeVideoPath)
    }

    func cachedMediaDetails(ratingKey: String) -> PlexMediaDetails? {
        metadataCache.firstCachedMediaDetails(ratingKey: ratingKey, serverIDs: preferredServerIDs)
    }

    func cachedSeasons(showKey: String) -> [PlexSeason]? {
        metadataCache.firstCachedSeasons(showKey: showKey, serverIDs: preferredServerIDs)
    }

    func cachedEpisodes(seasonKey: String) -> [PlexEpisode]? {
        metadataCache.firstCachedEpisodes(seasonKey: seasonKey, serverIDs: preferredServerIDs)
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

    private func queueSingleDownload(ratingKey: String, type: PlexMediaType) async throws {
        guard type == .movie || type == .episode else { return }
        guard let serverID = currentServerID else {
            throw PlexServiceError.noServerConnected
        }

        if let existing = record(for: ratingKey),
           existing.status == .completed || existing.status.isActive {
            return
        }

        let cachedDetails = metadataCache.mediaDetails(serverID: serverID, ratingKey: ratingKey)
        let record = DownloadedMediaRecord(
            serverID: serverID,
            serverName: currentServerName,
            ratingKey: ratingKey,
            type: cachedDetails?.type ?? type,
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
        guard let serverID = currentServerID else {
            throw PlexServiceError.noServerConnected
        }

        if let existing = record(for: episode.ratingKey),
           existing.status == .completed || existing.status.isActive {
            return
        }

        let cachedDetails = metadataCache.mediaDetails(serverID: serverID, ratingKey: episode.ratingKey)
        let record = DownloadedMediaRecord(
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

        guard !isQueuePaused,
              activeDownloadCount < preferences.maximumActiveDownloads.rawValue else {
            return
        }

        while !isQueuePaused,
              activeDownloadCount < preferences.maximumActiveDownloads.rawValue,
              let next = records.first(where: { $0.status == .queued && !deletingDownloadIDs.contains($0.globalKey) }) {
            await startDownload(record: next)
        }
    }

    private func startDownload(record: DownloadedMediaRecord) async {
        update(globalKey: record.globalKey) { item in
            item.status = .preparing
            item.errorMessage = nil
            item.updatedAt = .now
        }

        do {
            let details: PlexMediaDetails
            if let cachedDetails = metadataCache.mediaDetails(serverID: record.serverID, ratingKey: record.ratingKey) {
                details = cachedDetails
            } else {
                details = try await fetchAndCacheDetails(ratingKey: record.ratingKey)
            }

            guard details.type == .movie || details.type == .episode else {
                throw PlexServiceError.decodingError("Downloads are only supported for movies and episodes.")
            }

            if details.type == .episode {
                try await cacheEpisodeContext(details)
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

            _ = try fileStore.targetVideoURL(for: details, part: part)
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
            update(globalKey: record.globalKey) { item in
                item.status = .failed
                item.downloadTaskIdentifier = nil
                item.errorMessage = downloadErrorMessage(for: error)
                item.updatedAt = .now
            }
            processQueueIfNeeded()
        }
    }

    private func completeDownload(globalKey: String, taskIdentifier: Int, temporaryURL: URL) async {
        guard let record = record(globalKey: globalKey) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }

        do {
            guard let details = metadataCache.mediaDetails(serverID: record.serverID, ratingKey: record.ratingKey) else {
                throw PlexServiceError.decodingError("Cached metadata missing for \(record.title)")
            }

            let media = details.media.first(where: { $0.id == record.mediaID })
                ?? StreamResolver.selectMediaVersion(from: details.media, preferredMaxResolution: preferences.downloadMaxResolution)
            guard let media,
                  let part = media.parts.first(where: { $0.id == record.partID }) ?? media.parts.first else {
                throw PlexServiceError.decodingError("Cached media part missing for \(record.title)")
            }

            let targetURL = try fileStore.targetVideoURL(for: details, part: part)
            try? FileManager.default.removeItem(at: targetURL)
            try FileManager.default.moveItem(at: temporaryURL, to: targetURL)
            fileStore.deleteResumeData(relativePath: record.resumeDataPath)
            await cacheArtwork(for: details)

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
        guard let serverID = currentServerID else {
            throw PlexServiceError.noServerConnected
        }

        let data = try await plexService.getMediaDetailsPayload(ratingKey: ratingKey)
        try metadataCache.storePayload(
            data,
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
        guard let serverID = currentServerID else {
            throw PlexServiceError.noServerConnected
        }

        let data = try await plexService.getChildrenPayload(ratingKey: ratingKey)
        try metadataCache.storePayload(
            data,
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

        await cacheArtwork(paths: paths.compactMap { $0 })
    }

    private func cacheArtwork(for seasons: [PlexSeason]) async {
        await cacheArtwork(paths: seasons.flatMap { season in
            [
                season.thumb,
                season.art,
                season.parentThumb,
            ].compactMap { $0 }
        })
    }

    private func cacheArtwork(for episodes: [PlexEpisode]) async {
        await cacheArtwork(paths: episodes.flatMap { episode in
            [
                episode.thumb,
                episode.art,
                episode.grandparentThumb,
            ].compactMap { $0 }
        })
    }

    private func cacheArtwork(paths: [String]) async {
        for path in Set(paths) {
            guard let targetURL = fileStore.artworkURL(for: path),
                  !FileManager.default.fileExists(atPath: targetURL.path),
                  let sourceURL = plexService.imageURL(for: path, width: 900, height: 1350) else {
                continue
            }

            do {
                let data = try await plexService.imageData(for: sourceURL)
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

    private func subtitle(for details: PlexMediaDetails) -> String? {
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
        if let index = records.firstIndex(where: { $0.globalKey == record.globalKey }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist()
    }

    private func record(globalKey: String) -> DownloadedMediaRecord? {
        records.first { $0.globalKey == globalKey }
    }

    private func update(_ ratingKey: String, mutate: (inout DownloadedMediaRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.ratingKey == ratingKey }) else { return }
        mutate(&records[index])
        persist()
    }

    private func update(globalKey: String, persist shouldPersist: Bool = true, mutate: (inout DownloadedMediaRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.globalKey == globalKey }) else { return }
        mutate(&records[index])
        if shouldPersist {
            persist()
        }
    }

    private func handleTransferEvent(_ event: DownloadTransferEvent) {
        switch event {
        case let .progress(taskIdentifier, globalKey, progress, downloadedBytes, totalBytes):
            guard let globalKey = resolvedGlobalKey(globalKey, taskIdentifier: taskIdentifier) else { return }
            guard !deletingDownloadIDs.contains(globalKey) else { return }
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
            guard let globalKey = resolvedGlobalKey(globalKey, taskIdentifier: taskIdentifier) else { return }
            guard !deletingDownloadIDs.contains(globalKey) else { return }
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
            processQueueIfNeeded()
        case let .cancelled(taskIdentifier, globalKey):
            guard let globalKey = resolvedGlobalKey(globalKey, taskIdentifier: taskIdentifier) else { return }
            guard !deletingDownloadIDs.contains(globalKey) else { return }
            update(globalKey: globalKey) { item in
                item.status = .cancelled
                item.resumeDataPath = nil
                item.downloadTaskIdentifier = nil
                item.errorMessage = nil
                item.updatedAt = .now
            }
            lastProgressPersistDates.removeValue(forKey: globalKey)
            processQueueIfNeeded()
        case let .finished(taskIdentifier, globalKey, temporaryURL):
            guard let globalKey = resolvedGlobalKey(globalKey, taskIdentifier: taskIdentifier) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                return
            }
            guard !deletingDownloadIDs.contains(globalKey) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                return
            }
            Task { await completeDownload(globalKey: globalKey, taskIdentifier: taskIdentifier, temporaryURL: temporaryURL) }
        case let .failed(taskIdentifier, globalKey, error):
            guard let globalKey = resolvedGlobalKey(globalKey, taskIdentifier: taskIdentifier) else { return }
            guard !deletingDownloadIDs.contains(globalKey) else { return }
            if record(globalKey: globalKey)?.status == .paused {
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
            processQueueIfNeeded()
        }
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
        if let globalKey {
            return globalKey
        }
        return records.first { $0.downloadTaskIdentifier == taskIdentifier }?.globalKey
    }

    private func reconcileExistingTransfers() async {
        let activeTasks = await transferController.existingTasks()
        let taskByGlobalKey = Dictionary(
            uniqueKeysWithValues: activeTasks.compactMap { task -> (String, Int)? in
                guard let globalKey = task.globalKey else { return nil }
                return (globalKey, task.identifier)
            }
        )

        var changed = false
        for index in records.indices where records[index].status == .preparing || records[index].status == .downloading {
            if let taskIdentifier = taskByGlobalKey[records[index].globalKey] {
                records[index].status = .downloading
                records[index].downloadTaskIdentifier = taskIdentifier
            } else {
                records[index].status = .queued
                records[index].downloadTaskIdentifier = nil
            }
            records[index].updatedAt = .now
            changed = true
        }

        if changed {
            persist()
        }
        processQueueIfNeeded()
    }

    private func pruneMissingCompletedFiles() {
        let originalCount = records.count
        records.removeAll { record in
            record.status == .completed && fileStore.existingFileURL(for: record.relativeVideoPath) == nil
        }

        if records.count != originalCount {
            persist()
        }
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

    private func upsertFailedPlaceholder(ratingKey: String, type: PlexMediaType, error: Error) {
        guard let serverID = currentServerID else { return }
        let placeholder = DownloadedMediaRecord(
            serverID: serverID,
            serverName: currentServerName,
            ratingKey: ratingKey,
            type: type,
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
        let originalCount = records.count
        records.removeAll {
            $0.ratingKey == scope.ratingKey
                && $0.type == scope.type
                && $0.mediaID == nil
                && $0.partID == nil
        }
        if records.count != originalCount {
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
        records.removeAll { globalKeys.contains($0.globalKey) }
        for globalKey in globalKeys {
            lastProgressPersistDates.removeValue(forKey: globalKey)
            deletingDownloadIDs.remove(globalKey)
        }
        persist()
        processQueueIfNeeded()
    }

    private func persist() {
        try? fileStore.saveSnapshot(DownloadStoreSnapshot(records: records))
    }
}
