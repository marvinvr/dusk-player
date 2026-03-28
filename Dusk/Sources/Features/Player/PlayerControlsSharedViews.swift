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
                #if os(tvOS)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                #else
                .lineLimit(1)
                #endif

            if let secondaryTitle = header.secondaryTitle {
                Text(secondaryTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    #if os(tvOS)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
        #if os(tvOS)
        .frame(maxWidth: 560, alignment: .leading)
        #else
        .frame(maxWidth: 320, alignment: .leading)
        #endif
        .layoutPriority(1)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
    }
}

struct PlayerTimeStatusView: View {
    let viewModel: PlayerViewModel

    var body: some View {
        HStack(spacing: 6) {
            Text(viewModel.formattedTime)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))

            Text("/")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.5))

            Text(viewModel.formattedDuration)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

struct PlayerSeekBar: View {
    let viewModel: PlayerViewModel
    let isInteractive: Bool

    private let trackHeight: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progress = viewModel.duration > 0 ? viewModel.displayPosition / viewModel.duration : 0
            let playedWidth = playedTrackWidth(for: progress, totalWidth: width)
            let seekTrack = ZStack(alignment: .leading) {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule()
                            .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
                    }
                    .frame(height: trackHeight)

                if playedWidth > 0 {
                    Capsule()
                        .fill(.white.opacity(0.96))
                        .frame(width: playedWidth, height: trackHeight)
                        .shadow(color: .white.opacity(0.18), radius: 5)
                }
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

    private func playedTrackWidth(for progress: Double, totalWidth: CGFloat) -> CGFloat {
        let clampedProgress = max(0, min(progress, 1))
        guard clampedProgress > 0, totalWidth > 0 else { return 0 }

        return min(
            max(trackHeight, totalWidth * clampedProgress),
            totalWidth
        )
    }
}
