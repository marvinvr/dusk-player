import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Dusk

/// J-05 (docs/jellyfin/05-plan.md): direct play, playback reports, watched
/// state, markers, trickplay previews, sidecars and track positions, over the
/// jellyfin-demo fixtures and the semantics measured on jellyfin-demo 12.4
/// (every `/Sessions/Playing` counts a play; a 95 % stop marks played once;
/// a report without track indexes keeps the remembered ones).
@MainActor
@Suite("Jellyfin playback")
struct JellyfinPlaybackTests {
    static let serverID = "feedfacefeedfacefeedfacefeedface"
    static let knivesOut = "980dffd6dfa0d8cfd69e5bd6b350e983"
    static let office = "bf695ca96f49ed398033495d141110b4"

    private func client(_ base: String = "http://jellyfin.example:8096",
                        transport: any JellyfinTransport = JellyfinRecordingTransport()) -> JellyfinClient {
        JellyfinClient(
            baseURL: URL(string: base)!,
            identity: JellyfinClientIdentity(client: "Dusk", device: "iPhone", deviceID: "device-1", version: "2.0.0"),
            credentials: JellyfinCredentials(accessToken: "secret-token", userID: "user-1"),
            transport: transport
        )
    }

    private func details(_ name: String) throws -> MediaDetails {
        JellyfinItemMapper.mapDetails(try JellyfinFixtures.decode(JellyfinItemDTO.self, name), serverID: Self.serverID)
    }

    private func report(
        _ state: PlaybackReport.State,
        at positionMs: Int = 600_000,
        session: String? = "session-1",
        audio: String? = "2",
        subtitle: String? = PlaybackReport.subtitlesOff
    ) -> PlaybackReport {
        PlaybackReport(
            item: MediaItemID(serverID: Self.serverID, itemID: Self.knivesOut),
            state: state, positionMs: positionMs, durationMs: 7_817_000,
            sessionID: session, versionID: Self.knivesOut, playMethod: .directPlay,
            audioStreamID: audio, subtitleStreamID: subtitle
        )
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Direct play and sidecars

    @Test("direct play is the stored file with byte ranges, the token as ApiKey")
    func directPlayURL() throws {
        let part = try #require(try details("item-knives-out").media.first?.parts.first)
        let url = try #require(JellyfinPlayback.authenticatedURL(forServerPath: part.key, client: client()))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/Videos/\(Self.knivesOut)/stream")
        #expect(components.queryItems?.map(\.name) == ["static", "mediaSourceId", "ApiKey"])
        #expect(components.queryItems?.first { $0.name == "mediaSourceId" }?.value == Self.knivesOut)
        #expect(components.queryItems?.first { $0.name == "ApiKey" }?.value == "secret-token")

        let proxied = try #require(JellyfinPlayback.authenticatedURL(forServerPath: part.key, client: client("https://example.org/jf")))
        #expect(proxied.path == "/jf/Videos/\(Self.knivesOut)/stream")
    }

    @Test("an external subtitle is served in its own format; VobSub has no file")
    func sidecarFormats() throws {
        let stream = try #require(try details("item-av1-sdr-test-2026").media.first?.parts.first?.streams
            .first { $0.kind == .subtitle })
        let key = try #require(stream.key)
        #expect(key.hasSuffix("/Subtitles/0/0/Stream.srt"))
        let url = try #require(JellyfinPlayback.authenticatedURL(forServerPath: key, client: client()))
        #expect(url.query == "ApiKey=secret-token")

        #expect(JellyfinMediaMapper.sidecarFormat(codec: "ass") == "ass")
        #expect(JellyfinMediaMapper.sidecarFormat(codec: "pgs") == "sup")
        #expect(JellyfinMediaMapper.sidecarFormat(codec: nil) == "srt")
        #expect(JellyfinMediaMapper.servableSidecarFormats.contains("ass"))
        #expect(!JellyfinMediaMapper.servableSidecarFormats.contains(JellyfinMediaMapper.sidecarFormat(codec: "vobsub")))
    }

