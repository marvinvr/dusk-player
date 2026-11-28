import CoreFoundation
import Foundation

// Plex's Download Queue API (PMS 1.41.9+): the wire shapes behind
// `PlexDownloads`' converted downloads.

enum PlexDownloadQueueStatus: String, Sendable {
    case deciding, waiting, processing, available, error, expired
}

struct PlexDownloadQueueItem: Sendable {
    let id: String
    let queueID: String
    let key: String
    let status: PlexDownloadQueueStatus
    /// Preparation progress, not transferred bytes. nil is indeterminate.
    let progress: Double?
    let error: String?
}

extension PlexDownloadQueueItem {
    private static let metadataKeyPrefix = "/library/metadata/"

    /// The neutral job. The item id is the rating key behind
    /// `/library/metadata/`, so comparing it with a rating key is the same
    /// test as comparing `key` with that item's metadata path.
    var job: ConversionJob {
        let state: ConversionJobState = switch status {
        case .deciding, .waiting, .processing: .preparing
        case .available: .ready
        case .error: .failed
        case .expired: .expired
        }
        return ConversionJob(
            id: id,
            queueID: queueID,
            itemID: key.hasPrefix(Self.metadataKeyPrefix) ? String(key.dropFirst(Self.metadataKeyPrefix.count)) : nil,
            state: state,
            progress: progress,
            failureReason: error
        )
    }
}

/// The Plex name for the neutral preparation error; the queue parser and its
/// regression fixtures throw it.
typealias PlexDownloadQueueError = DownloadPreparationError

/// Only describes the validated converted output; library stream IDs and HDR
/// flags belong to the original file and must not leak into offline playback.
struct PlexDownloadDecision: Sendable {
    let videoResolution: String?
    let audioChannels: Int?
    let width: Int?
    let height: Int?
    let bitrate: Int?
    let duration: Int?
    let partDuration: Int?

    func convertedMedia(sourceMedia: MediaVersion, mediaPath: String, expectedBytes: Int64?) -> MediaVersion {
        let part = MediaPart(
            id: sourceMedia.firstAvailablePart?.id ?? "0",
            key: mediaPath,
            file: nil,
            size: expectedBytes.flatMap(Int.init(exactly:)),
            container: "mkv",
            duration: partDuration ?? duration ?? sourceMedia.duration,
            videoProfile: nil, audioProfile: nil, accessible: true, exists: true, streams: []
        )
        return MediaVersion(
            id: sourceMedia.id, container: "mkv", videoCodec: "h264", audioCodec: "aac",
            videoResolution: videoResolution, videoProfile: nil, audioProfile: nil,
            audioChannels: audioChannels, width: width, height: height, bitrate: bitrate,
            duration: duration ?? sourceMedia.duration, optimizedForStreaming: nil, parts: [part]
        )
    }
}

