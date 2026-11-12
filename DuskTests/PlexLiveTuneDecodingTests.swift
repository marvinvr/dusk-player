import Foundation
import Testing
@testable import Dusk

/// Plex Live TV through a Threadfin (HDHomeRun emulation) tuner on PMS 1.43:
/// the tune answer sends `Media.id`, `Part.id` and `Stream.id` as strings,
/// which dropped the whole Media and sent the stream to VLCKit as "unknown"
/// video. A busy one-tuner device answers with an errored grab instead.
@Suite("Plex Live TV tune decoding")
struct PlexLiveTuneDecodingTests {
    /// Trimmed from a real `POST /livetv/dvrs/12/channels/1000/tune` answer.
    private static let tuned = """
    {"MediaContainer":{"size":1,"MediaSubscription":[{"key":"111","type":4,"title":"This Episode",
      "channelIdentifier":"1000","MediaGrabOperation":[{"rolling":true,"mediaSubscriptionID":111,
      "mediaIndex":0,"id":"1000-AF80","grabberIdentifier":"tv.plex.grabbers.hdhomerun",
      "grabberProtocol":"livetv","percent":-1.0,"currentSize":0,"deviceID":14,"status":"inprogress",
      "Metadata":{"duration":10800000,"key":"/livetv/sessions/c83fb5ad-5720-40a6-9731-6beb44e38db9",
        "onAir":"1","ratingKey":"100001","title":"No live session","type":"movie",
        "Media":[{"audioChannels":2,"audioCodec":"aac","beginOffset":"1","beginsAt":1794431581,
          "channelIdentifier":"1000","container":"mpegts","endsAt":1794431881,"hasVoiceActivity":"0",
          "id":"222512","origin":"livetv","protocol":"hls","uuid":"c83fb5ad-5720-40a6-9731-6beb44e38db9",
          "videoCodec":"h264","videoResolution":"720",
          "Part":[{"container":"mpegts","id":"228619",
            "key":"/livetv/sessions/c83fb5ad-5720-40a6-9731-6beb44e38db9/AF80/index.m3u8?offset=-1.000000",
            "protocol":"hls","size":0,
            "Stream":[{"codec":"h264","frameRate":25.0,"height":720,"id":"919191","index":0,"level":31,
                       "profile":"constrained baseline","streamType":1,"width":1280},
                      {"audioChannelLayout":"stereo","bitrate":5,"channels":2,"codec":"aac","id":"919192",
                       "index":1,"profile":"lc","samplingRate":48000,"selected":true,"streamType":2}]}]}]}}]}]}}
    """

    /// A second F1 channel while the device's only tuner is in use.
    private static let conflict = """
    {"MediaContainer":{"size":1,"MediaSubscription":[{"key":"116","type":4,"channelIdentifier":"1001",
      "MediaGrabOperation":[{"rolling":true,"id":"1001-9507","grabberIdentifier":"tv.plex.grabbers.download",
        "grabberProtocol":"download","status":"error","error":"The recording conflicts with other recordings",
        "Metadata":{"title":"No live session","type":"movie","Media":[{"beginsAt":1794432284,"channelIdentifier":"1001","endsAt":1794432584}]},
        "Conflicts":{"rolling":true,"MediaGrabOperation":[{"id":"1000-D5AC","status":"inprogress","deviceID":14}]}}]}]}}
    """

    private func decode(_ json: String) throws -> PlexLiveTuneResponse {
        try JSONDecoder().decode(PlexLiveTuneResponse.self, from: Data(json.utf8))
    }

    @Test func stringIdentifiersKeepTheTunedMedia() throws {
        let session = try #require(try decode(Self.tuned).MediaContainer.tunedSession)
        #expect(session.sessionID == "c83fb5ad-5720-40a6-9731-6beb44e38db9")

        let tuneMedia = try #require(session.media)
        let media = tuneMedia.makeMedia(sessionPath: session.sessionPath)
        #expect(media.id == 222512)
        #expect(media.videoCodec == "h264")
        #expect(media.audioCodec == "aac")
        let part = try #require(media.parts.first)
        #expect(part.id == 228619)
        #expect(part.streams.map(\.id) == [919191, 919192])
        #expect(part.streams.first?.profile == "constrained baseline")
    }

    @Test func tunedH264AACPlaysThroughAVPlayer() throws {
        let session = try #require(try decode(Self.tuned).MediaContainer.tunedSession)
        let media = try #require(session.media).makeMedia(sessionPath: session.sessionPath)
        #expect(StreamResolver.evaluateLiveTV(media: media).engine == .avPlayer)
    }

    @Test func codecLessLiveMediaIsNotSentToVLCKit() {
        let part = PlexMediaPart(
            id: 0, key: "/livetv/sessions/x", file: nil, size: nil, container: "mpegts",
            duration: nil, videoProfile: nil, audioProfile: nil, accessible: true, exists: true, streams: []
        )
        let media = PlexMedia(
            id: 0, container: "hls", videoCodec: nil, audioCodec: nil, videoResolution: nil,
            videoProfile: nil, audioProfile: nil, audioChannels: nil, width: nil, height: nil,
            bitrate: nil, duration: nil, optimizedForStreaming: nil, parts: [part]
        )
        #expect(StreamResolver.evaluateLiveTV(media: media).engine == .avPlayer)
    }

    @Test func tunerConflictExplainsBusyTuners() throws {
        let container = try decode(Self.conflict).MediaContainer
        #expect(container.tunedSession == nil)
        let message = try #require(container.tuneFailureMessage)
        #expect(message.contains("tuners are in use"))
    }
}

/// A cold Plex Live TV tune with `X-Plex-Incomplete-Segments=1` opens with a
/// media playlist holding one `#EXTINF:0.000000` segment, on which AVPlayer
/// hangs forever without reloading or failing.
@Suite("Plex Live TV transcode request")
@MainActor
struct PlexLiveTVTranscodeRequestTests {
    @Test func liveTVNeverAsksForIncompleteSegments() {
        let names = query(sourcePath: "/livetv/sessions/c83fb5ad-5720-40a6-9731-6beb44e38db9")
        #expect(names["X-Plex-Incomplete-Segments"] == nil)
        #expect(names["offset"] == "-1")
        #expect(names["copyts"] == "0")
    }

    @Test func libraryTranscodesKeepIncompleteSegments() {
        let names = query(sourcePath: nil)
        #expect(names["X-Plex-Incomplete-Segments"] == "1")
        #expect(names["offset"] == nil)
    }

    private func query(sourcePath: String?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: PlexService().transcodeQueryItems(
            ratingKey: "1", mediaIndex: 0, sourcePath: sourcePath, mode: .directStreamFallback,
            sessionIdentifier: "session", transcodeSessionID: "transcode",
            audioStreamID: nil, subtitleStreamID: nil, token: nil
        ).map { ($0.name, $0.value ?? "") })
    }
}
