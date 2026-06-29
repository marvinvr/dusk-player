#if os(tvOS)
import SwiftUI
import UIKit

struct PlayerControlsTVOverlay: View {
    @Environment(UserPreferences.self) private var preferences
    @FocusState private var focusedControl: FocusTarget?
    @State private var tvScrubCursorPosition: TimeInterval?

    let viewModel: PlayerViewModel
    let context: PlayerControlsContext
    let scrubPreviewSource: PlexScrubPreviewSource?
    let hasActiveSkipMarker: Bool

    private let horizontalPadding: CGFloat = 12
    private let topPadding: CGFloat = 8
    private let bottomPadding: CGFloat = 2
    private let seekTooltipY: CGFloat = -6
    private let minimumScrubDistance: CGFloat = 2
    private let minimumScrubSecondsPerPoint: TimeInterval = 45
    private let scrubFullDurationTouchPoints: TimeInterval = 70

    private enum FocusTarget: Hashable {
        case seekPoint
        case settings
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                PlayerControlsGradientBackdrop()

                VStack(spacing: 12) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
                .focusSection()
            }
        }
        .defaultFocus($focusedControl, .seekPoint)
        .onAppear {
            if viewModel.showControls && !hasActiveSkipMarker {
                restoreSeekFocus()
            }
        }
        .onChange(of: viewModel.showControls) { _, isShowing in
            if isShowing && !hasActiveSkipMarker {
                restoreSeekFocus()
            } else {
                tvScrubCursorPosition = nil
                focusedControl = nil
            }
        }
        .onChange(of: hasActiveSkipMarker) { _, isVisible in
            if !isVisible, viewModel.showControls {
                restoreSeekFocus()
            } else if isVisible {
                tvScrubCursorPosition = nil
                focusedControl = nil
            }
        }
        .onChange(of: focusedControl) { previousControl, focusedControl in
            guard previousControl != nil,
                  focusedControl != nil,
                  previousControl != focusedControl else {
                return
            }
            viewModel.noteControlsInteraction()
        }
        .onMoveCommand(perform: handleMoveCommand)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            if let header = context.mediaHeader {
                PlayerMediaHeaderView(header: header)
            }

            Spacer()
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            seekPointControl

            HStack(alignment: .center, spacing: 18) {
                PlayerTimeStatusView(viewModel: viewModel, position: viewModel.currentTime)

                Spacer()

                PlayerTrackSettingsMenu(
                    viewModel: viewModel,
                    context: context,
                    onMenuPresentationChanged: handleSettingsMenuPresentation
                )
                .focused($focusedControl, equals: .settings)
            }
        }
    }

    private var seekPointControl: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let cursorPosition = tvScrubCursorPosition ?? viewModel.currentTime
            let cursorProgress = viewModel.duration > 0 ? cursorPosition / viewModel.duration : 0
            let clampedCursorProgress = max(0, min(cursorProgress, 1))
            let thumbX = max(15, min(width - 15, width * clampedCursorProgress))
            let isFocused = focusedControl == .seekPoint
            let isPaused = viewModel.state == .paused
            let shouldShowScrubPreview = scrubPreviewSource?.isAvailable == true &&
                (tvScrubCursorPosition != nil || isPaused || viewModel.seekFeedback != nil)

            ZStack(alignment: .topLeading) {
                PlayerSeekBar(
                    viewModel: viewModel,
                    isInteractive: false,
                    progressPosition: viewModel.currentTime
                )
                    .frame(height: 36)
                    .padding(.top, 20)

                if shouldShowScrubPreview,
                   let scrubPreviewSource {
                    PlayerScrubPreviewPopup(
                        source: scrubPreviewSource,
                        position: cursorPosition
                    )
                    .position(
                        x: scrubPreviewX(thumbX, totalWidth: width),
                        y: PlayerScrubPreviewPopup.verticalPosition
                    )
                    .transition(seekTooltipTransition)
                } else if let seekFeedback = viewModel.seekFeedback {
                    seekTooltip(seekFeedback)
                        .position(x: thumbX, y: seekTooltipY)
                        .transition(seekTooltipTransition)
                } else if isPaused {
                    pauseTooltip
                        .position(x: thumbX, y: seekTooltipY)
                        .transition(seekTooltipTransition)
                }

                ZStack {
                    Circle()
                        .fill(.white.opacity(isFocused ? 0.98 : 0.88))
                        .frame(width: isFocused ? 24 : 18, height: isFocused ? 24 : 18)
                        .shadow(
                            color: .white.opacity(isFocused ? 0.36 : 0.18),
                            radius: isFocused ? 14 : 7
                        )
                }
                .position(x: thumbX, y: 38)

                PlayerTVScrubGestureBridge(
                    minimumScrubDistance: minimumScrubDistance,
                    onTouchSurfaceTap: {
                        guard focusedControl == .seekPoint else { return }
                        tvScrubCursorPosition = nil
                        viewModel.toggleControls()
                    },
                    onScrubBegan: {
                        viewModel.beginControlsInteractionHold()
                    },
                    onScrubChanged: { deltaWidth in
                        updateTVScrub(
                            deltaWidth: deltaWidth
                        )
                    },
                    onScrubEnded: {
                        finishTVScrubPreview()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button(action: handleSeekPointSelect) {
                    Circle()
                        .fill(.clear)
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .duskSuppressTVOSButtonChrome()
                .focused($focusedControl, equals: .seekPoint)
                .focusEffectDisabled()
                .position(x: thumbX, y: 38)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .scaleEffect(isFocused ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isFocused)
        }
        .frame(height: 64)
    }

    private var pauseTooltip: some View {
        Image(systemName: "pause.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: 46, height: 46)
            .background {
                Circle()
                    .fill(.white.opacity(0.07))
                    .background(.ultraThinMaterial, in: Circle())
            }
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.42), lineWidth: 1.2)
            }
            .shadow(color: .white.opacity(0.12), radius: 10)
            .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
    }

    private var seekTooltipTransition: AnyTransition {
        .move(edge: .bottom).combined(with: .opacity)
    }

    private func seekTooltip(_ presentation: PlayerSeekFeedbackPresentation) -> some View {
        Image(systemName: presentation.direction.symbolName)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.92))
            .offset(y: -1.5)
            .frame(width: 46, height: 46)
            .background {
                Circle()
                    .fill(.white.opacity(0.07))
                    .background(.ultraThinMaterial, in: Circle())
            }
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.42), lineWidth: 1.2)
            }
            .shadow(color: .white.opacity(0.12), radius: 10)
            .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
    }

    private func scrubPreviewX(_ proposedX: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let halfWidth = PlayerScrubPreviewPopup.width / 2
        guard totalWidth > halfWidth * 2 else {
            return max(totalWidth / 2, halfWidth)
        }

        return min(max(proposedX, halfWidth), totalWidth - halfWidth)
    }

    private func updateTVScrub(deltaWidth: CGFloat) {
        guard focusedControl == .seekPoint,
              viewModel.duration > 0 else {
            return
        }

        let startPosition = tvScrubCursorPosition ?? viewModel.currentTime
        let secondsPerPoint = max(minimumScrubSecondsPerPoint, viewModel.duration / scrubFullDurationTouchPoints)
        tvScrubCursorPosition = clampedPosition(startPosition + TimeInterval(deltaWidth) * secondsPerPoint)
        viewModel.scheduleHide()
    }

    private func handleSettingsMenuPresentation(isPresented _: Bool) {
        viewModel.noteSettingsMenuInteraction()
    }

    private func finishTVScrubPreview() {
        viewModel.endControlsInteractionHold()
        restoreSeekFocus()
    }

    private func handleSeekPointSelect() {
        guard focusedControl == .seekPoint else { return }
        guard !viewModel.shouldIgnoreSeekPointSelectAfterReveal() else {
            viewModel.scheduleHide()
            return
        }

        if tvScrubCursorPosition != nil {
            commitTVScrub()
        } else {
            viewModel.togglePlayPause()
        }
    }

    private func commitTVScrub() {
        guard let targetPosition = tvScrubCursorPosition else {
            return
        }

        viewModel.seek(to: targetPosition, revealControls: true)
        if viewModel.state == .paused {
            viewModel.togglePlayPause()
        }
        tvScrubCursorPosition = nil
        restoreSeekFocus()
    }

    private func clampedPosition(_ position: TimeInterval) -> TimeInterval {
        guard viewModel.duration > 0 else {
            return max(0, position)
        }

        return min(max(position, 0), viewModel.duration)
    }

    private func restoreSeekFocus(reset: Bool = true) {
        if reset {
            focusedControl = nil
        }

        Task { @MainActor in
            await Task.yield()

            guard viewModel.showControls, !hasActiveSkipMarker else { return }
            focusedControl = .seekPoint
        }
    }

    // Explicit routing keeps the custom tvOS layout predictable across menus and the seek point.
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        viewModel.noteControlsInteraction()

        let currentFocus = focusedControl ?? .seekPoint

        switch direction {
        case .up:
            focusedControl = focusTargetAbove(currentFocus)
        case .down:
            focusedControl = focusTargetBelow(currentFocus)
        case .left:
            if currentFocus == .seekPoint {
                handleSeekPointJump(by: -preferences.playerDoubleTapBackwardInterval.timeInterval)
                restoreSeekFocus(reset: false)
            } else {
                focusedControl = focusTargetLeft(currentFocus)
            }
        case .right:
            if currentFocus == .seekPoint {
                handleSeekPointJump(by: preferences.playerDoubleTapForwardInterval.timeInterval)
                restoreSeekFocus(reset: false)
            } else {
                focusedControl = focusTargetRight(currentFocus)
            }
        default:
            break
        }
    }

    private func handleSeekPointJump(by offset: TimeInterval) {
        let startPosition = tvScrubCursorPosition ?? viewModel.currentTime
        tvScrubCursorPosition = clampedPosition(startPosition + offset)
        viewModel.scheduleHide()
    }

    private func focusTargetAbove(_ current: FocusTarget) -> FocusTarget? {
        switch current {
        case .seekPoint:
            return nil
        case .settings:
            return .seekPoint
        }
    }

    private func focusTargetBelow(_ current: FocusTarget) -> FocusTarget? {
        switch current {
        case .seekPoint:
            return hasAvailableTrackSettings ? .settings : nil
        case .settings:
            return nil
        }
    }

    private func focusTargetLeft(_ current: FocusTarget) -> FocusTarget? {
        switch current {
        case .seekPoint, .settings:
            return nil
        }
    }

    private func focusTargetRight(_ current: FocusTarget) -> FocusTarget? {
        switch current {
        case .seekPoint, .settings:
            return nil
        }
    }

    private var hasAvailableTrackSettings: Bool {
        context.hasPlaybackInfo ||
            context.hasQualityControl ||
            !viewModel.audioTracks.isEmpty ||
            !viewModel.subtitleTracks.isEmpty
    }
}

