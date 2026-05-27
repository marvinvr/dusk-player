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
        }
    }

    private var centerControls: some View {
        let isPlaying = viewModel.state == .playing

        return HStack {
            Spacer()
            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .contentTransition(.symbolEffect(.replace, options: .speed(2)))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.ultraThinMaterial, in: Circle())
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