/// Pure response parsing shared by preparation and its protocol regression
/// fixtures. Sending and active-profile validation stay in the facade
/// (`MediaService+Downloads`), reached through `DownloadConversionTransport`.
enum PlexDownloadQueueResponse {
    static func decision(_ data: Data) throws -> PlexDownloadDecision {
        let metadata = try elements(data, named: "Metadata")
        guard metadata.count == 1, let allMedia = metadata[0]["Media"] as? [[String: Any]] else {
            throw invalidResponse()
        }
        let selectedMedia = allMedia.filter { selected($0["selected"]) }
        let candidates = selectedMedia.isEmpty ? allMedia : selectedMedia
        guard candidates.count == 1, let parts = candidates[0]["Part"] as? [[String: Any]], parts.count == 1 else {
            throw invalidResponse()
        }
        let media = candidates[0]
        let part = parts[0]
        guard let streams = part["Stream"] as? [[String: Any]] else { throw invalidResponse() }
        let videos = streams.filter { integer($0["streamType"]) == 1 }
        let audio = streams.filter { integer($0["streamType"]) == 2 }
        let container = part["container"] as? String ?? media["container"] as? String
        let videoCodec = videos.count == 1 ? videos[0]["codec"] as? String : media["videoCodec"] as? String
        let audioCodec = audio.count == 1 ? audio[0]["codec"] as? String : media["audioCodec"] as? String
        guard container == "mkv", videoCodec == "h264", audioCodec == "aac",
              media["container"] == nil || media["container"] as? String == "mkv",
              media["videoCodec"] == nil || media["videoCodec"] as? String == "h264",
              media["audioCodec"] == nil || media["audioCodec"] as? String == "aac",
              videos.allSatisfy({ $0["codec"] as? String == "h264" }),
              audio.allSatisfy({ $0["codec"] as? String == "aac" }),
              media["protocol"] == nil || media["protocol"] as? String == "http",
              part["protocol"] == nil || part["protocol"] as? String == "http",
              part["decision"] as? String == "transcode" else {
            throw PlexDownloadQueueError.preparationFailed("Plex could not prepare an MKV download with H.264 video and AAC audio.")
        }

        return PlexDownloadDecision(
            videoResolution: media["videoResolution"] as? String,
            audioChannels: integer(media["audioChannels"]),
            width: integer(media["width"]),
            height: integer(media["height"]),
            bitrate: integer(media["bitrate"]),
            duration: integer(media["duration"]),
            partDuration: integer(part["duration"])
        )
    }

    static func elements(_ data: Data, named name: String, allowEmpty: Bool = false) throws -> [[String: Any]] {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = body["MediaContainer"] as? [String: Any] else { throw invalidResponse() }
        if allowEmpty, container[name] == nil, integer(container["size"]) == 0 { return [] }
        guard let values = container[name] as? [[String: Any]] else { throw invalidResponse() }
        return values
    }

    static func item(_ item: [String: Any], queueID: String) throws -> PlexDownloadQueueItem {
        let itemID = try id(item["id"])
        guard try id(item["queueId"]) == queueID,
              let key = item["key"] as? String, !key.isEmpty,
              let rawStatus = item["status"] as? String,
              let status = PlexDownloadQueueStatus(rawValue: rawStatus) else { throw invalidResponse() }
        var progress: Double?
        if let session = item["TranscodeSession"] as? [String: Any], let value = session["progress"] {
            let percentage = number(value)?.doubleValue ?? (value as? String).flatMap(Double.init)
            guard let percentage, percentage.isFinite, (0...100).contains(percentage) else { throw invalidResponse() }
            progress = percentage / 100
        }
        var reason = text(item["error"])
        if status == .error, let decision = item["DecisionResult"] as? [String: Any] {
            for kind in ["transcode", "general"] {
                let code = integer(decision["\(kind)DecisionCode"])
                if code == 1000 || code == 1001 { continue }
                if let text = text(decision["\(kind)DecisionText"]) {
                    reason = text
                    break
                }
            }
        }
        return PlexDownloadQueueItem(id: itemID, queueID: queueID, key: key, status: status,
                                     progress: status == .available ? 1 : progress, error: reason)
    }

    static func id(_ value: Any?) throws -> String {
        let value = (value as? String) ?? number(value)?.stringValue
        guard let value, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw invalidResponse()
        }
        return value
    }

    static func metadataKey(_ itemID: String) throws -> String {
        guard !itemID.isEmpty,
              let encoded = itemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) else {
            throw invalidResponse()
        }
        return "/library/metadata/\(encoded)"
    }

    private static func integer(_ value: Any?) -> Int? {
        if number(value) != nil, let value = value as? Int { return value }
        return (value as? String).flatMap(Int.init)
    }

    private static func selected(_ value: Any?) -> Bool {
        if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
            return value.boolValue
        }
        return integer(value) == 1
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func invalidResponse() -> PlexDownloadQueueError {
        .invalidResponse("Plex returned an invalid download preparation response.")
    }
}