    @Test("the token stays on its host and over HTTPS once it is there")
    func credentialPolicy() throws {
        let policy = JellyfinCredentialPolicy.shared
        let withKey = URLRequest(url: URL(string: "http://jellyfin.example/Videos/x/stream?ApiKey=t")!)
        var withHeader = URLRequest(url: URL(string: "https://jellyfin.example/Items")!)
        withHeader.setValue(#"MediaBrowser Client="Dusk", Token="t""#, forHTTPHeaderField: "Authorization")
        #expect(policy.carriesCredential(withKey))
        #expect(policy.carriesCredential(withHeader))
        #expect(!policy.carriesCredential(URLRequest(url: URL(string: "http://jellyfin.example/x?api=1")!)))
        #expect(throws: Never.self) { try policy.validate(withKey) }
        #expect(throws: (any Error).self) {
            try policy.validate(URLRequest(url: URL(string: "file:///tmp/x?ApiKey=t")!))
        }
        let elsewhere = URLRequest(url: URL(string: "http://other.example/x")!)
        #expect(!policy.allowsRedirect(elsewhere, original: withKey))
        let downgrade = URLRequest(url: URL(string: "http://jellyfin.example/Items")!)
        #expect(!policy.allowsRedirect(downgrade, original: withHeader))
        #expect(policy.allowsRedirect(URLRequest(url: URL(string: "http://jellyfin.example/y?ApiKey=t")!), original: withKey))
    }

    // MARK: Reports

    @Test("a progress report carries the source, session, ticks and tracks; off is -1")
    func progressBody() throws {
        let (start, progress) = JellyfinPlaybackSessions.requests(for: report(.paused))
        #expect(start.path == "/Sessions/Playing")
        #expect(progress.path == "/Sessions/Playing/Progress")
        let body = try json(try progress.body.map { try JellyfinJSON.encode($0.make(JellyfinRequestContext(userID: "user-1"))) })
        #expect(body["ItemId"] as? String == Self.knivesOut)
        #expect(body["MediaSourceId"] as? String == Self.knivesOut)
        #expect(body["PlaySessionId"] as? String == "session-1")
        #expect(body["PositionTicks"] as? Int == 6_000_000_000)
        #expect(body["IsPaused"] as? Bool == true)
        #expect(body["EventName"] as? String == "Pause")
        #expect(body["PlayMethod"] as? String == "DirectPlay")
        #expect(body["AudioStreamIndex"] as? Int == 2)
        #expect(body["SubtitleStreamIndex"] as? Int == -1)
    }

    @Test("unknown tracks are left out, so the remembered ones stay; stopped carries no event")
    func stoppedBody() throws {
        let event = report(.stopped, audio: nil, subtitle: nil)
        let (_, stopped) = JellyfinPlaybackSessions.requests(for: event)
        #expect(stopped.path == "/Sessions/Playing/Stopped")
        let body = try json(try stopped.body.map { try JellyfinJSON.encode($0.make(JellyfinRequestContext(userID: nil))) })
        #expect(body["EventName"] == nil)
        #expect(body["AudioStreamIndex"] == nil)
        #expect(body["SubtitleStreamIndex"] == nil)
        #expect(body["PositionTicks"] as? Int == 6_000_000_000)
    }

