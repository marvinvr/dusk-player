#if os(tvOS)
import TVVLCKit
import UIKit

final class TVOSVLCKitRenderingHost: NSObject, VLCKitRenderingHost, @unchecked Sendable {
    let playerView: UIView

    @MainActor
    override init() {
        self.playerView = UIView()
        super.init()
        playerView.backgroundColor = .black
        playerView.clipsToBounds = true
    }

    func attach(to player: VLCMediaPlayer, engine: VLCKitEngine) {
        player.drawable = playerView
    }

    func detach(from player: VLCMediaPlayer) {
        player.drawable = nil
    }

    func updatePlaybackState(
        currentTimeMs: Int64,
        durationMs: Int64,
        isPlaying: Bool,
        isSeekable: Bool
    ) {}

    func invalidatePlaybackState() {}

    // The zoom-to-fill control is iOS/iPadOS only.
    func setVideoFillEnabled(_ enabled: Bool) {}
}
#endif
