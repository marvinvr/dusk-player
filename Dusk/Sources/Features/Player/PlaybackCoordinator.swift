import Foundation
import SwiftUI

/// Orchestrates the "play an item" flow: fetch metadata → resolve engine →
/// construct URL → present player → report timeline → scrobble.
///
/// Injected into the environment so any view can trigger playback via
/// `coordinator.play(ratingKey:)`. The player is presented as a full-screen
/// cover in MainTabView.
@MainActor @Observable
final class PlaybackCoordinator {

    // MARK: - Public State

    /// When true, the full-screen player cover is presented.
    var showPlayer = false

    /// True while fetching metadata / creating the engine.
    private(set) var isLoading = false

    /// Non-nil if metadata fetch or engine creation failed.
    private(set) var loadError: String?

    /// The active engine (set after successful load, nil otherwise).
    private(set) var engine: (any PlaybackEngine)?

    /// Snapshot of the currently playing media for the debug overlay.
    private(set) var debugInfo: PlaybackDebugInfo?

    /// The media source to load once the player view is attached.
    private(set) var playbackSource: PlaybackSource?

    // MARK: - Private

    private let plexService: PlexService
    private let preferences: UserPreferences
    private var ratingKey: String?
    private var hasScrobbled = false

    /// Most recent position captured by the timeline timer (ms).
    private var lastReportedTimeMs = 0
    private var lastReportedDurationMs = 0

    @ObservationIgnored nonisolated(unsafe) private var timelineTimer: Timer?

    // MARK: - Init

    init(plexService: PlexService, preferences: UserPreferences = UserPreferences()) {
        self.plexService = plexService
        self.preferences = preferences
    }

    deinit {
        timelineTimer?.invalidate()
    }

    // MARK: - Play an Item

    /// Full "play an item" flow: fetch details → pick engine → build URL → present.
    func play(ratingKey: String) async {
        self.ratingKey = ratingKey
        isLoading = true
        loadError = nil
        debugInfo = nil
        playbackSource = nil
        hasScrobbled = false
        lastReportedTimeMs = 0
        lastReportedDurationMs = 0

        do {
            let details = try await plexService.getMediaDetails(ratingKey: ratingKey)

            guard let media = details.media.first,
                  let part = media.parts.first else {
                loadError = "No playable media found."
                isLoading = false
                return
            }

            guard let url = plexService.directPlayURL(for: part) else {
                loadError = "Could not construct playback URL."
                isLoading = false
                return
            }

            let engineType = StreamResolver.resolve(
                media: media,
                forceAVPlayer: preferences.forceAVPlayer,
                forceVLCKit: preferences.forceVLCKit
            )

            // Create engine via StreamResolver + factory, respecting user preference
            let newEngine = PlaybackEngineFactory.makeEngine(
                for: media,
                forceAVPlayer: preferences.forceAVPlayer,
                forceVLCKit: preferences.forceVLCKit
            )

            engine = newEngine
            playbackSource = PlaybackSource(
                url: url,
                startPosition: details.viewOffset.map { TimeInterval($0) / 1000.0 }
            )
            debugInfo = PlaybackDebugInfo(
                title: details.title,
                engine: engineType,
                decision: .directPlay,
                media: media,
                part: part
            )
            isLoading = false
            showPlayer = true

            // Begin periodic progress reporting to Plex
            startTimelineReporting()
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    /// Called when the full-screen player cover is dismissed.
    /// Sends a final "stopped" timeline, scrobbles if needed, and tears down.
    func onPlayerDismissed() {
        // Report final "stopped" state using last captured position
        if let ratingKey {
            let timeMs = lastReportedTimeMs
            let durationMs = lastReportedDurationMs
            Task {
                await plexService.reportTimeline(
                    ratingKey: ratingKey,
                    state: .stopped,
                    timeMs: timeMs,
                    durationMs: durationMs
                )
            }
        }

        timelineTimer?.invalidate()
        timelineTimer = nil
        engine = nil
        debugInfo = nil
        playbackSource = nil
        ratingKey = nil
        showPlayer = false
    }

    /// Dismiss any loading error so the UI can return to normal.
    func clearError() {
        loadError = nil
    }

    // MARK: - Timeline Reporting

    private func startTimelineReporting() {
        timelineTimer?.invalidate()
        timelineTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reportCurrentTimeline()
            }
        }
    }

