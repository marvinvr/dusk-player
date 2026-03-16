import SwiftUI

struct PlayerControlsOverlay: View {
    let viewModel: PlayerViewModel
    let mediaDetails: PlexMediaDetails?
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let showsTrackLabels = geometry.size.width > geometry.size.height

            ZStack {
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

                VStack {
                    topBar
                    Spacer()
                    centerControls
                    Spacer()
                    bottomBar(showsTrackLabels: showsTrackLabels)
                }
                .padding(.horizontal, PlayerOverlayLayout.controlsHorizontalPadding)
                .padding(.vertical, 16)
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }

            if let header = mediaHeader {
                mediaHeaderView(header)
            }

            Spacer()
        }
    }

    private func mediaHeaderView(_ header: PlayerMediaHeader) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let secondaryTitle = header.secondaryTitle {
                Text(secondaryTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
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

    private var mediaHeader: PlayerMediaHeader? {
        guard let mediaDetails else { return nil }

        if mediaDetails.type == .episode {
            let title = mediaDetails.grandparentTitle ?? mediaDetails.title
            let secondaryTitle = mediaDetails.grandparentTitle == nil ? nil : mediaDetails.title
            let subtitle = MediaTextFormatter.seasonEpisodeLabel(
                season: mediaDetails.parentIndex,
                episode: mediaDetails.index
            )

            return PlayerMediaHeader(
                title: title,
                secondaryTitle: secondaryTitle,
                subtitle: subtitle
            )
        }

        return PlayerMediaHeader(
            title: mediaDetails.title,
            secondaryTitle: nil,
            subtitle: mediaDetails.year.map(String.init)
        )
    }

    private var centerControls: some View {
        let isPlaying = viewModel.state == .playing

        return HStack {
            Spacer()
            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.11), value: isPlaying)
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
        }
    }

    private func bottomBar(showsTrackLabels: Bool) -> some View {
        VStack(spacing: 8) {
            seekBar

            HStack {
                Text(viewModel.formattedTime)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))

                Text("/")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

                Text(viewModel.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))

                Spacer()

                Button { viewModel.showSubtitlePicker = true } label: {
                    trackButtonLabel(
                        icon: viewModel.selectedSubtitleTrack == nil ? "captions.bubble" : "captions.bubble.fill",
                        title: subtitleControlTitle,
                        showsTitle: showsTrackLabels,
                        isEnabled: !viewModel.subtitleTracks.isEmpty
                    )
                }
                .disabled(viewModel.subtitleTracks.isEmpty)

                Button { viewModel.showAudioPicker = true } label: {
                    trackButtonLabel(
                        icon: "speaker.wave.2",
                        title: audioControlTitle,
                        showsTitle: showsTrackLabels,
                        isEnabled: !viewModel.audioTracks.isEmpty
                    )
                }
                .disabled(viewModel.audioTracks.isEmpty)
            }
        }
    }

    private var subtitleControlTitle: String {
        if let selectedSubtitleTrack = viewModel.selectedSubtitleTrack {
            return selectedSubtitleTrack.displayTitle
        }

        return viewModel.state == .loading ? "..." : "No Subtitles"
    }

    private var audioControlTitle: String {
        if let selectedAudioTrack = viewModel.selectedAudioTrack {
            return selectedAudioTrack.displayTitle
        }

        return viewModel.state == .loading ? "..." : "-"
    }

    private func trackButtonLabel(
        icon: String,
        title: String,
        showsTitle: Bool,
        isEnabled: Bool
    ) -> some View {
        HStack(spacing: showsTitle ? 8 : 0) {
            Image(systemName: icon)
                .font(.body)
                .frame(width: 16, height: 16, alignment: .center)

            if showsTitle {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.white.opacity(isEnabled ? 1.0 : 0.72))
        .padding(.horizontal, showsTitle ? 10 : 0)
        .frame(
            width: showsTitle ? 132 : 36,
            height: 36,
            alignment: showsTitle ? .leading : .center
        )
        .background(.white.opacity(0.12), in: Capsule())
    }

    private var seekBar: some View {
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
            #endif
        }
        .frame(height: 32)
    }

    private func thumbOffset(progress: Double, trackWidth: Double) -> Double {
        let thumbRadius: Double = viewModel.isScrubbing ? 8 : 6
        return max(0, min(trackWidth * progress - thumbRadius, trackWidth - thumbRadius * 2))
    }
}

private struct PlayerMediaHeader {
    let title: String
    let secondaryTitle: String?
    let subtitle: String?
}
