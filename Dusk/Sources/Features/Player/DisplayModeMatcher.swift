import Foundation
import OSLog

#if os(tvOS)
import AVFoundation
import AVKit
import CoreMedia
import UIKit
#endif

private let displayModeLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "DisplayMode"
)

/// Asks tvOS to switch the Apple TV's output mode to the content's native frame
/// rate and dynamic range for the duration of a playback session.
///
/// Why this exists: without it the Apple TV stays in whatever mode the system UI
/// runs in — commonly 60 Hz, and commonly a fixed Dolby Vision/HDR format. Both
/// halves hurt, and both are visible on ordinary SDR 23.976 fps content:
///
/// - **Motion.** 23.976 fps into a 60 Hz output needs 3:2 pulldown, so frames
///   alternate between 2 and 3 refreshes (41.7 ms / 83.3 ms). That cadence is
///   the judder you see on slow pans. At a 23.976 Hz output every frame gets an
///   identical 41.7 ms.
/// - **Color.** When the box is pinned to an HDR format, SDR content is carried
///   inside an HDR container. AVPlayer's frames are tagged and survive that
///   conversion, but VLCKit renders into an untagged 8-bit RGBA UI-plane surface
///   (libvlc 3.0.x `modules/video_output/ios.m` uses `kEAGLColorFormatRGBA8` and
///   never tags the layer), so the compositor treats BT.709 video as sRGB and
///   maps it with the SDR-UI curve. The result is a raised black floor and
///   flatter, less saturated color. Switching the display to native SDR removes
///   the conversion entirely.
///
/// This is renderer-independent: it helps the VLCKit native drawable, the Metal
/// enhancement path, and AVPlayer alike, which is why it is applied for every
/// engine rather than only for one.
///
/// tvOS gates the switch behind Settings → Video and Audio → Match Content. When
/// the user has it off, `displayCriteriaMatchingEnabled` is false and setting a
/// criteria is a no-op; `statusLabel` reports that so Playback Info can explain
/// why nothing changed instead of looking broken.
@MainActor
enum DisplayModeMatcher {
    /// Human-readable outcome of the last `apply`/`reset`, surfaced in the
    /// Playback Info overlay.
    private(set) static var statusLabel: String = defaultStatusLabel

    #if os(tvOS)
    private static let defaultStatusLabel = "Inactive"
    #else
    private static let defaultStatusLabel = "tvOS only"
    #endif

    /// Requests the display mode that matches `part`'s video stream.
    ///
    /// Call this *before* the engine loads its source: the switch blanks the
    /// screen for a moment, and Apple's guidance is to complete it ahead of
    /// handing the player its item so the blank overlaps buffering rather than
    /// playback.
    static func apply(media: PlexMedia, part: PlexMediaPart, decision: PlaybackDecision) {
        #if os(tvOS)
        // AirPlay hands the stream to a different renderer entirely, so the
        // local box's output mode is not what the viewer is watching.
        if case .airPlay = decision {
            reset()
            statusLabel = "Not applied (AirPlay)"
            return
        }

        guard let displayManager = currentDisplayManager() else {
            statusLabel = "No display manager"
            return
        }

        guard displayManager.isDisplayCriteriaMatchingEnabled else {
            // Leave any previous criteria alone — tvOS is ignoring it anyway —
            // but tell the user where the switch lives.
            statusLabel = "Off in tvOS Settings (Video and Audio → Match Content)"
            displayModeLogger.notice("Display criteria matching is disabled in tvOS Settings; skipping")
            return
        }

        let videoStream = part.streams.first { $0.streamType == .video }
        guard let refreshRate = matchableRefreshRate(for: videoStream) else {
            statusLabel = "No frame rate in metadata"
            return
        }

        guard let formatDescription = makeFormatDescription(
            media: media,
            videoStream: videoStream
        ) else {
            statusLabel = "Could not describe video format"
            return
        }

        let criteria = AVDisplayCriteria(
            refreshRate: refreshRate,
            formatDescription: formatDescription
        )
        displayManager.preferredDisplayCriteria = criteria

        let rangeLabel = dynamicRangeLabel(for: videoStream)
        statusLabel = "\(formattedRate(refreshRate)) Hz \(rangeLabel)"
        displayModeLogger.notice(
            "Requested display mode \(formattedRate(refreshRate), privacy: .public) Hz \(rangeLabel, privacy: .public)"
        )
        #else
        _ = (media, part, decision)
        #endif
    }

    /// Returns the display to the system's default mode. Safe to call when no
    /// criteria was ever set.
    static func reset() {
        #if os(tvOS)
        guard let displayManager = currentDisplayManager() else {
            statusLabel = defaultStatusLabel
            return
        }
        if displayManager.preferredDisplayCriteria != nil {
            displayManager.preferredDisplayCriteria = nil
            displayModeLogger.notice("Released display mode back to the system default")
        }
        #endif
        statusLabel = defaultStatusLabel
    }

