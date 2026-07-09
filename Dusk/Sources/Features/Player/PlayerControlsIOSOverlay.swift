import SwiftUI

struct PlayerControlsIOSOverlay: View {
    let viewModel: PlayerViewModel
    let context: PlayerControlsContext
    let scrubPreviewSource: PlexScrubPreviewSource?
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
                .padding(.top, 16)
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

            pictureInPictureButton
            aspectFillButton
        }
    }

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

        return HStack {
            Spacer()
            // Hidden during startup (including the VLCKit audio warmup,
            // masked as .loading): the button would render "play" while
            // video is already moving and then flip the moment the warmup
            // completes. The standard buffering spinner in PlayerView covers
            // the loading presentation instead.
            if !viewModel.isAwaitingPlaybackStart {
                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 44))
                        .contentTransition(.symbolEffect(.replace, options: .speed(2)))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            Spacer()
        }
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
