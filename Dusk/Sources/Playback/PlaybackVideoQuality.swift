import Foundation

/// What the viewer is actually watching right now, as opposed to what the Plex
/// metadata says about the source file. Engines publish what they can measure
/// (`PlaybackEngine.currentVideoQuality`); `PlaybackDebugInfo.currentVideoQuality(live:)`
/// fills the gaps from Plex only when the session copies the source's video.
struct PlaybackVideoQuality: Equatable, Sendable {
    /// Only reported once measured (or for VLCKit, which only draws SDR):
    /// unknown stays nil.
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
    /// `3840×2160 (4K) · 23.976 fps · HEVC · Dolby Vision 8.1 · 42.1 Mbps`. Nil when nothing
    /// is known yet.
    var summary: String? {
        let parts = [
            resolutionLabel,
            frameRateLabel,
            codec,
            dynamicRange,
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

    /// libvlc's demux rate (bytes per microsecond) as bits per second, or nil
    /// when it can't be a real reading. Must filter: `-[VLCMedia statistics]`
    /// ignores whether `libvlc_media_get_stats` succeeded, so for an item with no
    /// input yet (a queued time tick just after a media swap) it returns
    /// uninitialized stack memory. That can read as a huge float, and `Int()` of
    /// one traps.
    static func bitsPerSecond(fromVLCDemuxRate rate: Float) -> Double? {
        guard rate.isFinite, rate > 0 else { return nil }
        let bitsPerSecond = Double(rate) * 8_000_000
        return bitsPerSecond <= 10_000_000_000 ? bitsPerSecond : nil
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
        case "av01", "av1", "dav1": return "AV1"
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
        case "dvh1", "dvhe", "dva1", "dvav", "dav1": true
        default: false
        }
    }

    /// The dynamic range AVPlayer is putting on screen, from what it reports
    /// about the playing variant and track, e.g. `Dolby Vision 8.1`,
    /// `Dolby Vision 8.1 (from profile 7)`, `HDR10`, `SDR`. Nil until it has
    /// measured anything. HDR10+ reads HDR10: its metadata is per frame and
    /// nothing describing the track or variant carries it.
    static func dynamicRange(for signals: AVPlayerDynamicRangeSignals) -> String? {
        let transfer = signals.trackTransfer ?? signals.variantTransfer
        guard signals.hasTrack || !signals.variantCodecs.isEmpty || transfer != nil else { return nil }

        var label: String?
        var isHDR = transfer == .pq || transfer == .hlg
        if let dolbyVision = dolbyVisionPlaying(signals, transfer: transfer) {
            label = dolbyVision.displayName
            isHDR = true
        } else if signals.trackCodecs.contains(where: isDolbyVisionCodec)
                    || (!signals.hasTrack && signals.variantCodecs.contains(where: isDolbyVisionCodec)) {
            // A Dolby Vision sample entry whose configuration isn't readable.
            label = dolbyVisionLabel
            isHDR = true
        } else {
            switch transfer {
            case .pq: label = hdr10Label
            case .hlg: label = hlgLabel
            case .sdr: label = sdrLabel
            case nil: label = nil
            }
        }
        guard let label else { return nil }
        // Same words as VLCKit's: the source is HDR, the screen gets SDR.
        return isHDR && !signals.displaySupportsHDR ? "\(label) (SDR output)" : label
    }

    /// The track's own Dolby Vision configuration when it has one Apple
    /// decodes; before the track is readable, the signaling the session
    /// declared for the variant (`SUPPLEMENTAL-CODECS` / a `dvh1` CODECS).
    /// Once the track is there it alone decides: a remux that fell back to an
    /// unsignaled item plays its base layer.
    private static func dolbyVisionPlaying(
        _ signals: AVPlayerDynamicRangeSignals,
        transfer: AVPlayerDynamicRangeSignals.Transfer?
    ) -> DolbyVisionConfiguration? {
        let declared = signals.declaredDolbyVision
        if signals.hasTrack {
            guard let record = signals.dolbyVisionRecord.flatMap(DolbyVisionRecord.init(data:)),
                  record.isDecodedByApple else { return nil }
            // A converted 8.1 keeps saying where it came from.
            let convertedFrom = declared.flatMap { declared in
                declared.profile == record.profile && declared.blSignalCompatibilityID == record.compatibilityID
                    ? declared.convertedFromProfile : nil
            }
            return DolbyVisionConfiguration(
                profile: record.profile,
                level: record.level,
                blSignalCompatibilityID: record.compatibilityID,
                lumaSampleRate: nil,
                lumaPictureSize: nil,
                bitrateKbps: nil,
                convertedFromProfile: convertedFrom
            )
        }
        guard let declared, transfer != .sdr else { return nil }
        return declared
    }
}

/// What AVPlayer reports about the picture it plays, gathered by
/// `AVPlayerEngine` for `PlaybackVideoQuality.dynamicRange(for:)`.
struct AVPlayerDynamicRangeSignals: Equatable, Sendable {
    enum Transfer: Sendable { case sdr, pq, hlg }

