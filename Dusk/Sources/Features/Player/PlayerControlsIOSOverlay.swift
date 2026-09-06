import SwiftUI

struct PlayerControlsIOSOverlay: View {
    @Environment(PlaybackCoordinator.self) private var playback

    let viewModel: PlayerViewModel
    let context: PlayerControlsContext
    let scrubPreviewSource: PlexScrubPreviewSource?
    let controlsTopSafeAreaInset: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { _ in
            ZStack {
                PlayerControlsGradientBackdrop()

                VStack {
                    topBar
                    Spacer()
                    centerControls
                    Spacer()
                    bottomBar
                }
                .padding(.horizontal, PlayerOverlayLayout.controlsHorizontalPadding)
                .padding(.top, controlsTopSafeAreaInset + 16)
                .padding(.bottom, 8)
            }
            // Moving a mouse/trackpad pointer anywhere over the visible controls
            // keeps them up instead of letting them fade mid-reach. Never reveals
            // the HUD on its own — `noteControlsInteraction()` is a no-op while the
            // controls are hidden.
            .onContinuousHover { phase in
                if case .active = phase {
                    viewModel.noteControlsInteraction()
                }
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 20) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }

            if let header = context.mediaHeader {
                PlayerMediaHeaderView(header: header)
            }

            Spacer()

            #if os(iOS)
            airPlayButton
            #endif
            if !playback.isAirPlayPlaybackActive {
                pictureInPictureButton
                aspectFillButton
            }
        }
    }

    #if os(iOS)
    /// Same 44pt glass circle as the buttons beside it — the route picker
    /// underneath carries the accessibility label and opens the system sheet.
    private var airPlayButton: some View {
        PlayerAirPlayControl(isActive: playback.isAirPlayPlaybackActive)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
    }
    #endif

    @ViewBuilder
    private var pictureInPictureButton: some View {
        if viewModel.engine.isPictureInPicturePossible {
            Button {
                viewModel.togglePictureInPicture()
            } label: {
                Image(systemName: viewModel.engine.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                    .font(.title3.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace, options: .speed(2)))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Picture in Picture")
        }
    }

    private var aspectFillButton: some View {
        Button {
            viewModel.toggleAspectFill()
        } label: {
            Image(systemName: viewModel.aspectFillEnabled
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.title3.weight(.semibold))
                .contentTransition(.symbolEffect(.replace, options: .speed(2)))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(viewModel.aspectFillEnabled ? "Fit video to screen" : "Zoom video to fill screen")
    }

    private var centerControls: some View {
        let isPlaying = viewModel.state == .playing
        let isSpinnerActive = isLoadingPresentationActive

        return HStack {
            Spacer()
            // The center slot belongs to `PlayerView`'s shared spinner whenever
            // that spinner is up: startup (including the VLCKit audio warmup,
            // masked as .loading), delayed mid-play buffering, and the automatic
            // direct-play → server-stream recovery. Stacking the button under it
            // reads as a double control, and during startup it would render
            // "play" while video is already moving, then flip the moment the
            // warmup completes.
            //
            // The button stays mounted at zero opacity rather than being removed:
            // a removal transition here is re-decided on every render pass, and
            // sync republishes `currentTime` 4x/sec, so it would pop instead of
            // fade (same trap as the HUD itself, see `PlayerSessionView`).
            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .contentTransition(.symbolEffect(.replace, options: .speed(2)))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .opacity(isSpinnerActive ? 0 : 1)
            .allowsHitTesting(!isSpinnerActive)
            .accessibilityHidden(isSpinnerActive)
            .animation(.easeInOut(duration: 0.15), value: isSpinnerActive)
            Spacer()
        }
    }

    /// Mirrors what makes `PlayerView`'s spinner visible. `playerLoadingState` is
    /// the coordinator's single source of truth for that; the view-model-local
    /// startup checks stay in as a same-frame guard, since the coordinator reads
    /// its own engine reference and can lag by a render pass across a handoff.
    private var isLoadingPresentationActive: Bool {
        playback.playerLoadingState.isVisible ||
            viewModel.isAwaitingPlaybackStart ||
            isAutomaticFallbackPresentationActive
    }

    private var isAutomaticFallbackPresentationActive: Bool {
        playback.isAutomaticDirectPlayFallbackActive ||
            (
                playback.isAutomaticDirectPlayFallbackAvailable &&
                    viewModel.playbackError != nil
            )
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            PlayerSeekBar(
                viewModel: viewModel,
                isInteractive: true,
                scrubPreviewSource: scrubPreviewSource
            )

            HStack {
                PlayerTimeStatusView(viewModel: viewModel)

                Spacer()

                PlayerTrackSettingsMenu(
                    viewModel: viewModel,
                    context: context
                )
            }
        }
    }
}
