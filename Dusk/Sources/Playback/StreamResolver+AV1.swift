import Foundation
import VideoToolbox
import Darwin

/// Runtime capability is authoritative; simulator results describe the Mac,
/// never the named iPhone/iPad/Apple TV. Injected in routing/profile tests.
struct AV1PlaybackCapabilities: Sendable {
    let hardwareDecode: Bool
    let softwareDecode: Bool
    let supports1080pSoftware: Bool

    static let current = AV1PlaybackCapabilities(
        hardwareDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
        softwareDecode: VLCKitBuildInfo.decodesAV1,
        supports1080pSoftware: supportsSoftwareDecode(machine: machineIdentifier)
    )

    // A14+ phones/tablets, A12+ Apple TVs. Deliberately conservative: this is
    // a startup budget, not a benchmark or a promise for every AV1 encode.
    static func supportsSoftwareDecode(machine: String) -> Bool {
        #if targetEnvironment(simulator)
        if machine == "arm64" || machine == "x86_64" { return true }
        #endif
        for (prefix, minimum) in [("iPhone", 13), ("iPad", 13), ("AppleTV", 11)] {
            if machine.hasPrefix(prefix),
               let generation = Int(machine.dropFirst(prefix.count).split(separator: ",").first ?? "") {
                return generation >= minimum
            }
        }
        return false
    }

    private static var machineIdentifier: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

extension StreamResolver {
    static func containsAV1(_ media: MediaVersion) -> Bool {
        isAV1Codec(media.videoCodec) || media.parts.flatMap(\.streams).contains {
            $0.streamType == .video && isAV1Codec($0.codec)
        }
    }

    static func isAV1Codec(_ codec: String?) -> Bool {
        ["av1", "av01"].contains(codec?.lowercased() ?? "")
    }

    static func av1Decision(for media: MediaVersion, capabilities: AV1PlaybackCapabilities) -> Decision? {
        guard containsAV1(media) else { return nil }
        let videos = media.parts.flatMap(\.streams).filter { $0.streamType == .video }
        let hasHDR = videos.contains {
            let tags = [$0.colorSpace, $0.colorPrimaries, $0.colorTrc, $0.profile].compactMap { $0?.lowercased() }
            let hdrTags = tags.contains { tag in
                ["2020", "pq", "hlg", "hdr", "dovi", "dolby"].contains { tag.contains($0) }
            }
            let knownSDR = ["bt709", "smpte170m", "smpte240m", "gamma22", "gamma28", "iec61966-2-1"]
                .contains($0.colorTrc?.lowercased() ?? "")
            return hdrTags || hdrTransfer(of: $0) != nil || $0.doviPresent == true ||
                $0.doviProfile != nil || $0.doviBLCompatID != nil || $0.doviLevel != nil ||
                (($0.bitDepth ?? 8) > 8 && !knownSDR)
        }
        let supportedProfile = videos.allSatisfy {
            ($0.bitDepth ?? 8) <= 10 && $0.doviPresent != true && $0.doviProfile == nil && $0.doviBLCompatID == nil && $0.doviLevel == nil &&
                ($0.chromaSubsampling == nil || ["4:2:0", "420"].contains($0.chromaSubsampling!))
        }
        if capabilities.hardwareDecode && supportedProfile {
            // Inspect the complete container/audio/subtitle combination too.
            // Hardware AV1 must never fall into VLC because an MKV or a track
            // is incompatible with AVPlayer. Plex can package/convert tracks.
            let local = localAV1ContainerDecision(media)
            return Decision(engine: .avPlayer,
                            reason: local ? "AV1 hardware decode: native direct play" : "AV1 hardware decode requires Plex fMP4 remux",
                            requiresServerTranscode: !local)
        }
        let fitsSoftwareBudget = !videos.isEmpty && videos.allSatisfy { stream in
            guard let width = stream.width ?? media.width,
                  let height = stream.height ?? media.height,
                  width > 0, height > 0 else { return false }
            return max(width, height) <= 1920 && min(width, height) <= 1080 &&
                (stream.frameRate ?? 30) <= 30 &&
                (stream.bitrate ?? media.bitrate ?? 0) <= 20_000
        }
        if !hasHDR && supportedProfile && capabilities.softwareDecode &&
            capabilities.supports1080pSoftware && fitsSoftwareBudget {
            return Decision(engine: .vlcKit, reason: "AV1 SDR within 1080p/30 software budget: VLCKit dav1d")
        }
        return Decision(engine: .avPlayer,
                        reason: "AV1 requires Plex video conversion (HDR, decoder capability or software budget)",
                        requiresServerTranscode: true)
    }

    private static func localAV1ContainerDecision(_ media: MediaVersion) -> Bool {
        guard ["mp4", "mov", "m4v"].contains(media.container?.lowercased() ?? "") else { return false }
        let audio = media.parts.flatMap(\.streams).filter { $0.streamType == .audio }
        let audioCodecs = audio.isEmpty ? [media.audioCodec].compactMap { $0 } : audio.map { $0.codec ?? media.audioCodec ?? "" }
        return audioCodecs.allSatisfy { ["aac", "ac3", "eac3", "alac", "mp3", "flac"].contains($0.lowercased()) } &&
            media.parts.flatMap(\.streams).filter { $0.streamType == .subtitle }.allSatisfy {
                ["tx3g", "mov_text"].contains($0.codec?.lowercased() ?? "")
            }
    }

    static func canCopyAV1Audio(_ stream: MediaStream) -> Bool {
        ["aac", "eac3", "ac3", "flac", "alac", "mp3"].contains(stream.codec?.lowercased() ?? "")
    }

    static func canRemuxAV1(_ media: MediaVersion, capabilities: AV1PlaybackCapabilities = .current) -> Bool {
        containsAV1(media) && capabilities.hardwareDecode &&
            media.parts.flatMap(\.streams).filter { $0.streamType == .video }.allSatisfy {
                isAV1Codec($0.codec ?? media.videoCodec) && ($0.bitDepth ?? 8) <= 10 &&
                    $0.doviPresent != true && $0.doviProfile == nil && $0.doviBLCompatID == nil && $0.doviLevel == nil &&
                    ($0.chromaSubsampling == nil || ["4:2:0", "420"].contains($0.chromaSubsampling!))
            }
    }
}