    /// The playing HLS variant's `CODECS`, as FourCCs.
    var variantCodecs: [String] = []
    /// The variant's `VIDEO-RANGE`.
    var variantTransfer: Transfer?
    /// The video track's format description has loaded (HLS: once segments
    /// arrive). From then on the track's facts win over the playlist's.
    var hasTrack = false
    var trackCodecs: [String] = []
    /// The track's transfer function; SDR when untagged.
    var trackTransfer: Transfer?
    /// The payload of the track's `dvcC` / `dvvC` / `dvwC` box.
    var dolbyVisionRecord: Data?
    /// The Dolby Vision signaling the loaded source restores or converts to
    /// (`PlaybackSource.dolbyVision7Conversion ?? dolbyVisionRemux`).
    var declaredDolbyVision: DolbyVisionConfiguration?
    /// `AVPlayer.eligibleForHDRPlayback`.
    var displaySupportsHDR = true
}

/// A Dolby Vision decoder configuration record (`dvcC`/`dvvC`/`dvwC`):
/// version (2 bytes), then profile (7 bits), level (6), rpu/el/bl present
/// flags (3), then the base layer compatibility ID (4).
struct DolbyVisionRecord: Equatable, Sendable {
    let profile: Int
    let level: Int
    let compatibilityID: Int

    init?(data: Data) {
        let bytes = [UInt8](data.prefix(5))
        guard bytes.count == 5 else { return nil }
        profile = Int(bytes[2] >> 1)
        level = Int((bytes[2] & 0x01) << 5 | bytes[3] >> 3)
        compatibilityID = Int(bytes[4] >> 4)
    }

    /// Profiles Apple renders as Dolby Vision. Anything else (7, 8.2, 8.6)
    /// plays its base layer.
    var isDecodedByApple: Bool {
        switch (profile, compatibilityID) {
        case (5, _), (8, 1), (8, 4), (10, _): true
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
        var live = live ?? PlaybackVideoQuality()
        switch decision {
        case .directPlay, .localDownload, .spatialAudio:
            break
        case .transcode, .serverStream, .airPlay, .liveTV:
            if engine == .vlcKit, !live.isEmpty {
                live.dynamicRange = live.dynamicRange ?? PlaybackVideoQuality.sdrLabel
            }
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
                  let transfer = StreamResolver.hdrTransfer(of: stream) else { return PlaybackVideoQuality.sdrLabel }
            let label = transfer == .hlg ? PlaybackVideoQuality.hlgLabel : PlaybackVideoQuality.hdr10Label
            return "\(label) (SDR output)"
        }
        // AVPlayer measures what it plays (`PlaybackVideoQuality.dynamicRange(for:)`);
        // the file's metadata says nothing about whether Dolby Vision survived
        // the remux, so it never stands in.
        return live
    }
}
