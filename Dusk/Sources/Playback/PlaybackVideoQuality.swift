import Foundation

/// What the viewer is actually watching right now, as opposed to what the Plex
/// metadata says about the source file. Engines publish what they can measure
/// (`PlaybackEngine.currentVideoQuality`); `PlaybackDebugInfo.currentVideoQuality(live:)`
/// fills the gaps from Plex only when the session copies the source's video.
struct PlaybackVideoQuality: Equatable, Sendable {
    /// Reported for SDR so "known SDR" stays distinct from "unknown" when
    /// merging; `summary` leaves it out.
    static let sdrLabel = "SDR"
    static let hdr10Label = "HDR10"
    static let hlgLabel = "HLG"
    static let dolbyVisionLabel = "Dolby Vision"

    var width: Int?
    var height: Int?
    var frameRate: Double?
    /// Display name, e.g. `HEVC` (see `codecName(for:)`).
    var codec: String?
    /// Display label, e.g. `HDR10`, or `sdrLabel`.
    var dynamicRange: String?
    /// Bits per second.
    var bitrate: Int?
    /// The bitrate was measured from the data flowing through the engine
    /// rather than declared by the stream, so it wanders and Plex's figure for
    /// a copied source is better.
    var bitrateIsEstimate = false

    var isEmpty: Bool {
        width == nil && height == nil && frameRate == nil && codec == nil
            && dynamicRange == nil && bitrate == nil
    }

    /// The compact line the player shows, e.g.
    /// `3840×2160 (4K) · 23.976 fps · HEVC · HDR10 · 42.1 Mbps`. Nil when nothing
    /// is known yet.
    var summary: String? {
        let parts = [
            resolutionLabel,
            frameRateLabel,
            codec,
            dynamicRange == Self.sdrLabel ? nil : dynamicRange,
            bitrateLabel,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var resolutionLabel: String? {
        guard let height else { return nil }
        guard let width else { return "\(height)p" }
        // Width first: a 2.39:1 UHD film is 3840×1600.
        let isUHD = width >= 3_200 || height >= 1_800
        return isUHD ? "\(width)×\(height) (4K)" : "\(width)×\(height)"
    }

    var frameRateLabel: String? {
        guard let frameRate else { return nil }
        let rounded = (frameRate * 1_000).rounded() / 1_000
        let digits = rounded == rounded.rounded() ? 0 : (rounded * 100 == (rounded * 100).rounded() ? 2 : 3)
        return String(format: "%.\(digits)f fps", rounded)
    }

    var bitrateLabel: String? {
        guard let bitrate, bitrate > 0 else { return nil }
        let prefix = bitrateIsEstimate ? "~" : ""
        if bitrate >= 1_000_000 {
            return prefix + String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
        }
        return prefix + "\(bitrate / 1_000) kbps"
    }

    /// Keeps a measured bitrate from rewriting the observed property (and every
    /// view reading it) on each sample: under a 10% move it holds the old value.
    func holdingEstimatedBitrate(from previous: PlaybackVideoQuality?) -> PlaybackVideoQuality {
        guard bitrateIsEstimate, let bitrate,
              let previous, previous.bitrateIsEstimate, let held = previous.bitrate, held > 0,
              abs(Double(bitrate - held)) / Double(held) < 0.1 else { return self }
        var result = self
        result.bitrate = held
        return result
    }

    /// Measured rates wobble around the real one (23.98, 24.02…); this snaps
    /// them to the broadcast/cinema rate they belong to. Zero (paused, nothing
    /// decoded yet) is no information.
    static func snappedFrameRate(_ measured: Double) -> Double? {
        guard measured.isFinite, measured > 1 else { return nil }
        let standard = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100, 119.88, 120]
        if let nearest = standard.min(by: { abs($0 - measured) < abs($1 - measured) }),
           abs(nearest - measured) <= 0.02 * max(1, nearest / 24) {
            return nearest
        }
        return measured.rounded()
    }

    /// A display name for a Plex codec name, a CoreMedia subtype or a libvlc
    /// FourCC, which all spell the same codecs differently. Dolby Vision's
    /// sample entries name the base codec here; the dynamic range says DV.
    static func codecName(for rawValue: String?) -> String? {
        let raw = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }
        switch raw {
        case "avc1", "avc3", "h264", "x264", "avc", "dva1", "dvav": return "H.264"
        case "hvc1", "hev1", "hevc", "h265", "x265", "dvh1", "dvhe": return "HEVC"
        case "av01", "av1": return "AV1"
        case "vp09", "vp90", "vp9": return "VP9"
        case "vp08", "vp80", "vp8": return "VP8"
        case "mp2v", "mpgv", "mpeg2", "mpeg2video": return "MPEG-2"
        case "mp1v", "mpeg1", "mpeg1video": return "MPEG-1"
        case "mp4v", "fmp4", "xvid", "divx", "dx50", "mpeg4": return "MPEG-4"
        case "vc-1", "wvc1", "vc1": return "VC-1"
        case "wmv3", "wmv2", "wmv1": return raw.uppercased()
        case "ap4x", "ap4h", "apch", "apcn", "apcs", "apco": return "ProRes"
        default: return raw.uppercased()
        }
    }

