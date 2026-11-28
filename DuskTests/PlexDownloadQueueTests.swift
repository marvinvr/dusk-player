import Foundation
import Testing
@testable import Dusk

@Suite("Plex offline download protocol")
struct PlexDownloadQueueTests {
    @Test func processingAcceptsStringIdentifiersAndNormalizesPercentage() throws {
        let item = try queueItem(progress: "\"42.5\"")
        #expect(item.id == "23")
        #expect(item.queueID == "7")
        #expect(item.key == "/library/metadata/42")
        #expect(item.status == .processing)
        #expect(item.progress == 0.425)
    }

    @Test func waitingAndReadyDoNotConfusePreparationWithTransferProgress() throws {
        let waiting = try queueItem(status: "waiting", progress: nil)
        let available = try queueItem(status: "available", progress: "37.5")
        #expect(waiting.progress == nil)
        #expect(available.progress == 1)
    }

    @Test(arguments: ["-1", "101", "\"NaN\"", "\"unavailable\"", "true"])
    func malformedPreparationProgressIsRejected(_ progress: String) {
        #expect(throws: PlexDownloadQueueError.self) {
            try queueItem(progress: progress)
        }
    }

    @Test func wrongQueueAndUnknownStatusAreRejected() {
        #expect(throws: PlexDownloadQueueError.self) {
            try queueItem(queueID: "8")
        }
        #expect(throws: PlexDownloadQueueError.self) {
            try queueItem(status: "unknown")
        }
    }

    @Test func identifiersCannotChangeTheRequestPathOrComeFromBooleans() throws {
        for value: Any in ["../8", "7/items/23", "7?token=other", "", true, -1, 1.5] {
            #expect(throws: PlexDownloadQueueError.self) {
                try PlexDownloadQueueResponse.id(value)
            }
        }
        #expect(try PlexDownloadQueueResponse.id(7) == "7")
        #expect(try PlexDownloadQueueResponse.id("23") == "23")
        #expect(try PlexDownloadQueueResponse.metadataKey("42/part?x#y%") == "/library/metadata/42%2Fpart%3Fx%23y%25")
    }

    @Test func emptyQueueRequiresAnExplicitEmptyResponse() throws {
        let empty = Data(#"{"MediaContainer":{"size":0}}"#.utf8)
        let malformed = Data(#"{"MediaContainer":{}}"#.utf8)
        #expect(try PlexDownloadQueueResponse.elements(empty, named: "DownloadQueueItem", allowEmpty: true).isEmpty)
        #expect(throws: PlexDownloadQueueError.self) {
            try PlexDownloadQueueResponse.elements(malformed, named: "DownloadQueueItem", allowEmpty: true)
        }
    }

    @Test func serverFailureUsesTheSpecificReasonAndIgnoresPriorSuccess() throws {
        var raw = try rawQueueItem(status: "error", progress: nil)
        raw["error"] = "transcodeError"
        raw["DecisionResult"] = [
            "transcodeDecisionCode": 4005,
            "transcodeDecisionText": "  Transcoding is disabled  ",
        ]
        #expect(try PlexDownloadQueueResponse.item(raw, queueID: "7").error == "Transcoding is disabled")
        raw["DecisionResult"] = [
            "transcodeDecisionCode": 1001,
            "transcodeDecisionText": "Conversion OK",
            "generalDecisionCode": 1000,
            "generalDecisionText": "Direct play OK",
        ]
        #expect(try PlexDownloadQueueResponse.item(raw, queueID: "7").error == "transcodeError")
    }

    @Test(arguments: ["container", "videoCodec", "audioCodec", "protocol", "decision"])
    func incompatibleReadyDecisionsAreRejected(_ field: String) throws {
        var media = decisionMedia()
        if field == "decision" {
            var parts = try #require(media["Part"] as? [[String: Any]])
            parts[0]["decision"] = "directplay"
            media["Part"] = parts
        } else {
            media[field] = ["container": "mp4", "videoCodec": "hevc", "audioCodec": "ac3", "protocol": "hls"][field]
        }
        let data = try decisionData([media])
        #expect(throws: PlexDownloadQueueError.self) {
            try PlexDownloadQueueResponse.decision(data)
        }
    }

    @Test func ambiguousMediaAndMissingPartsAreRejected() throws {
        let ambiguous = try decisionData([decisionMedia(), decisionMedia()])
        var missing = decisionMedia()
        missing.removeValue(forKey: "Part")
        let incomplete = try decisionData([missing])
        #expect(throws: PlexDownloadQueueError.self) { try PlexDownloadQueueResponse.decision(ambiguous) }
        #expect(throws: PlexDownloadQueueError.self) { try PlexDownloadQueueResponse.decision(incomplete) }
    }

    @Test func convertedMetadataPreservesIdentityWithoutOriginalHDRAndTrackIDs() throws {
        let source = try sourceMedia()
        let decision = try PlexDownloadQueueResponse.decision(decisionData([decisionMedia()]))
        let converted = decision.convertedMedia(sourceMedia: source, mediaPath: "/downloadQueue/7/item/23/media", expectedBytes: 1234)
        let part = try #require(converted.parts.first)
        #expect(converted.id == "41")
        #expect(part.id == "17")
        #expect(converted.container == "mkv")
        #expect(converted.videoCodec == "h264")
        #expect(converted.audioCodec == "aac")
        #expect(converted.width == 1280)
        #expect(converted.height == 720)
        #expect(converted.duration == source.duration)
        #expect(part.size == 1234)
        #expect(part.streams.isEmpty)
        #expect(converted.videoProfile == nil)
        #expect(converted.audioProfile == nil)
    }

    @Test func legacyRecordsRemainOriginalAndConvertedMetadataSurvivesRelaunch() throws {
        let data = Data(#"{"serverID":"server-a","ratingKey":"42","type":"movie","title":"Example","mediaID":41,"partID":17,"relativeVideoPath":"Movies/Example.mkv","status":"completed","progress":1,"downloadedBytes":1234,"addedAt":0,"updatedAt":1}"#.utf8)
        var record = try JSONDecoder().decode(DownloadedMediaRecord.self, from: data)
        #expect(record.downloadQuality == .original)
        #expect(record.queueClientIdentifier == nil)
        #expect(record.plexDownloadQueueID == nil)
        #expect(record.plexDownloadItemID == nil)
        #expect(record.preparationProgress == nil)
        #expect(record.preparationRetryCount == 0)
        #expect(record.convertedMedia == nil)

        let decision = try PlexDownloadQueueResponse.decision(decisionData([decisionMedia()]))
        let converted = decision.convertedMedia(sourceMedia: try sourceMedia(), mediaPath: "/downloadQueue/7/item/23/media", expectedBytes: 1234)
        record.downloadQuality = .p720
        record.convertedMediaData = try JSONEncoder().encode(converted)
        let restored = try JSONDecoder().decode(DownloadedMediaRecord.self, from: JSONEncoder().encode(record))
        #expect(restored.downloadQuality == .p720)
        #expect(restored.mediaID == "41")
        #expect(restored.partID == "17")
        #expect(restored.convertedMedia?.videoCodec == "h264")
        #expect(restored.convertedMedia?.parts.first?.streams.isEmpty == true)
        #expect(restored.relativeVideoPath == "Movies/Example.mkv")
    }

    @Test func convertedPlaybackKeepsOnlyExternalSubtitleSidecars() throws {
        let decision = try PlexDownloadQueueResponse.decision(decisionData([decisionMedia()]))
        let converted = decision.convertedMedia(sourceMedia: try sourceMedia(), mediaPath: "/downloadQueue/7/item/23/media", expectedBytes: 1234)
        var record = try JSONDecoder().decode(DownloadedMediaRecord.self, from: Data(#"{"serverID":"server-a","ratingKey":"42","type":"movie","title":"Example","mediaID":41,"partID":17,"status":"completed","progress":1,"downloadedBytes":1234,"addedAt":0,"updatedAt":1}"#.utf8))
        record.downloadQuality = .p720
        record.convertedMediaData = try JSONEncoder().encode(converted)
        let sourcePartJSON = #"{"id":17,"key":"/library/parts/17/file.mkv","Stream":[{"id":101,"streamType":1,"codec":"hevc"},{"id":102,"streamType":2,"codec":"truehd"},{"id":103,"streamType":3,"codec":"pgs"},{"id":104,"streamType":3,"codec":"srt","key":"/library/streams/104"}]}"#
        let sourcePart = try JSONDecoder().decode(MediaPart.self, from: Data(sourcePartJSON.utf8))

        let version = try #require(record.convertedMediaVersion(sourcePart: sourcePart))
        #expect(version.part.streams.map(\.id) == ["104"])
        #expect(version.media.parts.first?.streams.map(\.id) == ["104"])
        #expect(version.part.key == "/downloadQueue/7/item/23/media")
        #expect(version.media.videoCodec == "h264")
        #expect(record.convertedMediaVersion(sourcePart: nil)?.part.streams.isEmpty == true)
    }

    @Test func legacyRecordsHaveNoSavedSubtitlesAndSavedPathsSurviveRelaunch() throws {
        let data = Data(#"{"serverID":"server-a","ratingKey":"42","type":"movie","title":"Example","mediaID":41,"partID":17,"status":"completed","progress":1,"downloadedBytes":1234,"addedAt":0,"updatedAt":1}"#.utf8)
        var record = try JSONDecoder().decode(DownloadedMediaRecord.self, from: data)
        #expect(record.externalSubtitlePaths == nil)
        #expect(record.hasMissingExternalSubtitles == false)

        record.externalSubtitlePaths = ["104": "Subtitles/abc/104.srt", "105": "Subtitles/abc/105.ass"]
        record.hasMissingExternalSubtitles = true
        let restored = try JSONDecoder().decode(DownloadedMediaRecord.self, from: JSONEncoder().encode(record))
        #expect(restored.externalSubtitlePaths == ["104": "Subtitles/abc/104.srt", "105": "Subtitles/abc/105.ass"])
        #expect(restored.hasMissingExternalSubtitles)
    }

    @Test func onlyExternalTextSubtitlesAreSavedForOffline() throws {
        let json = #"{"id":17,"key":"/library/parts/17/file.mp4","Stream":[{"id":101,"streamType":1,"codec":"h264"},{"id":102,"streamType":3,"codec":"mov_text"},{"id":103,"streamType":3,"codec":"srt","key":"/library/streams/103"},{"id":104,"streamType":3,"codec":"ass","key":"/library/streams/104"},{"id":105,"streamType":3,"codec":"ssa","key":"/library/streams/105"},{"id":106,"streamType":3,"codec":"vtt","key":"/library/streams/106"},{"id":107,"streamType":3,"codec":"vobsub","key":"/library/streams/107"},{"id":108,"streamType":3,"codec":"srt","key":""}]}"#
        let part = try JSONDecoder().decode(MediaPart.self, from: Data(json.utf8))
        #expect(DownloadedMediaRecord.offlineSubtitleStreams(in: part).map(\.id) == ["103", "104", "105", "106"])
        #expect(DownloadedMediaRecord.offlineSubtitleStreams(in: nil).isEmpty)
    }

    @Test func savedSubtitlesResolveAndAreDeletedWithTheRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadFileStore(rootDirectory: root)
        let body = try #require(SubtitleTextDecoder.normalizedFileData(Data("1\n00:00:00,000 --> 00:00:01,000\nHi\n".utf8)))

        let path = try store.saveSubtitle(body, globalKey: "profile:server-a:42", streamID: "103", fileExtension: "srt")
        #expect(path.hasPrefix("Subtitles/"))
        #expect(path.hasSuffix("/103.srt"))
        let url = try #require(store.existingFileURL(for: path))
        #expect(try Data(contentsOf: url) == body)
        // A sibling record's folder must survive the delete.
        let other = try store.saveSubtitle(body, globalKey: "profile:server-a:43", streamID: "1", fileExtension: "srt")

        // Re-keyed since the file was written: the stored path still wins.
        store.deleteSubtitles(relativePaths: [path], globalKey: "profile:server-b:42")
        #expect(store.existingFileURL(for: path) == nil)
        #expect(store.existingFileURL(for: other) != nil)
        #expect(FileManager.default.fileExists(atPath: store.subtitlesDirectory.path))
    }

    private func rawQueueItem(status: String = "processing", queueID: String = "7", progress: String? = "37.5") throws -> [String: Any] {
        let session = progress.map { ",\"TranscodeSession\":{\"progress\":\($0)}" } ?? ""
        let data = Data("{\"id\":\"23\",\"queueId\":\"\(queueID)\",\"key\":\"/library/metadata/42\",\"status\":\"\(status)\"\(session)}".utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func queueItem(status: String = "processing", queueID: String = "7", progress: String? = "37.5") throws -> PlexDownloadQueueItem {
        try PlexDownloadQueueResponse.item(rawQueueItem(status: status, queueID: queueID, progress: progress), queueID: "7")
    }

    private func decisionData(_ media: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [["Media": media]]]])
    }

    private func decisionMedia() -> [String: Any] {
        [
            "container": "mkv", "videoCodec": "h264", "audioCodec": "aac", "protocol": "http", "selected": true,
            "width": 1280, "height": 720, "audioChannels": 6,
            "Part": [[
                "container": "mkv", "protocol": "http", "decision": "transcode",
                "Stream": [["streamType": 1, "codec": "h264"], ["streamType": 2, "codec": "aac"]],
            ]],
        ]
    }

    private func sourceMedia() throws -> MediaVersion {
        let json = #"{"id":41,"container":"mkv","videoCodec":"hevc","audioCodec":"truehd","videoProfile":"main 10","audioProfile":"truehd atmos","width":3840,"height":2160,"duration":600000,"Part":[{"id":17,"key":"/library/parts/17/file.mkv","size":999999,"Stream":[{"id":101,"streamType":1,"codec":"hevc","DOVIPresent":true,"DOVIProfile":5},{"id":102,"streamType":2,"codec":"truehd"}]}]}"#
        return try JSONDecoder().decode(MediaVersion.self, from: Data(json.utf8))
    }
}
