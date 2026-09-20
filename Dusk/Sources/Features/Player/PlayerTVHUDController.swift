#if os(tvOS)
import Foundation
import SwiftUI

/// The four states the tvOS play bar can be in. Every remote press is routed
/// through `PlayerTVHUDController.handle(_:)` and interpreted against the
/// current mode, so a button never means two things at once.
enum PlayerTVHUDMode: Equatable {
    /// Nothing on screen. Left/right still seek, a tap or Select raises the
    /// transport, a swipe starts a scrub, down opens the panel.
    case hidden
    /// The play bar, the title block and the action row.
    case transport
    /// Previewing a seek target. Nothing is sent to the engine until Select.
    case scrubbing
    /// The settings sheet. The only place SwiftUI focus is used, so the remote
    /// bridge resigns capture while it is up.
    case panel
}

/// Which element of the transport the remote is "on". Deliberately not
/// `@FocusState`: the transport is never focusable, so the focus engine cannot
/// take the remote away from the bridge.
enum PlayerTVTransportFocus: Equatable {
    case bar
    case action(Int)
}

enum PlayerTVPanelTab: String, CaseIterable, Identifiable, Hashable {
    case info
    case chapters
    case audio
    case subtitles
    case quality
    case channel
    case speed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return "Info"
        case .chapters: return "Chapters"
        case .audio: return "Audio"
        case .subtitles: return "Subtitles"
        case .quality: return "Quality"
        case .channel: return "Channel"
        case .speed: return "Speed"
        }
    }

    var systemImage: String {
        switch self {
        case .info: return "info.circle"
        case .chapters: return "list.bullet"
        case .audio: return "speaker.wave.2"
        case .subtitles: return "captions.bubble"
        case .quality: return "rectangle.compress.vertical"
        case .channel: return "list.number"
        case .speed: return "gauge.with.dots.needle.67percent"
        }
    }
}

/// A circular button on the action row above the play bar. Either a shortcut
/// into a panel tab or a one-shot action.
enum PlayerTVActionItem: Equatable, Identifiable {
    case panel(PlayerTVPanelTab)
    case goLive
    case sharePlay(isActive: Bool)

    var id: String {
        switch self {
        case let .panel(tab): return "panel.\(tab.rawValue)"
        case .goLive: return "goLive"
        case let .sharePlay(isActive): return "sharePlay.\(isActive)"
        }
    }

    var systemImage: String {
        switch self {
        case let .panel(tab): return tab.systemImage
        case .goLive: return "forward.end.alt.fill"
        case .sharePlay: return "shareplay"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case let .panel(tab): return tab.title
        case .goLive: return "Go Live"
        case let .sharePlay(isActive): return isActive ? "Leave SharePlay" : "Start SharePlay"
        }
    }
}

/// Transient feedback shown over the video while the HUD is hidden.
enum PlayerTVTransientBadge: Equatable {
    case seek(direction: PlayerSeekFeedbackPresentation.Direction, seconds: Int)
    case playPause(isPlaying: Bool)
}

/// Owns the tvOS HUD's state machine.
///
/// The view model still owns playback and HUD *visibility* (`showControls`,
/// which the status bar, the Up Next poster and the skip chip all read); this
/// controller owns what the HUD is *doing* and mirrors the two in both
/// directions — `apply(_:)` writes `showControls`, `syncControlsVisibility(_:)`
/// reads it back so a reveal that came from playback code (an auto-skip, for
/// example) still lands in a coherent mode.
@MainActor
@Observable
final class PlayerTVHUDController {
    private(set) var mode: PlayerTVHUDMode = .hidden
    private(set) var transportFocus: PlayerTVTransportFocus = .bar
    /// Seek target being previewed by a swipe scrub. Nil outside `.scrubbing`.
    private(set) var scrubTarget: TimeInterval?
    /// Seek target accumulated by held left/right clicks, not yet committed.
    private(set) var seekPreviewPosition: TimeInterval?
    private(set) var transientBadge: PlayerTVTransientBadge?
    var panelTab: PlayerTVPanelTab = .info

    /// Supplied by the overlay every time they change.
    var actions: [PlayerTVActionItem] = []
    var availablePanelTabs: [PlayerTVPanelTab] = []
    var backwardSeekInterval: TimeInterval = 10
    var forwardSeekInterval: TimeInterval = 10
    /// A Skip Intro chip or an Up Next poster is on screen. While the HUD is
    /// hidden it owns Select and Down.
    var isBottomTrailingControlVisible = false

