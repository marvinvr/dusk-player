import Foundation

/// Local resume points for IPTV catch-up programmes (`IPTVResumeStore`).
/// Plex keeps the resume point of everything else; these never leave the
/// device. Saved on pause, when the app leaves the foreground, when the
/// session ends, and every ~20 s while playing.
extension PlaybackCoordinator {
    static let iptvResumeSaveInterval: TimeInterval = 20

    /// Where to offer resuming a past IPTV programme from, if anywhere.
    func iptvResumePosition(channel: PlexLiveChannel, program: PlexLiveProgram) -> TimeInterval? {
        IPTVResumeKey(channel: channel, program: program).flatMap { IPTVResumeStore.shared.resumePosition(for: $0) }
    }

    /// The timeline tick: saves at most every `iptvResumeSaveInterval`.
    func saveIPTVResumePointIfDue() {
        guard activeIPTVResumeKey != nil else { return }
        if let last = iptvResumeLastSavedAt, Date.now.timeIntervalSince(last) < Self.iptvResumeSaveInterval { return }
        saveIPTVResumePoint()
    }

    /// The engine's position now. Skipped while it opens or seeks: a
    /// loading engine can report 0, which must not replace a resume point.
    func saveIPTVResumePoint() {
        guard let engine, engine.state == .playing || engine.state == .paused else { return }
        saveIPTVResumePoint(position: engine.currentTime, duration: engine.duration)
    }

    /// The session's final position (`finalizeCurrentPlaybackSession`).
    func saveIPTVResumePoint(timeMs: Int, durationMs: Int) {
        guard timeMs > 0 else { return }
        saveIPTVResumePoint(position: TimeInterval(timeMs) / 1000, duration: TimeInterval(durationMs) / 1000)
    }

    private func saveIPTVResumePoint(position: TimeInterval, duration: TimeInterval) {
        guard let key = activeIPTVResumeKey else { return }
        iptvResumeLastSavedAt = .now
        IPTVResumeStore.shared.record(position: position, duration: duration, for: key)
    }
}