    #if os(tvOS)

    // MARK: - Display manager lookup

    private static func currentDisplayManager() -> AVDisplayManager? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        return window?.avDisplayManager
    }

    // MARK: - Refresh rate

    /// Plex reports the source frame rate directly, which is what the display
    /// should match. Values outside the plausible video range are treated as
    /// missing rather than passed through to `AVDisplayCriteria`.
    ///
    /// NTSC rates are deliberately NOT snapped to their integer neighbours: an
    /// exact 23.976 request is what makes a 24000/1001 file play without any
    /// cadence correction at all. tvOS picks the closest mode the TV actually
    /// supports, so an unsupported request degrades instead of failing.
    private static func matchableRefreshRate(for stream: PlexStream?) -> Float? {
        guard let frameRate = stream?.frameRate, frameRate >= 20, frameRate <= 120 else {
            return nil
        }
        return Float(frameRate)
    }

    private static func formattedRate(_ rate: Float) -> String {
        let rounded = (rate * 1000).rounded() / 1000
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.3f", rounded)
    }

    // MARK: - Format description

    /// Builds the `CMVideoFormatDescription` that `AVDisplayCriteria` reads the
    /// dynamic range from. Only the codec, dimensions, and the three color tags
    /// matter here — this description is never used to decode anything.
    private static func makeFormatDescription(
        media: PlexMedia,
        videoStream: PlexStream?
    ) -> CMVideoFormatDescription? {
        let width = media.width ?? videoStream?.width ?? 1920
        let height = media.height ?? videoStream?.height ?? 1080

        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: colorPrimaries(for: videoStream),
            kCMFormatDescriptionExtension_TransferFunction: transferFunction(for: videoStream),
            kCMFormatDescriptionExtension_YCbCrMatrix: yCbCrMatrix(for: videoStream),
        ]

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType(for: videoStream?.codec ?? media.videoCodec),
            width: Int32(clamping: width),
            height: Int32(clamping: height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr else {
            displayModeLogger.error("CMVideoFormatDescriptionCreate failed with status \(status, privacy: .public)")
            return nil
        }
        return formatDescription
    }

    private static func codecType(for codec: String?) -> CMVideoCodecType {
        switch codec?.lowercased() {
        case "hevc", "h265", "x265": kCMVideoCodecType_HEVC
        case "av1": kCMVideoCodecType_AV1
        case "vp9": kCMVideoCodecType_VP9
        default: kCMVideoCodecType_H264
        }
    }

    // MARK: - Color tags
    //
    // Plex passes ffprobe's spelling through largely untouched, so these match
    // on ffmpeg's names. Anything unrecognized falls back to BT.709, which is
    // correct for the overwhelming majority of a Plex library and keeps an
    // unknown value from being reported as HDR.

    private static func colorPrimaries(for stream: PlexStream?) -> CFString {
        switch stream?.colorPrimaries?.lowercased() {
        case "bt2020", "bt.2020":
            kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case "bt470bg":
            // PAL/SECAM primaries.
            kCMFormatDescriptionColorPrimaries_EBU_3213
        case "smpte170m", "smpte240m", "smpte-c":
            // NTSC primaries.
            kCMFormatDescriptionColorPrimaries_SMPTE_C
        default:
            kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        }
    }

    private static func transferFunction(for stream: PlexStream?) -> CFString {
        // The transfer characteristic is what actually decides SDR vs HDR here,
        // so it is read from the stream's own TRC rather than inferred from the
        // looser "is this HDR" heuristics used elsewhere.
        let trc = stream?.colorTrc?.lowercased() ?? ""
        if trc.contains("2084") || trc.contains("pq") {
            return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        }
        if trc.contains("hlg") || trc.contains("b67") {
            return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        }
        // Dolby Vision profiles that reach a local engine carry an HDR10 base
        // layer, so PQ is the right request even when the TRC field is absent.
        if stream?.doviPresent == true, (stream?.doviProfile ?? 0) != 5 {
            return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        }
        return kCMFormatDescriptionTransferFunction_ITU_R_709_2
    }

    private static func yCbCrMatrix(for stream: PlexStream?) -> CFString {
        switch stream?.colorSpace?.lowercased() {
        case let space? where space.contains("2020"):
            kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case "smpte170m", "bt470bg", "bt601":
            kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        default:
            kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        }
    }

    private static func dynamicRangeLabel(for stream: PlexStream?) -> String {
        let transfer = transferFunction(for: stream)
        if CFEqual(transfer, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ) {
            return stream?.doviPresent == true ? "Dolby Vision" : "HDR10 (PQ)"
        }
        if CFEqual(transfer, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG) {
            return "HLG"
        }
        return "SDR"
    }
    #endif
}