    /// Whether a CoreMedia subtype / HLS codec is a Dolby Vision sample entry.
    static func isDolbyVisionCodec(_ rawValue: String?) -> Bool {
        switch rawValue?.lowercased() {
        case "dvh1", "dvhe", "dva1", "dvav": true
        default: false
        }
    }
}

extension PlaybackDebugInfo {
    /// The engine's measurements, completed from Plex where the session copies
    /// the source's video untouched. A transcode, conversion or live tune plays
    /// something Plex's metadata doesn't describe, so those stay live-only:
    /// showing nothing beats showing the source's resolution for a 720p stream.
    func currentVideoQuality(live: PlaybackVideoQuality?) -> PlaybackVideoQuality {
        let live = live ?? PlaybackVideoQuality()
        switch decision {
        case .directPlay, .localDownload, .spatialAudio:
            break
        case .transcode, .serverStream, .airPlay, .liveTV:
            return live
        }

        let stream = part.streams.first { $0.streamType == .video }
        var quality = live
        quality.width = live.width ?? stream?.width ?? media.width
        quality.height = live.height ?? stream?.height ?? media.height
        quality.frameRate = live.frameRate ?? stream?.frameRate
        quality.codec = live.codec
            ?? PlaybackVideoQuality.codecName(for: stream?.codec ?? media.videoCodec)
        quality.dynamicRange = dynamicRange(live: live.dynamicRange)

        if live.bitrate == nil || live.bitrateIsEstimate,
           let kilobits = media.bitrate ?? stream?.bitrate {
            quality.bitrate = kilobits * 1_000
            quality.bitrateIsEstimate = false
        }
        return quality
    }

    private func dynamicRange(live: String?) -> String? {
        // libvlc draws into an 8-bit, untagged surface, so an HDR source
        // reaches the screen as SDR, and only its base layer ever plays.
        if engine == .vlcKit {
            guard let stream = part.streams.first(where: { $0.streamType == .video }),
                  let transfer = StreamResolver.hdrTransfer(of: stream) else { return live }
            let label = transfer == .hlg ? PlaybackVideoQuality.hlgLabel : PlaybackVideoQuality.hdr10Label
            return "\(label) (SDR output)"
        }

        let sourceIsHDR = media.parts.lazy.flatMap(\.streams).contains(where: StreamResolver.isRemuxableHDRVideo)
        guard let live else {
            return sourceIsHDR ? StreamResolver.hdrVideoLabel(for: media) : nil
        }
        // AVPlayer knows it is on Dolby Vision; Plex knows which profile. A
        // base-layer label would contradict it (DV7 converted to 8.1), and a
        // live HDR10 is the failed-conversion retry, which plays exactly that.
        if live == PlaybackVideoQuality.dolbyVisionLabel, sourceIsHDR {
            let source = StreamResolver.hdrVideoLabel(for: media)
            if source.hasPrefix(PlaybackVideoQuality.dolbyVisionLabel), !source.contains("base layer") {
                return source
            }
        }
        return live
    }
}