    @ObservationIgnored weak var viewModel: PlayerViewModel?
    @ObservationIgnored var onDismissPlayer: (() -> Void)?
    @ObservationIgnored var onSharePlay: (() -> Void)?
    @ObservationIgnored var onActivateBottomTrailingControl: (() -> Void)?
    /// Returns true when it actually dismissed something; false lets Down fall
    /// through to opening the panel (the Skip Intro chip cannot be dismissed).
    @ObservationIgnored var onDismissBottomTrailingControl: (() -> Bool)?

    @ObservationIgnored private var isPanActive = false
    @ObservationIgnored private var scrubAnchor: TimeInterval = 0
    @ObservationIgnored private var scrubOrigin: PlayerTVHUDMode = .hidden
    @ObservationIgnored private var seekAnchor: TimeInterval = 0
    @ObservationIgnored private var seekAccumulator: TimeInterval = 0
    @ObservationIgnored private var lastModeChangeAt = Date.distantPast
    @ObservationIgnored private var lastSelectAt = Date.distantPast
    @ObservationIgnored private var holdsControlsInteraction = false
    @ObservationIgnored private var seekRepeatTask: Task<Void, Never>?
    @ObservationIgnored private var seekCommitTask: Task<Void, Never>?
    @ObservationIgnored private var badgeTask: Task<Void, Never>?

    /// What the bar should draw its playhead at: a live preview when one is
    /// running, the engine position otherwise.
    var previewPosition: TimeInterval? {
        scrubTarget ?? seekPreviewPosition
    }

    var isPanelPresented: Bool {
        mode == .panel
    }

    // MARK: - Lifecycle

    func cleanup() {
        seekRepeatTask?.cancel()
        seekRepeatTask = nil
        seekCommitTask?.cancel()
        seekCommitTask = nil
        badgeTask?.cancel()
        badgeTask = nil
        releaseControlsInteractionHold()
        // A session view can be re-presented onto the same controller (the PiP
        // restore path). Come back in the resting state instead of resuming a
        // scrub or an open panel that belonged to the previous appearance.
        mode = .hidden
        transportFocus = .bar
        scrubTarget = nil
        seekPreviewPosition = nil
        seekAccumulator = 0
        transientBadge = nil
        isPanActive = false
        viewModel = nil
        onDismissPlayer = nil
        onSharePlay = nil
        onActivateBottomTrailingControl = nil
        onDismissBottomTrailingControl = nil
    }

    // MARK: - Mode

    /// Reconciles a `showControls` change that did not come from here (the
    /// auto-hide timer, an auto-skip that reveals the HUD).
    func syncControlsVisibility(_ isShowing: Bool) {
        if isShowing, mode == .hidden {
            apply(.transport)
        } else if !isShowing, mode != .hidden {
            apply(.hidden)
        }
    }

    func openPanel(_ tab: PlayerTVPanelTab? = nil) {
        guard !availablePanelTabs.isEmpty else { return }

        if let tab, availablePanelTabs.contains(tab) {
            panelTab = tab
        } else if !availablePanelTabs.contains(panelTab) {
            panelTab = availablePanelTabs[0]
        }

        apply(.panel)
    }

    func closePanel() {
        guard mode == .panel else { return }
        apply(.transport)
    }

    func noteInteraction() {
        guard mode == .transport else { return }
        viewModel?.noteControlsInteraction()
    }

    private func apply(_ newMode: PlayerTVHUDMode) {
        guard mode != newMode else { return }

        let wasHidden = mode == .hidden
        mode = newMode
        lastModeChangeAt = Date()

        switch newMode {
        case .hidden:
            scrubTarget = nil
            transportFocus = .bar
            releaseControlsInteractionHold()
            setControlsVisible(false)
        case .transport:
            if wasHidden {
                transportFocus = .bar
            }
            setControlsVisible(true)
            releaseControlsInteractionHold()
            viewModel?.noteControlsInteraction()
        case .scrubbing, .panel:
            setControlsVisible(true)
            // Reuses the view model's existing interaction hold so the shared
            // auto-hide timer cannot pull the HUD out from under a scrub or an
            // open settings sheet.
            takeControlsInteractionHold()
        }
    }

