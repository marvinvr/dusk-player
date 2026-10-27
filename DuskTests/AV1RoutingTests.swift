import Foundation
import Testing
@testable import Dusk

@Suite("AV1 routing and Plex capabilities")
@MainActor
struct AV1RoutingTests {
    private let hardware = AV1PlaybackCapabilities(hardwareDecode: true, softwareDecode: true, supports1080pSoftware: true)
    private let software = AV1PlaybackCapabilities(hardwareDecode: false, softwareDecode: true, supports1080pSoftware: true)
    private let oldDevice = AV1PlaybackCapabilities(hardwareDecode: false, softwareDecode: true, supports1080pSoftware: false)
    private let missingDecoder = AV1PlaybackCapabilities(hardwareDecode: false, softwareDecode: false, supports1080pSoftware: true)

    @Test(arguments: ["mp4", "mov", "m4v"])
    func hardwareNativeContainer(container: String) throws {
        let decision = StreamResolver.evaluate(media: try media(container: container), av1Capabilities: hardware)
        #expect(decision.engine == .avPlayer)
        #expect(!decision.requiresServerTranscode)
    }

    @Test(arguments: ["bt709", "smpte2084", "arib-std-b67"])
    func hardwareMKVRequiresRemux(transfer: String) throws {
        let source = try media(transfer: transfer)
        let decision = StreamResolver.evaluate(media: source, av1Capabilities: hardware)
        #expect(decision.engine == .avPlayer)
        #expect(decision.requiresServerTranscode)
        #expect(StreamResolver.canRemuxAV1(source, capabilities: hardware))
    }

    @Test(arguments: ["mkv", "mp4"])
    func software1080pSDR(container: String) throws {
        let decision = StreamResolver.evaluate(media: try media(container: container), av1Capabilities: software)
        #expect(decision.engine == .vlcKit)
        #expect(!decision.requiresServerTranscode)
    }

    @Test(arguments: ["smpte2084", "arib-std-b67"])
    func noHardwareHDRNeverUsesVLC(transfer: String) throws {
        let source = try media(transfer: transfer)
        let decision = StreamResolver.evaluate(media: source, forceVLCKit: true, av1Capabilities: software)
        #expect(decision.engine == .avPlayer)
        #expect(decision.requiresServerTranscode)
        #expect(!StreamResolver.canRemuxAV1(source, capabilities: software))
    }

    @Test func softwareBudgetRequiresConversion() throws {
        for source in [try media(width: 3840, height: 2160), try media(fps: 60), try media(width: 0), try media(bitrate: 30_000)] {
            #expect(StreamResolver.evaluate(media: source, av1Capabilities: software).requiresServerTranscode)
        }
    }

    @Test func olderOrMissingDecoderRequiresConversion() throws {
        for capability in [oldDevice, missingDecoder] {
            let decision = StreamResolver.evaluate(media: try media(), av1Capabilities: capability)
            #expect(decision.engine == .avPlayer)
            #expect(decision.requiresServerTranscode)
        }
    }

    @Test func unsupportedNativeTracksUseServer() throws {
        for source in [try media(container: "mp4", audio: "opus"), try media(container: "mp4", subtitle: "pgs")] {
            #expect(StreamResolver.evaluate(media: source, av1Capabilities: hardware).requiresServerTranscode)
        }
    }

    @Test func conservativeDeviceGenerations() {
        for machine in ["iPhone13,1", "iPad13,1", "AppleTV11,1", "AppleTV14,1"] {
            #expect(AV1PlaybackCapabilities.supportsSoftwareDecode(machine: machine))
        }
        for machine in ["iPhone12,1", "iPad11,1", "AppleTV6,2", "unknown"] {
            #expect(!AV1PlaybackCapabilities.supportsSoftwareDecode(machine: machine))
        }
    }

    @Test func av1CopyProfileOnlyAdvertisesHardwareCapability() {
        for capability in [hardware, software] {
            let query = query(mode: .spatialAudioRemux(convertsAudio: false), capabilities: capability)
            let profile = query["X-Plex-Client-Profile-Extra"] ?? ""
            #expect(profile.contains("videoCodec=hevc,h264,av1") == capability.hardwareDecode)
            #expect(query["directStream"] == "1")
            #expect(query["directStreamAudio"] == "1")
            #expect(query["subtitles"] == "auto")
            #expect(query["audioStreamID"] == "2")
            #expect(query["subtitleStreamID"] == "3")
            #expect(query["maxVideoBitrate"] == nil)
        }
    }

    @Test func decoderFallbackAlwaysReencodesWithoutQualityCap() {
        for capability in [hardware, software] {
            let query = query(mode: .av1Transcode, capabilities: capability)
            let profile = query["X-Plex-Client-Profile-Extra"] ?? ""
            #expect(!profile.contains("av1"))
            #expect(profile.contains("container=mp4&videoCodec=hevc,h264"))
            #expect(query["directStream"] == "0")
            #expect(query["subtitles"] == "burn")
            #expect(query["audioStreamID"] == "2")
            #expect(query["maxVideoBitrate"] == nil)
            #expect(query["videoResolution"] == nil)
        }
    }

    @Test func loadedDuskBuildHasDav1d() {
        if VLCKitBuildInfo.duskBuild?.hasPrefix("3.7.3-dusk") == true {
            #expect(VLCKitBuildInfo.decodesAV1)
        }
    }

    @Test func copyableLosslessAudioDoesNotNeedConversion() throws {
        for codec in ["flac", "alac", "aac", "eac3"] {
            let source = try media(audio: codec)
            #expect(StreamResolver.canCopyAV1Audio(source.parts[0].streams[1]))
        }
        let source = try media(audio: "truehd")
        #expect(!StreamResolver.canCopyAV1Audio(source.parts[0].streams[1]))
    }

    private func query(mode: PlexService.TranscodeDeliveryMode, capabilities: AV1PlaybackCapabilities) -> [String: String] {
        Dictionary(uniqueKeysWithValues: PlexService().transcodeQueryItems(
            ratingKey: "1", mediaIndex: 0, sourcePath: nil, mode: mode,
            sessionIdentifier: "session", transcodeSessionID: "transcode",
            audioStreamID: 2, subtitleStreamID: 3, token: nil, av1Capabilities: capabilities
        ).map { ($0.name, $0.value ?? "") })
    }

    private func media(container: String = "mkv", width: Int = 1920, height: Int = 1080,
                       transfer: String = "bt709", fps: Int = 24, bitrate: Int = 5000,
                       audio: String = "aac", subtitle: String? = nil) throws -> PlexMedia {
        let subs = subtitle.map { ", {\"id\":3,\"streamType\":3,\"codec\":\"\($0)\"}" } ?? ""
        return try JSONDecoder().decode(PlexMedia.self, from: Data("""
        {"id":1,"container":"\(container)","videoCodec":"av1","audioCodec":"\(audio)",
         "width":\(width),"height":\(height),"bitrate":\(bitrate),"Part":[{"id":1,"key":"/sample","Stream":[
         {"id":1,"streamType":1,"codec":"av1","width":\(width),"height":\(height),
          "colorTrc":"\(transfer)","frameRate":\(fps),"bitDepth":10},
         {"id":2,"streamType":2,"codec":"\(audio)","channels":2}\(subs)]}]}
        """.utf8))
    }
}
