#if DEBUG
import Foundation

/// DEBUG-only: `-DuskDebugPlayItem <itemID>` plays that item of the connected
/// server once, with its resume point as Continue Watching would
/// (`-DuskDebugPlayOffset <seconds>` starts there instead). For simulator
/// checks of a server whose browse screens are not built yet. Add
/// `-DuskScreenshotMute 1` to keep the run silent.
enum DebugPlaybackLink {
    @MainActor private static var hasPlayed = false

    @MainActor
    static func playRequestedItem(media: MediaService, playback: PlaybackCoordinator) async {
        let defaults = UserDefaults.standard
        guard !hasPlayed, let itemID = defaults.string(forKey: "DuskDebugPlayItem")?.nilIfEmpty else { return }
        for _ in 0..<120 {
            if let serverID = media.pool.primary?.serverID,
               let details = try? await media.getMediaDetails(itemID: itemID, serverID: serverID) {
                guard !hasPlayed else { return }
                hasPlayed = true
                let offset = defaults.object(forKey: "DuskDebugPlayOffset") == nil
                    ? details.resumeOffsetMs
                    : Int(defaults.double(forKey: "DuskDebugPlayOffset") * 1000)
                await playback.play(
                    id: MediaItemID(serverID: serverID, itemID: itemID),
                    resumeOffsetMilliseconds: offset,
                    resumeOffsetDurationMilliseconds: details.duration
                )
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
    }
}
#endif