    private func setControlsVisible(_ isVisible: Bool) {
        guard let viewModel, viewModel.showControls != isVisible else { return }
        withAnimation(PlayerViewModel.controlsVisibilityAnimation) {
            viewModel.showControls = isVisible
        }
    }

    private func takeControlsInteractionHold() {
        guard !holdsControlsInteraction else { return }
        holdsControlsInteraction = true
        viewModel?.beginControlsInteractionHold()
    }

    private func releaseControlsInteractionHold() {
        guard holdsControlsInteraction else { return }
        holdsControlsInteraction = false
        viewModel?.endControlsInteractionHold()
    }

    // MARK: - Input

    func handle(_ input: PlayerTVRemoteInput) {
        switch input {
        case .panBegan:
            beginScrub()
            return
        case let .panChanged(translationX, _):
            updateScrub(translationX: translationX)
            return
        case .panEnded:
            isPanActive = false
            return
        default:
            break
        }

        // While a finger is down on the touch surface tvOS also synthesizes
        // arrow presses. The pan owns the gesture; the arrows would otherwise
        // fire a ±interval seek on top of the scrub.
        if isPanActive {
            switch input {
            case .arrowDown(_), .arrowUp(_):
                return
            default:
                break
            }
        }

        if case .select = input {
            lastSelectAt = Date()
        }

        switch mode {
        case .hidden:
            handleHidden(input)
        case .transport:
            handleTransport(input)
        case .scrubbing:
            handleScrubbing(input)
        case .panel:
            // Unreachable in practice: capture is off while the panel is up.
            if case .menu = input { closePanel() }
        }
    }

    private func handleHidden(_ input: PlayerTVRemoteInput) {
        switch input {
        case .select:
            if isBottomTrailingControlVisible {
                activateBottomTrailingControl()
                return
            }
            apply(.transport)
        case .touchTap:
            guard !isTapEchoingAClick else { return }
            apply(.transport)
        case .arrowDown(.up):
            apply(.transport)
        case .arrowDown(.down):
            if isBottomTrailingControlVisible, onDismissBottomTrailingControl?() == true {
                return
            }
            openPanel()
        case .arrowDown(.left):
            beginSeekHold(direction: -1)
        case .arrowDown(.right):
            beginSeekHold(direction: 1)
        case .arrowUp(.left), .arrowUp(.right):
            endSeekHold()
        case .playPause:
            togglePlayPause()
        case .menu:
            onDismissPlayer?()
        default:
            break
        }
    }

    private func handleTransport(_ input: PlayerTVRemoteInput) {
        // `actions` shrinks mid-session (Go Live disappears the moment the
        // playhead reaches the live edge), so a stale index is folded back into
        // range before it is acted on.
        let focus = normalizedTransportFocus
        if focus != transportFocus {
            transportFocus = focus
        }

        switch input {
        case .menu:
            apply(.hidden)
        case .touchTap:
            guard !isTapEchoingAClick else { return }
            apply(.hidden)
        case .select:
            switch focus {
            case .bar:
                togglePlayPause()
            case let .action(index):
                activateAction(at: index)
            }
        case .playPause:
            togglePlayPause()
        case .arrowDown(.up):
            if focus == .bar, !actions.isEmpty {
                withTransportAnimation { transportFocus = .action(0) }
            }
            noteInteraction()
        case .arrowDown(.down):
            switch focus {
            case .bar:
                openPanel()
            case .action:
                withTransportAnimation { transportFocus = .bar }
                noteInteraction()
            }
        case .arrowDown(.left):
            if case let .action(index) = focus {
                withTransportAnimation { transportFocus = .action(max(0, index - 1)) }
                noteInteraction()
            } else {
                beginSeekHold(direction: -1)
            }
        case .arrowDown(.right):
            if case let .action(index) = focus {
                withTransportAnimation { transportFocus = .action(min(actions.count - 1, index + 1)) }
                noteInteraction()
            } else {
                beginSeekHold(direction: 1)
            }
        case .arrowUp(.left), .arrowUp(.right):
            // Unconditional: a hold that started on the bar must be able to end
            // even if the selection moved off it in between, or the repeat task
            // runs on and the accumulated offset is never committed.
            endSeekHold()
        default:
            break
        }
    }

    /// `transportFocus` clamped to what the action row currently holds. An
    /// `.action` selection with an empty row collapses back to the bar.
    private var normalizedTransportFocus: PlayerTVTransportFocus {
        guard case let .action(index) = transportFocus else { return .bar }
        guard !actions.isEmpty else { return .bar }
        return .action(min(max(index, 0), actions.count - 1))
    }

