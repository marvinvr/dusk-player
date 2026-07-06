#if os(iOS)
import MobileVLCKit
import UIKit

/// iOS/iPadOS rendering host for the shared VLCKit playback core.
///
/// VLCKit 3.x renders straight into a plain `UIView` drawable. Zoom-to-fill is
/// applied through libvlc's crop geometry, re-applied on every layout pass so
/// rotation keeps the crop matched to the drawable's aspect ratio.
///
/// Note: VLCKit 3.x has no drawable-native Picture in Picture (that was a 4.x
/// feature). VLC PiP is provided by the sample-buffer output on the Video
/// Enhancement path instead; see `VLCKitEnhancedPictureInPicture.swift`.
final class IOSVLCKitRenderingHost: NSObject, VLCKitRenderingHost, @unchecked Sendable {
    let playerView: UIView

    private weak var mediaPlayer: VLCMediaPlayer?
    private var aspectFillEnabled = false

    @MainActor
    override init() {
        let container = IOSVLCRendererContainerView()
        self.playerView = container
        super.init()
        container.backgroundColor = .black
        container.clipsToBounds = true
        // The crop geometry that fills the screen depends on the drawable's
        // aspect ratio, so re-apply it whenever the view lays out (rotation).
        container.onLayout = { [weak self] in
            self?.applyVideoCropGeometry()
        }
    }

    func attach(to player: VLCMediaPlayer, engine: VLCKitEngine) {
        mediaPlayer = player
        player.drawable = playerView
        applyVideoCropGeometry()
    }

    func detach(from player: VLCMediaPlayer) {
        mediaPlayer = nil
        player.drawable = nil
    }

    func updatePlaybackState(
        currentTimeMs: Int64,
        durationMs: Int64,
        isPlaying: Bool,
        isSeekable: Bool
    ) {}

    func invalidatePlaybackState() {}

    func setVideoFillEnabled(_ enabled: Bool) {
        MainActor.assumeIsolated {
            aspectFillEnabled = enabled
            applyVideoCropGeometry()
        }
    }

    /// Crops the video to the drawable's aspect ratio (so it fills the screen
    /// with no letterbox/pillarbox) when zoom is on, otherwise clears the crop
    /// so the whole frame is shown. libvlc copies the geometry string, so the
    /// `withCString` scope is safe.
    private func applyVideoCropGeometry() {
        MainActor.assumeIsolated {
            guard let mediaPlayer else { return }
            if aspectFillEnabled {
                let bounds = playerView.bounds
                let width = max(1, Int(bounds.width.rounded()))
                let height = max(1, Int(bounds.height.rounded()))
                "\(width):\(height)".withCString { geometry in
                    mediaPlayer.videoCropGeometry = UnsafeMutablePointer(mutating: geometry)
                }
            } else {
                mediaPlayer.videoCropGeometry = nil
            }
        }
    }
}

private final class IOSVLCRendererContainerView: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
#endif
