#if os(tvOS)
import SwiftUI

struct PlayerControlsTVOverlay: View {
    @Environment(UserPreferences.self) private var preferences
    @FocusState private var focusedControl: FocusTarget?
    @State private var tvScrubStartPosition: TimeInterval?

    let viewModel: PlayerViewModel
    let context: PlayerControlsContext
    let scrubPreviewSource: PlexScrubPreviewSource?
    let hasActiveSkipMarker: Bool

    private let horizontalPadding: CGFloat = 12
    private let topPadding: CGFloat = 8
    private let bottomPadding: CGFloat = 2
    private let seekTooltipY: CGFloat = -6
    private let minimumScrubDistance: CGFloat = 4

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
                focusedControl = .seekPoint
            }
        }
        .onChange(of: viewModel.showControls) { _, isShowing in
            focusedControl = isShowing && !hasActiveSkipMarker ? .seekPoint : nil
        }
        .onChange(of: hasActiveSkipMarker) { _, isVisible in
            if !isVisible, viewModel.showControls {
                focusedControl = .seekPoint
            }
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
                PlayerTimeStatusView(viewModel: viewModel)

                Spacer()

                PlayerTrackSettingsMenu(
                    viewModel: viewModel,
                    context: context
                )
                .focused($focusedControl, equals: .settings)
            }
        }
    }

    private var seekPointControl: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progress = viewModel.duration > 0 ? viewModel.displayPosition / viewModel.duration : 0
            let clampedProgress = max(0, min(progress, 1))
            let thumbX = max(15, min(width - 15, width * clampedProgress))
            let isFocused = focusedControl == .seekPoint
            let isPaused = viewModel.state == .paused
            let shouldShowScrubPreview = scrubPreviewSource?.isAvailable == true &&
                (viewModel.isScrubbing || isPaused || viewModel.seekFeedback != nil)

            ZStack(alignment: .topLeading) {
                PlayerSeekBar(viewModel: viewModel, isInteractive: false)
                    .frame(height: 36)
                    .padding(.top, 20)

                if shouldShowScrubPreview,
                   let scrubPreviewSource {
                    PlayerScrubPreviewPopup(
                        source: scrubPreviewSource,
                        position: viewModel.displayPosition
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

                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focused($focusedControl, equals: .seekPoint)
                    .focusEffectDisabled()
                    .onTapGesture {
                        viewModel.togglePlayPause()
                    }
                    .gesture(
                        DragGesture(minimumDistance: minimumScrubDistance)
                            .onChanged { value in
                                updateTVScrub(value, trackWidth: width)
                            }
                            .onEnded { _ in
                                endTVScrub()
                            }
                    )
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

    private func updateTVScrub(_ value: DragGesture.Value, trackWidth: CGFloat) {
        guard focusedControl == .seekPoint,
              viewModel.duration > 0,
              trackWidth > 0 else {
            return
        }

        let startPosition = tvScrubStartPosition ?? viewModel.displayPosition
        if !viewModel.isScrubbing {
            viewModel.beginScrub()
        }
        tvScrubStartPosition = startPosition

        let delta = TimeInterval(value.translation.width / trackWidth) * viewModel.duration
        viewModel.updateScrub(to: startPosition + delta)
    }

    private func endTVScrub() {
        guard viewModel.isScrubbing else {
            tvScrubStartPosition = nil
            return
        }

        viewModel.endScrub()
        tvScrubStartPosition = nil
        focusedControl = .seekPoint
    }

    // Explicit routing keeps the custom tvOS layout predictable across menus and the seek point.
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        let currentFocus = focusedControl ?? .seekPoint

        switch direction {
        case .up:
            focusedControl = focusTargetAbove(currentFocus)
        case .down:
            focusedControl = focusTargetBelow(currentFocus)
        case .left:
            if currentFocus == .seekPoint {
                viewModel.handleSeekJump(by: -preferences.playerDoubleTapBackwardInterval.timeInterval)
                focusedControl = .seekPoint
            } else {
                focusedControl = focusTargetLeft(currentFocus)
            }
        case .right:
            if currentFocus == .seekPoint {
                viewModel.handleSeekJump(by: preferences.playerDoubleTapForwardInterval.timeInterval)
                focusedControl = .seekPoint
            } else {
                focusedControl = focusTargetRight(currentFocus)
            }
        default:
            break
        }
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
#endif