    private func handleScrubbing(_ input: PlayerTVRemoteInput) {
        switch input {
        case .select, .playPause:
            commitScrub()
        case .menu, .arrowDown(.up):
            cancelScrub()
        case .arrowDown(.left):
            stepScrub(by: -backwardSeekInterval)
        case .arrowDown(.right):
            stepScrub(by: forwardSeekInterval)
        default:
            break
        }
    }

    /// A click on the touch surface arrives as a Select press and, a beat
    /// later, as a plain tap of the same physical press. Without this a single
    /// click would raise the HUD and immediately drop it again — or, on the
    /// bar, pause playback *and* hide the transport.
    private var isTapEchoingAClick: Bool {
        let reference = max(lastModeChangeAt, lastSelectAt)
        return Date().timeIntervalSince(reference) < PlayerTVHUDLayout.selectTapDebounce
    }

    private func withTransportAnimation(_ body: () -> Void) {
        withAnimation(PlayerTVHUDLayout.selectionAnimation, body)
    }

    // MARK: - Actions

    private func activateAction(at index: Int) {
        guard actions.indices.contains(index) else { return }

        switch actions[index] {
        case let .panel(tab):
            openPanel(tab)
        case .goLive:
            viewModel?.goLive()
            noteInteraction()
        case .sharePlay:
            onSharePlay?()
            noteInteraction()
        }
    }

    private func activateBottomTrailingControl() {
        guard let viewModel else {
            onActivateBottomTrailingControl?()
            return
        }

        // Skipping a marker reveals the HUD through `seek(revealControls:)`.
        // From the hidden state that is not what the viewer asked for.
        viewModel.suppressControlsReveal = true
        onActivateBottomTrailingControl?()
        viewModel.suppressControlsReveal = false
    }

    private func togglePlayPause() {
        guard let viewModel else { return }

        let staysHidden = mode == .hidden
        viewModel.suppressControlsReveal = staysHidden
        viewModel.togglePlayPause()
        viewModel.suppressControlsReveal = false

        if staysHidden {
            showBadge(.playPause(isPlaying: viewModel.state == .playing))
        } else {
            noteInteraction()
        }
    }

    // MARK: - Hold-to-seek

    /// Left/right clicks never reach the engine one at a time. They accumulate
    /// into an offset the bar and the badge preview, and a single seek is
    /// issued once the button comes up (plus a short grace period, so a burst
    /// of clicks is one seek too).
    private func beginSeekHold(direction: Int) {
        guard let viewModel, viewModel.playbackError == nil else { return }

        seekCommitTask?.cancel()
        seekCommitTask = nil

        if seekPreviewPosition == nil {
            seekAnchor = viewModel.displayPosition
            seekAccumulator = 0
        }

        applySeekStep(interval(for: direction))
        startSeekRepeat(direction: direction)
        noteInteraction()
    }