private struct PlayerTVScrubGestureBridge: UIViewRepresentable {
    let minimumScrubDistance: CGFloat
    let onTouchSurfaceTap: () -> Void
    let onScrubBegan: () -> Void
    let onScrubChanged: (CGFloat) -> Void
    let onScrubEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PlayerTVScrubGestureView {
        let view = PlayerTVScrubGestureView()
        view.backgroundColor = .clear

        context.coordinator.touchSurfaceTapRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        context.coordinator.touchSurfaceTapRecognizer.allowedPressTypes = []
        context.coordinator.touchSurfaceTapRecognizer.cancelsTouchesInView = false
        context.coordinator.panRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        context.coordinator.panRecognizer.delegate = context.coordinator

        view.addGestureRecognizer(context.coordinator.touchSurfaceTapRecognizer)
        view.addGestureRecognizer(context.coordinator.panRecognizer)
        context.coordinator.sync(with: self)
        context.coordinator.sync(view, with: self)
        return view
    }

    func updateUIView(_ uiView: PlayerTVScrubGestureView, context: Context) {
        context.coordinator.sync(with: self)
        context.coordinator.sync(uiView, with: self)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var parent: PlayerTVScrubGestureBridge
        let touchSurfaceTapRecognizer = UITapGestureRecognizer()
        let panRecognizer = UIPanGestureRecognizer()
        private var hasStartedScrubbing = false
        private var lastPanTranslationWidth: CGFloat = 0

        init(parent: PlayerTVScrubGestureBridge) {
            self.parent = parent
            super.init()
            touchSurfaceTapRecognizer.addTarget(self, action: #selector(handleTouchSurfaceTap(_:)))
            panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        func sync(with parent: PlayerTVScrubGestureBridge) {
            self.parent = parent
        }

        func sync(_ view: PlayerTVScrubGestureView, with parent: PlayerTVScrubGestureBridge) {}

        @objc
        private func handleTouchSurfaceTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onTouchSurfaceTap()
        }

        @objc
        private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translationWidth = recognizer.translation(in: recognizer.view).x

            switch recognizer.state {
            case .began:
                hasStartedScrubbing = false
                lastPanTranslationWidth = 0
                parent.onScrubBegan()
            case .changed:
                guard hasStartedScrubbing || abs(translationWidth) >= parent.minimumScrubDistance else {
                    return
                }
                let deltaWidth = hasStartedScrubbing ? translationWidth - lastPanTranslationWidth : translationWidth
                hasStartedScrubbing = true
                lastPanTranslationWidth = translationWidth
                parent.onScrubChanged(deltaWidth)
            case .ended, .cancelled, .failed:
                parent.onScrubEnded()
                hasStartedScrubbing = false
                lastPanTranslationWidth = 0
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

private final class PlayerTVScrubGestureView: UIView {
    override var canBecomeFocused: Bool {
        false
    }
}
#endif
