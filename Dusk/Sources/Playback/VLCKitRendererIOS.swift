#if os(iOS)
import UIKit
import VLCKit

final class IOSVLCKitRenderingHost: NSObject, VLCKitRenderingHost, @unchecked Sendable, VLCDrawable, VLCPictureInPictureDrawable, VLCPictureInPictureMediaControlling {
    let playerView: UIView

    private weak var mediaPlayer: VLCMediaPlayer?
    private var pictureInPictureController: (any VLCPictureInPictureWindowControlling)?
    private var hostedVideoView: UIView?
    private var currentTimeMs: Int64 = 0
    private var durationMs: Int64 = 0
    private var mediaPlaying = false
    private var mediaSeekable = false
    private var notificationObservers: [NSObjectProtocol] = []

    private var playHandler: (() -> Void)?
    private var pauseHandler: (() -> Void)?
    private var seekHandler: ((Int64, @escaping () -> Void) -> Void)?
    private var aspectFillEnabled = false

    /// VLCKit vends the window controller asynchronously once its native PiP
    /// pipeline is ready; until then PiP cannot be started.
    var isPictureInPictureReady: Bool { pictureInPictureController != nil }
    /// Fires when `isPictureInPictureReady` flips so the engine can republish an
    /// observable "PiP possible" flag for the button.
    var onPictureInPictureReadyChanged: (@MainActor () -> Void)?
    /// Fires when the floating window starts (`true`) or stops (`false`).
    var onPictureInPictureActiveChanged: (@MainActor (Bool) -> Void)?

    @MainActor
    override init() {
        let container = IOSVLCPictureInPictureContainerView()
        self.playerView = container
        super.init()
        container.backgroundColor = .black
        // The crop ratio that fills the screen depends on the drawable's aspect
        // ratio, so re-apply it whenever the view lays out (e.g. on rotation).
        container.onLayout = { [weak self] in
            self?.applyVideoCropRatio()
        }
    }

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to player: VLCMediaPlayer, engine: VLCKitEngine) {
        mediaPlayer = player
        playHandler = { [weak engine] in
            Task { @MainActor [weak engine] in
                engine?.play()
            }
        }
        pauseHandler = { [weak engine] in
            Task { @MainActor [weak engine] in
                engine?.pause()
            }
        }
        seekHandler = { [weak engine] offsetMs, completion in
            guard engine != nil else {
                completion()
                return
            }

            Task { @MainActor [weak engine] in
                guard let engine else { return }
                let targetSeconds = max(0, engine.currentTime + (TimeInterval(offsetMs) / 1000.0))
                engine.seek(to: targetSeconds)
            }

            completion()
        }

        player.drawable = self
        applyVideoCropRatio()
    }

    func detach(from player: VLCMediaPlayer) {
        mediaPlayer = nil
        player.drawable = nil
        playHandler = nil
        pauseHandler = nil
        seekHandler = nil
        // The window controller is only vended after playback starts, so it is
        // already nil here (detach runs on video-enhancement enable or deinit).
        // Readiness changes are reported from `pictureInPictureReady` instead.
        pictureInPictureController = nil
    }

    func updatePlaybackState(
        currentTimeMs: Int64,
        durationMs: Int64,
        isPlaying: Bool,
        isSeekable: Bool
    ) {
        self.currentTimeMs = currentTimeMs
        self.durationMs = durationMs
        self.mediaPlaying = isPlaying
        self.mediaSeekable = isSeekable
    }

    func invalidatePlaybackState() {
        pictureInPictureController?.invalidatePlaybackState()
    }

    func startPictureInPicture() {
        pictureInPictureController?.startPictureInPicture()
    }

    func stopPictureInPicture() {
        pictureInPictureController?.stopPictureInPicture()
    }

    func setVideoFillEnabled(_ enabled: Bool) {
        MainActor.assumeIsolated {
            aspectFillEnabled = enabled
            applyVideoCropRatio()
        }
    }

    /// Crops the video to the drawable's aspect ratio (so it fills the screen
    /// with no letterbox/pillarbox) when zoom is on, otherwise clears the crop
    /// so the whole frame is shown. Passing 0/0 resets VLCKit's crop ratio.
    private func applyVideoCropRatio() {
        MainActor.assumeIsolated {
            guard let mediaPlayer else { return }
            if aspectFillEnabled {
                let bounds = playerView.bounds
                let width = UInt32(max(1, Int(bounds.width.rounded())))
                let height = UInt32(max(1, Int(bounds.height.rounded())))
                mediaPlayer.setCropRatioWithNumerator(width, denominator: height)
            } else {
                mediaPlayer.setCropRatioWithNumerator(0, denominator: 0)
            }
        }
    }

    func addSubview(_ view: UIView) {
        MainActor.assumeIsolated {
            if hostedVideoView !== view {
                hostedVideoView?.removeFromSuperview()
                hostedVideoView = view
                view.frame = playerView.bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                playerView.addSubview(view)
            }
        }
    }

    func bounds() -> CGRect {
        MainActor.assumeIsolated {
            playerView.bounds
        }
    }

    func mediaController() -> (any VLCPictureInPictureMediaControlling)? {
        self
    }

    func pictureInPictureReady() -> (((any VLCPictureInPictureWindowControlling)?) -> Void)? {
        { [weak self] controller in
            guard let self else { return }

            // The window controller is not `Sendable`, so keep it inside this
            // nonisolated closure (VLCKit invokes it on the main thread, like the
            // other VLCDrawable callbacks) and only hop the Sendable readiness/
            // state notifications onto the main actor.
            guard let controller else {
                self.pictureInPictureController = nil
                self.notifyPictureInPictureReadyChanged()
                return
            }

            self.pictureInPictureController = controller
            controller.invalidatePlaybackState()
            controller.stateChangeEventHandler = { [weak self] isStarted in
                self?.notifyPictureInPictureActiveChanged(isStarted)
            }
            self.notifyPictureInPictureReadyChanged()
        }
    }

    private func notifyPictureInPictureReadyChanged() {
        MainActor.assumeIsolated {
            onPictureInPictureReadyChanged?()
        }
    }

    private func notifyPictureInPictureActiveChanged(_ isActive: Bool) {
        MainActor.assumeIsolated {
            onPictureInPictureActiveChanged?(isActive)
        }
    }

    func play() {
        playHandler?()
    }

    func pause() {
        pauseHandler?()
    }

    func seek(by offset: Int64, completion: @escaping () -> Void) {
        seekHandler?(offset, completion)
    }

    func mediaLength() -> Int64 {
        if let media = mediaPlayer?.media {
            return Int64(media.length.intValue)
        }
        return durationMs
    }

    func mediaTime() -> Int64 {
        if let mediaPlayer {
            return Int64(mediaPlayer.time.intValue)
        }
        return currentTimeMs
    }

    func isMediaSeekable() -> Bool {
        mediaPlayer?.isSeekable ?? mediaSeekable
    }

    func isMediaPlaying() -> Bool {
        mediaPlayer?.isPlaying ?? mediaPlaying
    }
}

private final class IOSVLCPictureInPictureContainerView: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
#endif
