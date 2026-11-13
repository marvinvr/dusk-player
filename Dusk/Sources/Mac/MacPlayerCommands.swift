#if os(macOS)
import AppKit
import SwiftUI

/// The menu bar's Playback menu. It drives whichever player is on screen in
/// the key window through the `MacPlayerCommandTarget` that `MacPlayerView`
/// publishes with `focusedSceneValue`; with no player up every item is
/// disabled, so the bare-key equivalents (Space, arrows, F, M) fall through to
/// the rest of the app.
struct MacPlayerCommands: Commands {
    @FocusedValue(MacPlayerCommandTarget.self) private var target

    var body: some Commands {
        CommandMenu("Playback") {
            Button(target?.isPlaying == true ? "Pause" : "Play") {
                target?.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(target?.acceptsCommands != true)

            Button(skipTitle("Skip Back", seconds: target?.skipBackwardSeconds)) {
                target?.skip(.backward)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(target?.canSeek != true)

            Button(skipTitle("Skip Forward", seconds: target?.skipForwardSeconds)) {
                target?.skip(.forward)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(target?.canSeek != true)

            if target?.hasEpisodeNavigation == true {
                Divider()

                Button("Previous Episode") {
                    target?.playAdjacentEpisode(.previous)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(target?.canPlayAdjacentEpisode(.previous) != true)

                Button("Next Episode") {
                    target?.playAdjacentEpisode(.next)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(target?.canPlayAdjacentEpisode(.next) != true)
            }

            Divider()

            Button("Volume Up") {
                target?.volume.step(by: MacPlayerVolume.keyboardStep)
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(target?.acceptsCommands != true)

            Button("Volume Down") {
                target?.volume.step(by: -MacPlayerVolume.keyboardStep)
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(target?.acceptsCommands != true)

            Button(target?.volume.isMuted == true ? "Unmute" : "Mute") {
                target?.volume.toggleMute()
            }
            .keyboardShortcut("m", modifiers: [])
            .disabled(target?.acceptsCommands != true)

            Divider()

            Button(target?.isFullScreen == true ? "Exit Full Screen" : "Enter Full Screen") {
                target?.toggleFullScreen()
            }
            .keyboardShortcut("f", modifiers: [])
            .disabled(target?.acceptsCommands != true)

            Button(target?.isPictureInPictureActive == true ? "Exit Picture in Picture" : "Enter Picture in Picture") {
                target?.togglePictureInPicture()
            }
            .disabled(target?.canPictureInPicture != true)

            Divider()

            Button("Close Player") {
                target?.close()
            }
            .disabled(target == nil)
        }
    }

    private func skipTitle(_ title: String, seconds: Int?) -> String {
        guard let seconds else { return title }
        return "\(title) \(seconds) Seconds"
    }
}

/// What the Playback menu and the player's own key handling act on. Owned by
/// `MacPlayerView` for as long as the player is on screen; the session and
/// pre-roll views plug their engine or view model in and out as they change.
@MainActor @Observable
final class MacPlayerCommandTarget {
    enum SkipDirection {
        case backward
        case forward
    }

    /// The full session's view model. Nil while loading and during a pre-roll.
    weak var viewModel: PlayerViewModel?
    /// The pre-roll's engine while one plays (no view model, no timeline).
    weak var prerollEngine: (any PlaybackEngine)?
    @ObservationIgnored weak var playback: PlaybackCoordinator?
    @ObservationIgnored weak var preferences: UserPreferences?

    /// False while a sheet (subtitle search, playback info, audio offset) or
    /// another surface owns the keyboard, so Space and the arrows reach it.
    var isKeyboardEnabled = true
    private(set) var isFullScreen = false
    let volume = MacPlayerVolume.shared

    /// Closes the player. Set by `MacPlayerView`.
    @ObservationIgnored var onClose: () -> Void = {}

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    /// The player put the window into full screen, so closing the player takes
    /// it back out. A window the viewer made full screen themselves stays.
    @ObservationIgnored private var didEnterFullScreenForPlayer = false

    // MARK: - State for the menu

    var acceptsCommands: Bool {
        isKeyboardEnabled && (viewModel != nil || prerollEngine != nil)
    }

    var isPlaying: Bool {
        if let viewModel { return viewModel.state == .playing }
        return prerollEngine?.state == .playing
    }

    var canSeek: Bool {
        guard isKeyboardEnabled, let viewModel else { return false }
        return viewModel.playbackError == nil && (viewModel.duration > 0 || viewModel.seekableRange != nil)
    }

    var skipBackwardSeconds: Int? {
        preferences?.playerDoubleTapBackwardInterval.rawValue
    }

    var skipForwardSeconds: Int? {
        preferences?.playerDoubleTapForwardInterval.rawValue
    }

    var canPictureInPicture: Bool {
        isKeyboardEnabled && viewModel?.engine.isPictureInPicturePossible == true
    }

    var isPictureInPictureActive: Bool {
        viewModel?.engine.isPictureInPictureActive == true
    }

    var hasEpisodeNavigation: Bool {
        viewModel != nil && playback?.adjacentEpisodes != nil
    }

    func canPlayAdjacentEpisode(_ direction: AdjacentEpisodeDirection) -> Bool {
        guard isKeyboardEnabled, let playback else { return false }
        return playback.adjacentEpisodes?.episode(direction) != nil && playback.canStepEpisodes
    }

    // MARK: - Actions

    func togglePlayPause() {
        guard acceptsCommands else { return }
        if let viewModel {
            viewModel.togglePlayPause()
        } else if let prerollEngine {
            if prerollEngine.state == .playing {
                prerollEngine.pause()
            } else {
                prerollEngine.play()
            }
        }
    }

    func skip(_ direction: SkipDirection) {
        guard canSeek, let viewModel, let preferences else { return }
        let interval = direction == .backward
            ? -preferences.playerDoubleTapBackwardInterval.timeInterval
            : preferences.playerDoubleTapForwardInterval.timeInterval
        viewModel.handleSeekJump(by: interval)
        viewModel.touchControls()
    }

    func playAdjacentEpisode(_ direction: AdjacentEpisodeDirection) {
        guard canPlayAdjacentEpisode(direction), let playback else { return }
        playback.playAdjacentEpisode(direction, isPastCredits: viewModel?.isPastCreditsMarker ?? false)
    }

    func togglePictureInPicture() {
        guard canPictureInPicture || isPictureInPictureActive else { return }
        viewModel?.togglePictureInPicture()
    }

    func close() {
        onClose()
    }

    /// Esc: leave full screen first, then the player.
    func escape() {
        if isFullScreen {
            toggleFullScreen()
        } else {
            close()
        }
    }

    // MARK: - Window

    func attach(to window: NSWindow?) {
        guard window !== self.window else { return }
        detachWindow()
        self.window = window
        guard let window else { return }

        isFullScreen = window.styleMask.contains(.fullScreen)
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = true }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isFullScreen = false
                    self?.didEnterFullScreenForPlayer = false
                }
            },
        ]
    }

    func toggleFullScreen() {
        guard let window = window ?? NSApp.keyWindow else { return }
        if !window.styleMask.contains(.fullScreen) {
            didEnterFullScreenForPlayer = true
        }
        window.toggleFullScreen(nil)
    }

    /// Called as the player leaves the screen.
    func restoreWindow() {
        if didEnterFullScreenForPlayer, let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        didEnterFullScreenForPlayer = false
        detachWindow()
    }

    private func detachWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        window = nil
    }
}

/// The Mac player's own volume and mute, kept across sessions like
/// QuickTime's. Engines get it through `PlaybackEngine.setVolume(_:muted:)`.
@MainActor @Observable
final class MacPlayerVolume {
    static let shared = MacPlayerVolume()
    static let keyboardStep: Float = 0.1

    private static let levelKey = "macPlayerVolume"
    private static let mutedKey = "macPlayerMuted"

    var level: Float {
        didSet { UserDefaults.standard.set(level, forKey: Self.levelKey) }
    }

    var isMuted: Bool {
        didSet { UserDefaults.standard.set(isMuted, forKey: Self.mutedKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        level = defaults.object(forKey: Self.levelKey) == nil
            ? 1
            : max(0, min(defaults.float(forKey: Self.levelKey), 1))
        isMuted = defaults.bool(forKey: Self.mutedKey)
    }

    /// Keyboard and menu steps unmute, the way the system volume keys do.
    func step(by delta: Float) {
        level = max(0, min(level + delta, 1))
        if isMuted { isMuted = false }
    }

    func toggleMute() {
        isMuted.toggle()
    }

    /// The speaker glyph for the current level, as the menu bar's volume uses.
    var symbolName: String {
        if isMuted || level == 0 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    func apply(to engine: any PlaybackEngine) {
        engine.setVolume(level, muted: isMuted)
    }
}
#endif