    private func endSeekHold() {
        seekRepeatTask?.cancel()
        seekRepeatTask = nil

        guard seekPreviewPosition != nil else { return }

        seekCommitTask?.cancel()
        seekCommitTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: PlayerTVHUDLayout.seekCommitDebounce)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.commitAccumulatedSeek()
        }
    }

    private func interval(for direction: Int) -> TimeInterval {
        TimeInterval(direction) * (direction < 0 ? backwardSeekInterval : forwardSeekInterval)
    }

    private func applySeekStep(_ delta: TimeInterval) {
        guard let viewModel else { return }

        let target = viewModel.clampedSeekPosition(seekAnchor + seekAccumulator + delta)
        seekAccumulator = target - seekAnchor
        seekPreviewPosition = target

        // At a clamp edge the accumulator stays at zero, so the arrow that was
        // actually pressed decides the direction — otherwise pressing left at
        // position 0 reads as "+0:01".
        let offset = seekAccumulator == 0 ? delta : seekAccumulator
        showBadge(
            .seek(
                direction: offset < 0 ? .backward : .forward,
                seconds: Int(abs(seekAccumulator).rounded())
            ),
            autoDismiss: false
        )
    }

    private func startSeekRepeat(direction: Int) {
        seekRepeatTask?.cancel()
        seekRepeatTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: PlayerTVHUDLayout.seekHoldInitialDelay)
            } catch {
                return
            }

            var step = 0
            let ramp = PlayerTVHUDLayout.seekHoldRampMultipliers

            while !Task.isCancelled {
                guard let self else { return }
                let multiplier = ramp[min(step, ramp.count - 1)]
                self.applySeekStep(self.interval(for: direction) * multiplier)
                self.noteInteraction()
                step += 1

                do {
                    try await Task.sleep(for: PlayerTVHUDLayout.seekHoldRepeatInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func commitAccumulatedSeek() {
        guard let viewModel, let target = seekPreviewPosition else { return }

        // Transient jump: let the engine take the keyframe-tolerant path.
        viewModel.suppressControlsReveal = mode == .hidden
        viewModel.seek(to: target, revealControls: false, precise: false)
        viewModel.suppressControlsReveal = false

        seekPreviewPosition = nil
        seekAccumulator = 0
        scheduleBadgeDismissal()
        noteInteraction()
    }

    // MARK: - Swipe scrubbing

    private func beginScrub() {
        guard mode != .panel, let viewModel, viewModel.playbackError == nil else { return }

        isPanActive = true
        guard mode != .scrubbing else {
            // A second swipe without committing continues from where the last
            // one left the cursor; `translation` restarts at zero for the new
            // gesture, so the anchor has to move with it.
            scrubAnchor = scrubTarget ?? viewModel.displayPosition
            return
        }

        // A swipe that starts mid-hold would otherwise fight the accumulator.
        seekRepeatTask?.cancel()
        seekRepeatTask = nil
        seekCommitTask?.cancel()
        seekCommitTask = nil
        seekPreviewPosition = nil
        seekAccumulator = 0
        transientBadge = nil

        scrubOrigin = mode == .hidden ? .hidden : .transport
        scrubAnchor = viewModel.displayPosition
        scrubTarget = scrubAnchor
        apply(.scrubbing)
    }

    private func updateScrub(translationX: CGFloat) {
        guard mode == .scrubbing, let viewModel else { return }

        let normalized = Double(translationX / PlayerTVHUDLayout.fullSwipeTranslation)
        let eased = (normalized < 0 ? -1.0 : 1.0)
            * pow(abs(normalized), PlayerTVHUDLayout.swipeEaseExponent)
        scrubTarget = viewModel.clampedSeekPosition(scrubAnchor + eased * scrubSpan)
    }

    private func stepScrub(by offset: TimeInterval) {
        guard let viewModel, let current = scrubTarget else { return }
        scrubTarget = viewModel.clampedSeekPosition(current + offset)
        // Keep the anchor with the cursor so a following swipe starts here.
        scrubAnchor = scrubTarget ?? scrubAnchor
    }

    /// A live play bar spans a whole scheduled program, but only the stretch
    /// the tuned session still holds is reachable — often just minutes. Pacing
    /// the swipe by the bar would make every touch overshoot it.
    private var scrubSpan: TimeInterval {
        guard let viewModel else { return 0 }

        if viewModel.isLiveTV, let seekableRange = viewModel.seekableRange {
            return seekableRange.upperBound - seekableRange.lowerBound
        }

        let range = viewModel.timelineRange
        return range.upperBound - range.lowerBound
    }

    private func commitScrub() {
        guard let viewModel, let target = scrubTarget else {
            apply(.transport)
            return
        }

        // Frame-accurate: this is a target the viewer deliberately picked.
        let wasPaused = viewModel.state == .paused
        viewModel.seek(to: target, revealControls: false, precise: true)
        if wasPaused {
            viewModel.togglePlayPause()
        }

        scrubTarget = nil
        apply(.transport)
    }

    private func cancelScrub() {
        scrubTarget = nil
        apply(scrubOrigin == .hidden ? .hidden : .transport)
    }

    // MARK: - Badge

    private func showBadge(_ badge: PlayerTVTransientBadge, autoDismiss: Bool = true) {
        badgeTask?.cancel()
        badgeTask = nil

        withAnimation(.easeOut(duration: 0.12)) {
            transientBadge = badge
        }

        guard autoDismiss else { return }
        scheduleBadgeDismissal()
    }

    private func scheduleBadgeDismissal() {
        badgeTask?.cancel()
        badgeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: PlayerTVHUDLayout.transientBadgeDuration)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                self.transientBadge = nil
            }
        }
    }
}
#endif
