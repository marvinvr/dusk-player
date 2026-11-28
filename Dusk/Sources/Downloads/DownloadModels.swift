import Foundation

/// An explicit offline conversion choice, independent of playback quality.
enum DownloadQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, p1080High, p1080, p720, p720Low, p480, p320

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: "Original"
        case .p1080High: "1080p · 12 Mbps"
        case .p1080: "1080p · 8 Mbps"
        case .p720: "720p · 4 Mbps"
        case .p720Low: "720p · 2 Mbps"
        case .p480: "480p · 1 Mbps"
        case .p320: "320p · 0.7 Mbps"
        }
    }

    var bitrate: Int? {
        switch self {
        case .original: nil
        case .p1080High: 12000
        case .p1080: 8000
        case .p720: 4000
        case .p720Low: 2000
        case .p480: 1000
        case .p320: 700
        }
    }

    var resolution: String? {
        switch self {
        case .original: nil
        case .p1080High, .p1080: "1920x1080"
        case .p720, .p720Low: "1280x720"
        case .p480: "720x480"
        case .p320: "576x320"
        }
    }
}

enum DownloadStatus: String, Codable, Sendable {
    case queued
    case preparing
    case downloading
    case paused
    case completed
    case failed
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .preparing, .downloading:
            return true
        case .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    var canPause: Bool {
        switch self {
        case .queued, .preparing, .downloading:
            return true
        case .paused, .completed, .failed, .cancelled:
            return false
        }
    }

    var canResume: Bool {
        switch self {
        case .paused, .failed:
            return true
        case .queued, .preparing, .downloading, .completed, .cancelled:
            return false
        }
    }

    var canCancel: Bool {
        switch self {
        case .queued, .preparing, .downloading, .paused, .failed, .cancelled:
            return true
        case .completed:
            return false
        }
    }

