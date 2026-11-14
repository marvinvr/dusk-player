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

    override var mouseDownCanMoveWindow: Bool { false }

    /// libvlc's macOS video view (`VLCVideoLayerView`, or `VLCOpenGLVideoView`
    /// for the legacy output) is opaque and answers `mouseDownCanMoveWindow`
    /// with YES: VLC.app drags its window by the picture. `hitTest` above
    /// keeps it out of AppKit's click routing, but the window server's drag
    /// region is built from opaque descendants without asking `hitTest`, so
    /// the picture (and the HUD drawn over it) can turn into window-drag
    /// area, where a real click starts a window move instead of reaching
    /// the play bar. The AVPlayer host is opaque and never moves the window;
    /// the VLC view gets the same answer.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        Self.disableWindowMoving(for: subview)
    }

    private static func disableWindowMoving(for view: NSView) {
        let viewClass: AnyClass = type(of: view)
        // Once replaced, the class answers NO and is never patched again.
        guard view.mouseDownCanMoveWindow else { return }
        let selector = #selector(getter: NSView.mouseDownCanMoveWindow)
        guard let method = class_getInstanceMethod(viewClass, selector) else { return }
        let block: @convention(block) (AnyObject) -> Bool = { _ in false }
        class_replaceMethod(
            viewClass,
            selector,
            imp_implementationWithBlock(block),
            method_getTypeEncoding(method)
        )
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}
#endif
