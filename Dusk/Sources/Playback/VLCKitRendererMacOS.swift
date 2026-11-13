#if os(macOS)
import AppKit
import VLCKit

/// macOS rendering host for the shared VLCKit playback core.
///
/// VLCKit's macOS video output accepts any `NSView` as its drawable and adds
/// its own OpenGL subview, sized to the drawable. Zoom-to-fill uses libvlc's
/// crop geometry like iOS, re-applied on every layout pass so a window resize
/// keeps the crop matched to the drawable's aspect ratio.
///
/// There is no VLC Picture in Picture on macOS: VLCKit 3.x has no
/// drawable-native PiP and the sample-buffer path is iOS-only.
final class MacOSVLCKitRenderingHost: NSObject, VLCKitRenderingHost, @unchecked Sendable {
    let playerView: NSView

    private weak var mediaPlayer: VLCMediaPlayer?
    private var aspectFillEnabled = false

    @MainActor
    override init() {
        let container = MacOSVLCRendererContainerView()
        self.playerView = container
        super.init()
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

private final class MacOSVLCRendererContainerView: NSView {
    var onLayout: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    /// Clicks belong to the SwiftUI player HUD above the picture.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        onLayout?()
    }
}
#endif