    private func reportCurrentTimeline() {
        guard let engine, let ratingKey else { return }

        let timeMs = Int(engine.currentTime * 1000)
        let durationMs = Int(engine.duration * 1000)

        // Store for final report on dismiss
        lastReportedTimeMs = timeMs
        lastReportedDurationMs = durationMs

        let plexState: PlaybackState
        switch engine.state {
        case .playing: plexState = .playing
        case .paused: plexState = .paused
        default: return // Don't report idle/loading/stopped/error
        }

        Task {
            await plexService.reportTimeline(
                ratingKey: ratingKey,
                state: plexState,
                timeMs: timeMs,
                durationMs: durationMs
            )
        }

        // Scrobble at >90% watched
        if !hasScrobbled, durationMs > 0, timeMs > Int(Double(durationMs) * 0.9) {
            hasScrobbled = true
            Task {
                try? await plexService.scrobble(ratingKey: ratingKey)
            }
        }
    }
}

struct PlaybackSource: Sendable {
    let url: URL
    let startPosition: TimeInterval?
}

struct PlaybackDebugInfo: Sendable {
    let title: String
    let engine: PlaybackEngineType
    let decision: PlaybackDecision
    let media: PlexMedia
    let part: PlexMediaPart

    var engineLabel: String {
        switch engine {
        case .avPlayer: "AVPlayer"
        case .vlcKit: "VLCKit"
        }
    }

    var transcodeLabel: String {
        "No"
    }

    var directPlayLabel: String {
        "Yes"
    }

    var decisionLabel: String {
        switch decision {
        case .directPlay: "Direct Play"
        }
    }

    var containerLabel: String {
        (part.container ?? media.container ?? "Unknown").uppercased()
    }

    var resolutionLabel: String {
        if let width = media.width, let height = media.height {
            return "\(width)x\(height)"
        }
        if let height = media.height {
            return "\(height)p"
        }
        if let resolution = media.videoResolution {
            return resolution.uppercased()
        }
        return "Unknown"
    }

    var bitrateLabel: String {
        if let bitrate = media.bitrate {
            return Self.formatBitrateKbps(bitrate)
        }
        if let bitrate = selectedVideoStream?.bitrate {
            return Self.formatBitrateKbps(bitrate)
        }
        return "Unknown"
    }

    var videoLabel: String {
        let codec = media.videoCodec?.uppercased() ?? selectedVideoStream?.codec?.uppercased() ?? "Unknown"
        if let profile = media.videoProfile?.uppercased() {
            return "\(codec) (\(profile))"
        }
        return codec
    }

    var audioLabel: String {
        let codec = media.audioCodec?.uppercased() ?? selectedAudioStream?.codec?.uppercased() ?? "Unknown"
        let channels = media.audioChannels ?? selectedAudioStream?.channels
        if let channels {
            return "\(codec) \(channels)ch"
        }
        return codec
    }

    var fileSizeLabel: String {
        guard let size = part.size else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var subtitleLabel: String {
        guard let subtitle = selectedSubtitleStream else { return "None" }
        return subtitle.extendedDisplayTitle ?? subtitle.displayTitle ?? subtitle.codec?.uppercased() ?? "Selected"
    }

    private var selectedVideoStream: PlexStream? {
        part.streams.first { $0.streamType == .video }
    }

    private var selectedAudioStream: PlexStream? {
        part.streams.first { $0.streamType == .audio && ($0.isSelected ?? false) }
            ?? part.streams.first { $0.streamType == .audio }
    }

    private var selectedSubtitleStream: PlexStream? {
        part.streams.first { $0.streamType == .subtitle && ($0.isSelected ?? false) }
    }

    private static func formatBitrateKbps(_ value: Int) -> String {
        if value >= 1_000 {
            return String(format: "%.1f Mbps", Double(value) / 1_000.0)
        }
        return "\(value) kbps"
    }
}

enum PlaybackDecision: Sendable {
    case directPlay
}
