import AVFoundation
import Foundation
import OSLog

private let hevcProbeLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "HEVCSampleEntryProbe"
)

/// Reads the sample-entry tag (`hvc1` / `hev1`) of an MP4/MOV file's video
/// track. Plex reports both as `hevc`, but AVPlayer shows no picture for
/// `hev1` (audio plays, no error), so the coordinator asks before it hands
/// an HEVC MP4 to AVPlayer (`StreamResolver.needsHEVCSampleEntryProbe`).
///
/// AVFoundation reads only the `moov` box (wherever it sits) to answer, and
/// results are remembered per file for the app's lifetime. Any failure or a
/// timeout answers nil, which keeps today's AVPlayer direct play.
@MainActor
enum HEVCSampleEntryProbe {
    private static var cache: [String: String] = [:]

    /// - Parameter cacheKey: identifies the file (server + part, or the
    ///   local path); the URL itself carries a token and is not used.
    static func sampleEntry(
        of url: URL,
        cacheKey: String,
        timeout: Duration = .seconds(4)
    ) async -> String? {
        if let cached = cache[cacheKey] { return cached }
        let started = ContinuousClock.now
        let asset = AVURLAsset(url: url)
        let timer = Task {
            try? await Task.sleep(for: timeout)
            asset.cancelLoading()
        }
        defer { timer.cancel() }
        guard let entry = await videoSampleEntry(of: asset) else {
            hevcProbeLogger.notice("No video sample entry for \(cacheKey, privacy: .public) (timeout or unreadable)")
            return nil
        }
        cache[cacheKey] = entry
        hevcProbeLogger.notice(
            "Video sample entry \(entry, privacy: .public) for \(cacheKey, privacy: .public) in \(String(describing: ContinuousClock.now - started), privacy: .public)"
        )
        return entry
    }

    private static func videoSampleEntry(of asset: AVURLAsset) async -> String? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let description = try? await track.load(.formatDescriptions).first else {
            return nil
        }
        return fourCharacterCode(CMFormatDescriptionGetMediaSubType(description))
    }

    nonisolated static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
