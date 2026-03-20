import SwiftUI

struct PlayerControlsGradientBackdrop: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)

            Spacer()

            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 160)
        }
        .ignoresSafeArea()
    }
}

struct PlayerMediaHeaderView: View {
    let header: PlayerMediaHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let secondaryTitle = header.secondaryTitle {
                Text(secondaryTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    #if os(tvOS)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    #else
                    .lineLimit(2)
                    #endif
            }

            if let subtitle = header.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
    }
}

struct PlayerTimeStatusView: View {
    let viewModel: PlayerViewModel

    var body: some View {
        HStack(spacing: 6) {
            Text(viewModel.formattedTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))

            Text("/")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))

            Text(viewModel.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

struct PlayerSeekBar: View {
    let viewModel: PlayerViewModel
    let isInteractive: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progress = viewModel.duration > 0 ? viewModel.displayPosition / viewModel.duration : 0
            let seekTrack = ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(0.3))
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.duskAccent)
                    .frame(width: max(0, width * progress), height: 4)

                Circle()
                    .fill(Color.duskAccent)
                    .frame(
                        width: viewModel.isScrubbing ? 16 : 12,
                        height: viewModel.isScrubbing ? 16 : 12
                    )
                    .offset(x: thumbOffset(progress: progress, trackWidth: width))
                    .animation(.easeOut(duration: 0.15), value: viewModel.isScrubbing)
            }
            .frame(height: 32)
            .contentShape(Rectangle())

            #if os(tvOS)
            seekTrack
            #else
            if isInteractive {
                seekTrack.gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !viewModel.isScrubbing {
                                viewModel.beginScrub()
                            }
                            let fraction = max(0, min(1, value.location.x / width))
                            viewModel.updateScrub(to: fraction * viewModel.duration)
                        }
                        .onEnded { _ in
                            viewModel.endScrub()
                        }
                )
            } else {
                seekTrack
            }
            #endif
        }
        .frame(height: 32)
    }

    private func thumbOffset(progress: Double, trackWidth: Double) -> Double {
        let thumbRadius: Double = viewModel.isScrubbing ? 8 : 6
        return max(0, min(trackWidth * progress - thumbRadius, trackWidth - thumbRadius * 2))
    }
}