    @Test("a session is opened once, however many reports and engines follow")
    func opensOnce() async throws {
        let transport = JellyfinRecordingTransport()
        let sessions = JellyfinPlaybackSessions()
        let client = client(transport: transport)
        for state in [PlaybackReport.State.buffering, .progress, .paused, .progress, .stopped, .progress] {
            try await sessions.send(report(state), client: client)
        }
        #expect(transport.paths == [
            "/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Progress",
            "/Sessions/Playing/Progress", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped",
            "/Sessions/Playing/Progress",
        ])
    }

    @Test("a failed opening is retried by the next report; a stop alone opens nothing")
    func retriesOpening() async throws {
        let transport = JellyfinRecordingTransport(failing: ["/Sessions/Playing"])
        let sessions = JellyfinPlaybackSessions()
        let client = client(transport: transport)
        await #expect(throws: (any Error).self) { try await sessions.send(report(.progress), client: client) }
        #expect(!sessions.isOpen("session-1"))
        transport.failing = []
        try await sessions.send(report(.progress), client: client)
        try await sessions.send(report(.stopped, session: "session-2"), client: client)
        #expect(transport.paths == [
            "/Sessions/Playing", "/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped",
        ])
    }

    @Test("play methods")
    func playMethods() {
        #expect(JellyfinPlaybackSessions.playMethod(.directStream) == .directStream)
        #expect(JellyfinPlaybackSessions.playMethod(.transcode) == .transcode)
        #expect(JellyfinPlaybackSessions.playMethod(nil) == .directPlay)
        #expect(PlaybackCoordinator.reportedPlayMethod(for: .directPlay) == .directPlay)
        #expect(PlaybackCoordinator.reportedPlayMethod(for: .spatialAudio) == .directStream)
        #expect(PlaybackCoordinator.reportedPlayMethod(for: .transcode(.p1080_8Mbps)) == .transcode)
        #expect(PlaybackCoordinator.reportedPlayMethod(for: .liveTV) == nil)
    }

    // MARK: Details and markers

    @Test("details carry the episode's intro and credits from MediaSegments")
    func detailsWithMarkers() async throws {
        let transport = JellyfinRecordingTransport(routes: [
            "/Items/\(Self.office)": try JellyfinFixtures.data("item-the-office-s01e01"),
            "/MediaSegments/\(Self.office)": try JellyfinFixtures.data("media-segments-the-office-s01e01"),
        ])
        let details = try await JellyfinItemDetails.load(itemID: Self.office, serverID: Self.serverID, client: client(transport: transport))
        #expect(details.markers.map(\.type) == ["intro", "credits"])
        #expect(details.markers.first?.startTimeOffset == 0)
        #expect(details.markers.first?.endTimeOffset == 54_555)
        #expect(details.markers.last?.startTimeOffset == 1_372_746)
        #expect(details.markers.last?.endTimeOffset == 1_405_162)
        #expect(details.markers.allSatisfy { $0.skipButtonTitle != nil })
        #expect(Set(transport.paths) == ["/Items/\(Self.office)", "/MediaSegments/\(Self.office)"])
    }

    @Test("no segments means no skip buttons, not a failed load")
    func detailsWithoutSegments() async throws {
        let transport = JellyfinRecordingTransport(routes: [
            "/Items/\(Self.office)": try JellyfinFixtures.data("item-the-office-s01e01"),
        ], failing: ["/MediaSegments/\(Self.office)"])
        let details = try await JellyfinItemDetails.load(itemID: Self.office, serverID: Self.serverID, client: client(transport: transport))
        #expect(details.markers.isEmpty)
        #expect(details.itemID == Self.office)
        #expect(details.media.first?.parts.first?.id == Self.office)
    }

    // MARK: Trickplay

    @Test("the 320 px rendition of the playing source, in sheets of 100")
    func rendition() throws {
        let item = try JellyfinFixtures.decode(JellyfinItemDTO.self, "item-knives-out")
        let info = try #require(JellyfinTrickplay.rendition(in: item.trickplay, sourceID: Self.knivesOut))
        #expect(info.width == 320)
        #expect(JellyfinTrickplay.sheetCount(info) == 8)
        #expect(JellyfinTrickplay.rendition(in: item.trickplay, sourceID: Self.office) == nil)
        // Dashed and plain spellings are the same id.
        #expect(JellyfinTrickplay.rendition(in: item.trickplay, sourceID: "980dffd6-dfa0-d8cf-d69e-5bd6b350e983") != nil)
    }

    @Test("thumbnails are cut row by row; the short last sheet and a missing sheet are handled")
    func frames() throws {
        // 3 × 2 tiles of 16 × 16 px (whole JPEG blocks), 9 thumbnails: one
        // full sheet, then one row.
        let info = try JellyfinJSON.decode(JellyfinTrickplayInfoDTO.self, from: Data(#"""
        {"Width":16,"Height":16,"TileWidth":3,"TileHeight":2,"ThumbnailCount":9,"Interval":10000}
        """#.utf8))
        #expect(JellyfinTrickplay.sheetCount(info) == 2)
        let first = try sheet(columns: 3, rows: 2, tile: (16, 16), firstValue: 0)
        let second = try sheet(columns: 3, rows: 1, tile: (16, 16), firstValue: 6)
        let frames = JellyfinTrickplay.frames(from: [
            .init(index: 0, data: first), .init(index: 1, data: second),
        ], info: info)
        #expect(frames.map(\.timestampMs) == (0..<9).map { Int64($0) * 10_000 })
        #expect(try frames.map(redValue) == (0..<9).map { $0 * 25 })
        let set = ScrubPreviewFrameSet(frames: frames)
        #expect(set.frame(at: 45)?.timestampMs == 40_000)

        let withGap = JellyfinTrickplay.frames(from: [.init(index: 0, data: nil), .init(index: 1, data: second)], info: info)
        #expect(withGap.map(\.timestampMs) == [60_000, 70_000, 80_000])
    }

    /// A JPEG sheet whose tile `n` is filled with red `(firstValue + n) × 25`.
    private func sheet(columns: Int, rows: Int, tile: (Int, Int), firstValue: Int) throws -> Data {
        let width = columns * tile.0, height = rows * tile.1
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        for row in 0..<rows {
            for column in 0..<columns {
                let value = CGFloat((firstValue + row * columns + column) * 25) / 255
                context.setFillColor(red: value, green: 0, blue: 0, alpha: 1)
                // Core Graphics counts rows from the bottom.
                context.fill(CGRect(x: column * tile.0, y: height - (row + 1) * tile.1, width: tile.0, height: tile.1))
            }
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The red of a frame's centre pixel, rounded to the nearest 25.
    private func redValue(_ frame: ScrubPreviewFrame) throws -> Int {
        let source = try #require(CGImageSourceCreateWithData(frame.imageData as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return Int((Double(pixel[0]) / 25).rounded()) * 25
    }

    // MARK: Engine tracks

    @Test("engine tracks map to stream indexes by position among embedded streams")
    func embeddedPositions() throws {
        let part = try #require(try details("item-knives-out").media.first?.parts.first)
        let model = PlayerViewModel(engine: TrackListEngine())
        defer { model.cleanup() }
        model.sourcePart = part

        let embeddedSubtitles = part.streams.filter { $0.kind == .subtitle && $0.key == nil }
        // What VLCKit lists: its own ids and its own labels, container order.
        let engineSubtitles = embeddedSubtitles.enumerated().map { offset, stream in
            SubtitleTrack(id: 100 + offset, displayTitle: "Track \(offset + 1)", language: nil,
                          languageCode: stream.languageTag, codec: nil, isForced: false,
                          isHearingImpaired: false, isExternal: false, externalURL: nil)
        }
        let merged = model.mergeSubtitleMetadata(into: engineSubtitles)
        #expect(merged.map(\.plexStreamID) == embeddedSubtitles.map(\.id))
        #expect(merged.prefix(3).map(\.plexStreamID) == ["4", "5", "6"])

        let audio = part.streams.filter { $0.kind == .audio }
        let engineAudio = audio.enumerated().map { offset, stream in
            AudioTrack(id: 200 + offset, displayTitle: "Track \(offset + 1)", language: nil,
                       languageCode: stream.languageTag, codec: nil, channels: nil, channelLayout: nil)
        }
        #expect(model.mergeAudioMetadata(into: engineAudio).map(\.plexStreamID) == ["1", "2", "3"])
        #expect(JellyfinStreamPositions.position(ofIndex: 4, kind: .subtitle, in: part) == 0)
    }

    @Test("an external subtitle at index 0 shifts no engine track")
    func externalAtIndexZero() throws {
        let part = try #require(try details("item-av1-sdr-test-2026").media.first?.parts.first)
        let model = PlayerViewModel(engine: TrackListEngine())
        defer { model.cleanup() }
        model.sourcePart = part
        let engineAudio = [
            AudioTrack(id: 1, displayTitle: "Track 1", language: nil, languageCode: "en", codec: nil, channels: nil, channelLayout: nil),
            AudioTrack(id: 2, displayTitle: "Track 2", language: nil, languageCode: "de", codec: nil, channels: nil, channelLayout: nil),
        ]
        #expect(model.mergeAudioMetadata(into: engineAudio).map(\.plexStreamID) == ["2", "3"])
        #expect(model.mergeSubtitleMetadata(into: []).isEmpty)
        #expect(JellyfinStreamPositions.position(ofIndex: 0, kind: .subtitle, in: part) == nil)
        #expect(JellyfinStreamPositions.index(atPosition: 0, kind: .audio, in: part) == 2)
    }
}

/// Records request paths and answers from a route table: a known path gets
/// its body, a failing one a 500, anything else `{}`.
final class JellyfinRecordingTransport: JellyfinTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var failingPaths: Set<String>
    private let routes: [String: Data]

    init(routes: [String: Data] = [:], failing: Set<String> = []) {
        self.routes = routes
        self.failingPaths = failing
    }

    var paths: [String] { lock.withLock { recorded } }

    var failing: Set<String> {
        get { lock.withLock { failingPaths } }
        set { lock.withLock { failingPaths = newValue } }
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        let fails = lock.withLock {
            recorded.append(path)
            return failingPaths.contains(path)
        }
        let status = fails ? 500 : (routes[path] == nil && request.httpMethod == "POST" ? 204 : 200)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (fails ? Data() : routes[path] ?? Data("{}".utf8), response)
    }
}

/// Lists no tracks and never loads anything.
@MainActor
private final class TrackListEngine: PlaybackEngine {
    var state = PlaybackState.playing
    let currentTime: TimeInterval = 0
    let duration: TimeInterval = 120
    let isBuffering = false
    let error: PlaybackError? = nil
    let videoEnhancementStatus = VideoEnhancementStatus.disabled
    var onPlaybackEnded: (@MainActor () -> Void)?
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    private let player = AVPlayer()
    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }

    func load(source: PlaybackSource) {}
    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {}
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Float) {}
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