    var canDelete: Bool {
        switch self {
        case .completed:
            return true
        case .queued, .preparing, .downloading, .paused, .failed, .cancelled:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .queued:
            return "Queued"
        case .preparing:
            return "Preparing"
        case .downloading:
            return "Downloading"
        case .paused:
            return "Paused"
        case .completed:
            return "Downloaded"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

/// What a download control acts on: one item (or one season/show branch) on one
/// server. The server travels with the rating key because the same key means a
/// different title on every other server the account has connected.
struct DownloadScope: Hashable, Sendable {
    let id: MediaItemID
    let type: MediaKind

    init(id: MediaItemID, type: MediaKind) {
        self.id = id
        self.type = type
    }

    var itemID: String { id.itemID }
    var serverID: String? { id.serverID }
}

struct DownloadControlState: Hashable, Sendable {
    let scope: DownloadScope
    let status: DownloadStatus?
    let progress: Double
    let isDeleting: Bool
    let records: [DownloadedMediaRecord]

    var hasRecords: Bool {
        !records.isEmpty
    }

    var canPause: Bool {
        status?.canPause == true
    }

    var canResume: Bool {
        status?.canResume == true
    }

    var canCancel: Bool {
        status?.canCancel == true
    }

    var canDelete: Bool {
        status?.canDelete == true
    }
}

struct DownloadedMediaRecord: Codable, Sendable, Identifiable, Hashable {
    var id: String { globalKey }

    /// Stable Plex Home identity that owns this download. A nil value is a
    /// pre-Plex-Home record awaiting one-time adoption by the original account.
    var accountProfileID: String? = nil
    /// Machine identifier of the server the file came from. Mutable only so a
    /// legacy record keyed on the server's base URL can be re-keyed once the
    /// matching server is known (see `DownloadManager`).
    var serverID: String
    var serverName: String?
    let itemID: String
    let type: MediaKind
    /// Whether the item is a video clip (Plex reports clips as `type == "movie"`
    /// with `subtype == "clip"`). Drives 16:9 artwork and the `.downloadedVideo`
    /// route. Defaults to false so records persisted before the flag existed
    /// still decode.
    var isClip: Bool = false
    var title: String
    var subtitle: String?
    var parentID: String?
    var parentTitle: String?
    var grandparentID: String?
    var grandparentTitle: String?
    var thumbPath: String?
    var artPath: String?
    var mediaID: String?
    var partID: String?
    var downloadQuality: DownloadQuality = .original
    /// Queued by the show's Keep Next N Unwatched rule (`SmartDownloadRule`),
    /// so the rule may remove it once watched. Manual downloads stay false.
    var isSmartDownload: Bool = false
    /// Persisted before any server mutation; each request owns its own Plex queue.
    var queueClientIdentifier: String? = nil
    var plexDownloadQueueID: String? = nil
    var plexDownloadItemID: String? = nil
    var preparationProgress: Double? = nil
    var preparationRetryCount: Int = 0
    /// Encoded separately to retain the record's Hashable conformance. Source
    /// media/part IDs above remain stable even when the prepared file expires.
    var convertedMediaData: Data? = nil

    var convertedMedia: MediaVersion? {
        convertedMediaData.flatMap { try? JSONDecoder().decode(MediaVersion.self, from: $0) }
    }

    /// The converted file plus the source part's external subtitle sidecars.
    /// Plex's audio/video and embedded subtitle metadata describe the original
    /// file and would mislabel the MKV's own tracks; sidecars can still mount.
    func convertedMediaVersion(sourcePart: MediaPart?) -> (media: MediaVersion, part: MediaPart)? {
        guard let media = convertedMedia, let converted = media.parts.first else { return nil }
        let sidecars = sourcePart?.streams.filter { $0.kind == .subtitle && $0.key != nil } ?? []
        let part = MediaPart(
            id: converted.id, key: converted.key, file: converted.file, size: converted.size,
            container: converted.container, duration: converted.duration,
            videoProfile: converted.videoProfile, audioProfile: converted.audioProfile,
            accessible: converted.accessible, exists: converted.exists, streams: sidecars
        )
        return (MediaVersion(
            id: media.id, container: media.container, videoCodec: media.videoCodec, audioCodec: media.audioCodec,
            videoResolution: media.videoResolution, videoProfile: media.videoProfile, audioProfile: media.audioProfile,
            audioChannels: media.audioChannels, width: media.width, height: media.height, bitrate: media.bitrate,
            duration: media.duration, optimizedForStreaming: media.optimizedForStreaming, parts: [part]
        ), part)
    }
    var relativeVideoPath: String?
    /// Plex stream id → relative path of that external text subtitle, saved
    /// next to the download so it mounts offline. Nil until the item's sidecars
    /// were fetched once (an empty map: it has none), so downloads made before
    /// subtitles were saved fetch theirs the next time their server is online.
    var externalSubtitlePaths: [String: String]? = nil
    /// A sidecar could not be fetched; the next backfill retries the missing ones.
    var hasMissingExternalSubtitles: Bool = false
    var resumeDataPath: String?
    var downloadTaskIdentifier: Int?
    /// Distinguishes an automatic Home-user suspension from a user-requested
    /// pause so the queue can resume when its owning profile becomes active.
    var wasPausedForProfileSwitch: Bool = false
    var status: DownloadStatus
    var progress: Double
    var downloadedBytes: Int64
    var totalBytes: Int64?
    var errorMessage: String?
    var addedAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case accountProfileID, serverID, serverName, itemID = "ratingKey", type, isClip
        case title, subtitle
        case parentID = "parentRatingKey", parentTitle
        case grandparentID = "grandparentRatingKey", grandparentTitle
        case thumbPath, artPath
        case mediaID, partID
        case downloadQuality, isSmartDownload, queueClientIdentifier, plexDownloadQueueID, plexDownloadItemID
        case preparationProgress, preparationRetryCount, convertedMediaData
        case relativeVideoPath, externalSubtitlePaths, hasMissingExternalSubtitles, resumeDataPath, downloadTaskIdentifier, wasPausedForProfileSwitch
        case status, progress, downloadedBytes, totalBytes
        case errorMessage, addedAt, updatedAt
    }

    var globalKey: String {
        Self.globalKey(
            accountProfileID: accountProfileID,
            serverID: serverID,
            itemID: itemID
        )
    }

    /// Server-scoped identity of the downloaded item, for playback and lookups.
    var mediaItemID: MediaItemID {
        MediaItemID(serverID: serverID, itemID: itemID)
    }

    var displayTitle: String {
        if type == .episode, let grandparentTitle, !grandparentTitle.isEmpty {
            return "\(grandparentTitle) - \(title)"
        }
        return title
    }

    static func globalKey(serverID: String, itemID: String) -> String {
        globalKey(accountProfileID: nil, serverID: serverID, itemID: itemID)
    }

    static func globalKey(accountProfileID: String?, serverID: String, itemID: String) -> String {
        if let accountProfileID = accountProfileID?.nilIfEmpty {
            return "\(accountProfileID):\(serverID):\(itemID)"
        }
        return "\(serverID):\(itemID)"
    }

    var legacyGlobalKey: String {
        Self.globalKey(serverID: serverID, itemID: itemID)
    }

    /// The source part's external subtitles that can be saved for offline
    /// playback: text sidecars only. Bitmap sidecars (VobSub) and unknown
    /// codecs are left on the server.
    static func offlineSubtitleStreams(in sourcePart: MediaPart?) -> [MediaStream] {
        (sourcePart?.streams ?? []).filter {
            $0.kind == .subtitle && $0.key?.nilIfEmpty != nil
                && SubtitleTextDecoder.fileExtension(for: $0.codec) != nil
        }
    }
}

extension DownloadedMediaRecord {
    /// Custom decoding (kept in an extension so the memberwise initializer
    /// survives) so `isClip` can default to false for snapshots written before
    /// the flag existed, and so `mediaID`/`partID` decode from a number or a
    /// string.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountProfileID = try container.decodeIfPresent(String.self, forKey: .accountProfileID)
        serverID = try container.decode(String.self, forKey: .serverID)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        itemID = try container.decode(String.self, forKey: .itemID)
        type = try container.decode(MediaKind.self, forKey: .type)
        isClip = try container.decodeIfPresent(Bool.self, forKey: .isClip) ?? false
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        grandparentID = try container.decodeIfPresent(String.self, forKey: .grandparentID)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        thumbPath = try container.decodeIfPresent(String.self, forKey: .thumbPath)
        artPath = try container.decodeIfPresent(String.self, forKey: .artPath)
        mediaID = try container.decodeIDIfPresent(forKey: .mediaID)
        partID = try container.decodeIDIfPresent(forKey: .partID)
        downloadQuality = try container.decodeIfPresent(DownloadQuality.self, forKey: .downloadQuality) ?? .original
        isSmartDownload = try container.decodeIfPresent(Bool.self, forKey: .isSmartDownload) ?? false
        queueClientIdentifier = try container.decodeIfPresent(String.self, forKey: .queueClientIdentifier)
        plexDownloadQueueID = try container.decodeIfPresent(String.self, forKey: .plexDownloadQueueID)
        plexDownloadItemID = try container.decodeIfPresent(String.self, forKey: .plexDownloadItemID)
        preparationProgress = try container.decodeIfPresent(Double.self, forKey: .preparationProgress)
        preparationRetryCount = try container.decodeIfPresent(Int.self, forKey: .preparationRetryCount) ?? 0
        convertedMediaData = try container.decodeIfPresent(Data.self, forKey: .convertedMediaData)
        relativeVideoPath = try container.decodeIfPresent(String.self, forKey: .relativeVideoPath)
        externalSubtitlePaths = try container.decodeIfPresent([String: String].self, forKey: .externalSubtitlePaths)
        hasMissingExternalSubtitles = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasMissingExternalSubtitles
        ) ?? false
        resumeDataPath = try container.decodeIfPresent(String.self, forKey: .resumeDataPath)
        downloadTaskIdentifier = try container.decodeIfPresent(Int.self, forKey: .downloadTaskIdentifier)
        wasPausedForProfileSwitch = try container.decodeIfPresent(
            Bool.self,
            forKey: .wasPausedForProfileSwitch
        ) ?? false
        status = try container.decode(DownloadStatus.self, forKey: .status)
        progress = try container.decode(Double.self, forKey: .progress)
        downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct DownloadedShowSummary: Identifiable, Hashable {
    let serverID: String
    let itemID: String
    let title: String
    let thumbPath: String?
    let artPath: String?
    let downloadedEpisodeCount: Int
    let totalEpisodeCount: Int?
    /// The show's Keep Next N Unwatched rule, when one is on.
    var smartRule: SmartDownloadRule? = nil
    /// Episodes of the show still queued or transferring.
    var pendingEpisodeCount: Int = 0

    var id: String {
        DownloadedMediaRecord.globalKey(serverID: serverID, itemID: itemID)
    }

    var mediaItemID: MediaItemID {
        MediaItemID(serverID: serverID, itemID: itemID)
    }

    var subtitle: String {
        if let smartRule {
            let detail: String? = if downloadedEpisodeCount > 0 {
                downloadedEpisodeCount == 1 ? "1 episode" : "\(downloadedEpisodeCount) episodes"
            } else if pendingEpisodeCount > 0 {
                "downloading"
            } else if smartRule.remainingUnwatchedCount == 0 {
                "all watched"
            } else {
                nil
            }
            return [smartRule.shortLabel, detail].compactMap { $0 }.joined(separator: " · ")
        }
        if let totalEpisodeCount, totalEpisodeCount > 0 {
            return "\(downloadedEpisodeCount) of \(totalEpisodeCount) episodes"
        }
        return MediaTextFormatter.episodeCount(downloadedEpisodeCount) ?? "\(downloadedEpisodeCount) episodes"
    }
}

struct DownloadStoreSnapshot: Codable, Sendable {
    var records: [DownloadedMediaRecord] = []
    var pendingQueueRemovals: [DownloadQueueRemoval]? = nil
    var smartDownloadRules: [SmartDownloadRule]? = nil
}

/// Cleanup survives an offline cancellation or a Plex Home profile switch.
struct DownloadQueueRemoval: Codable, Sendable, Hashable {
    let profileID: String
    let serverID: String
    let clientIdentifier: String
    let itemID: String
    let queueID: String?
    let queueItemID: String?

    enum CodingKeys: String, CodingKey {
        case profileID, serverID, clientIdentifier, itemID = "ratingKey", queueID
        case queueItemID = "itemID"
    }
}

extension DownloadedMediaRecord {
    /// Matches the synthesized encoding; `mediaID`/`partID` are written back as
    /// numbers when they are numbers, as they always were (`encodeID`).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(accountProfileID, forKey: .accountProfileID)
        try container.encode(serverID, forKey: .serverID)
        try container.encodeIfPresent(serverName, forKey: .serverName)
        try container.encode(itemID, forKey: .itemID)
        try container.encode(type, forKey: .type)
        try container.encode(isClip, forKey: .isClip)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(parentTitle, forKey: .parentTitle)
        try container.encodeIfPresent(grandparentID, forKey: .grandparentID)
        try container.encodeIfPresent(grandparentTitle, forKey: .grandparentTitle)
        try container.encodeIfPresent(thumbPath, forKey: .thumbPath)
        try container.encodeIfPresent(artPath, forKey: .artPath)
        try container.encodeIDIfPresent(mediaID, forKey: .mediaID)
        try container.encodeIDIfPresent(partID, forKey: .partID)
        try container.encode(downloadQuality, forKey: .downloadQuality)
        try container.encode(isSmartDownload, forKey: .isSmartDownload)
        try container.encodeIfPresent(queueClientIdentifier, forKey: .queueClientIdentifier)
        try container.encodeIfPresent(plexDownloadQueueID, forKey: .plexDownloadQueueID)
        try container.encodeIfPresent(plexDownloadItemID, forKey: .plexDownloadItemID)
        try container.encodeIfPresent(preparationProgress, forKey: .preparationProgress)
        try container.encode(preparationRetryCount, forKey: .preparationRetryCount)
        try container.encodeIfPresent(convertedMediaData, forKey: .convertedMediaData)
        try container.encodeIfPresent(relativeVideoPath, forKey: .relativeVideoPath)
        try container.encodeIfPresent(externalSubtitlePaths, forKey: .externalSubtitlePaths)
        try container.encode(hasMissingExternalSubtitles, forKey: .hasMissingExternalSubtitles)
        try container.encodeIfPresent(resumeDataPath, forKey: .resumeDataPath)
        try container.encodeIfPresent(downloadTaskIdentifier, forKey: .downloadTaskIdentifier)
        try container.encode(wasPausedForProfileSwitch, forKey: .wasPausedForProfileSwitch)
        try container.encode(status, forKey: .status)
        try container.encode(progress, forKey: .progress)
        try container.encode(downloadedBytes, forKey: .downloadedBytes)
        try container.encodeIfPresent(totalBytes, forKey: .totalBytes)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
