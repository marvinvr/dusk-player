import SwiftUI
import UIKit

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
                .font(titleFont)
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

    private var titleFont: Font {
        #if os(tvOS)
        header.usesCompactTitleOnTV ? .subheadline.weight(.semibold) : .headline.weight(.semibold)
        #else
        .headline.weight(.semibold)
        #endif
    }
}

struct PlayerTimeStatusView: View {
    let viewModel: PlayerViewModel
    let position: TimeInterval?

    init(viewModel: PlayerViewModel, position: TimeInterval? = nil) {
        self.viewModel = viewModel
        self.position = position
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(formattedPosition)
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

    private var formattedPosition: String {
        guard let position else {
            return viewModel.formattedTime
        }

        return formatTime(position)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

struct PlayerSeekBar: View {
    let viewModel: PlayerViewModel
    let isInteractive: Bool
    let scrubPreviewSource: PlexScrubPreviewSource?
    let progressPosition: TimeInterval?

    private let trackHeight: CGFloat = 8

    init(
        viewModel: PlayerViewModel,
        isInteractive: Bool,
        scrubPreviewSource: PlexScrubPreviewSource? = nil,
        progressPosition: TimeInterval? = nil
    ) {
        self.viewModel = viewModel
        self.isInteractive = isInteractive
        self.scrubPreviewSource = scrubPreviewSource
        self.progressPosition = progressPosition
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progressBase = progressPosition ?? viewModel.displayPosition
            let progress = viewModel.duration > 0 ? progressBase / viewModel.duration : 0
            let playedWidth = playedTrackWidth(for: progress, totalWidth: width)
            let clampedProgress = max(0, min(progress, 1))
            let scrubX = width * clampedProgress
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

            ZStack(alignment: .topLeading) {
                #if os(tvOS)
                seekTrack
                #else
                if isInteractive {
                    seekTrack.gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard width > 0 else { return }
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

                if viewModel.isScrubbing,
                   let scrubPreviewSource,
                   scrubPreviewSource.isAvailable {
                    PlayerScrubPreviewPopup(
                        source: scrubPreviewSource,
                        position: viewModel.displayPosition
                    )
                    .position(
                        x: scrubPreviewX(scrubX, totalWidth: width),
                        y: PlayerScrubPreviewPopup.verticalPosition
                    )
                    .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
                    .zIndex(2)
                }
                #endif
            }
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

    private func scrubPreviewX(_ proposedX: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let halfWidth = PlayerScrubPreviewPopup.width / 2
        guard totalWidth > halfWidth * 2 else {
            return max(totalWidth / 2, halfWidth)
        }

        return min(max(proposedX, halfWidth), totalWidth - halfWidth)
    }
}

struct PlayerScrubPreviewPopup: View {
    let source: PlexScrubPreviewSource
    let position: TimeInterval

    #if os(tvOS)
    static let width: CGFloat = 240
    #else
    static let width: CGFloat = 156
    #endif
    static let aspectRatio: CGFloat = 16.0 / 9.0
    static let height: CGFloat = width / aspectRatio
    static let verticalPosition: CGFloat = -(height / 2 + 12)

    private var frame: PlexScrubPreviewFrame? {
        source.frame(at: position)
    }

    var body: some View {
        if let frame,
           let image = UIImage(data: frame.imageData) {
            ZStack(alignment: .bottom) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.width, height: Self.height)
                    .clipped()

                Text(formattedTime(position))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.58), in: Capsule())
                    .padding(.bottom, 6)
            }
            .frame(width: Self.width, height: Self.height)
            .background(.black, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.42), radius: 18, y: 8)
            .allowsHitTesting(false)
        }
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

struct PlayerTrackSettingsMenu: View {
    @Environment(PlaybackCoordinator.self) private var playback

    let viewModel: PlayerViewModel
    let context: PlayerControlsContext

    private var hasAvailableSettings: Bool {
        context.hasPlaybackInfo ||
            context.hasQualityControl ||
            !viewModel.audioTracks.isEmpty ||
            !viewModel.subtitleTracks.isEmpty
    }

    var body: some View {
        #if os(tvOS)
        tvOSMenu
        #else
        iOSMenu
        #endif
    }

    #if os(tvOS)
    private var tvOSMenu: some View {
        Menu {
            playbackInfoButton
            qualityMenu
            subtitleTracksMenu
            audioTracksMenu
        } label: {
            Image(systemName: "gearshape")
                .font(.footnote.weight(.semibold))
                .accessibilityLabel("Playback Settings")
        }
        .disabled(!hasAvailableSettings)
        .buttonStyle(.glass)
        .controlSize(.small)
        .tint(.white)
    }

    private var qualityMenu: some View {
        Menu {
            if !context.canSelectQuality {
                Button("Unavailable Offline") {}
                    .disabled(true)
            } else {
                ForEach(context.availableQualityPresets) { preset in
                    Button {
                        Task {
                            await playback.switchQuality(to: preset)
                        }
                    } label: {
                        trackMenuItem(
                            title: preset.displayName,
                            subtitle: preset.detailTitle,
                            isSelected: context.selectedQualityPreset == preset
                        )
                    }
                    .disabled(context.isChangingQuality || context.selectedQualityPreset == preset)
                }
            }
        } label: {
            Label("Quality", systemImage: "rectangle.compress.vertical")
        }
        .disabled(!context.canSelectQuality || context.isChangingQuality)
    }

    private var subtitleTracksMenu: some View {
        Menu {
            if viewModel.subtitleTracks.isEmpty {
                Button("No Subtitles") {}
                    .disabled(true)
            } else {
                Button {
                    viewModel.selectSubtitle(nil)
                } label: {
                    trackMenuItem(
                        title: "Off",
                        subtitle: nil,
                        isSelected: viewModel.selectedSubtitleTrack == nil
                    )
                }

                ForEach(viewModel.subtitleTracks) { track in
                    Button {
                        viewModel.selectSubtitle(track)
                    } label: {
                        trackMenuItem(
                            title: track.displayTitle,
                            subtitle: track.language,
                            isSelected: viewModel.selectedSubtitleTrackID == track.id
                        )
                    }
                }
            }
        } label: {
            Label {
                Text("Subtitles")
            } icon: {
                Image(systemName: viewModel.selectedSubtitleTrack == nil ? "captions.bubble" : "captions.bubble.fill")
            }
        }
        .disabled(viewModel.subtitleTracks.isEmpty)
    }

    private var audioTracksMenu: some View {
        Menu {
            if viewModel.audioTracks.isEmpty {
                Button("No Audio Tracks") {}
                    .disabled(true)
            } else {
                ForEach(viewModel.audioTracks) { track in
                    Button {
                        viewModel.selectAudio(track)
                    } label: {
                        trackMenuItem(
                            title: track.compactDisplayTitle,
                            subtitle: track.detailDisplayTitle,
                            isSelected: viewModel.selectedAudioTrackID == track.id
                        )
                    }
                }
            }
        } label: {
            Label("Audio", systemImage: "speaker.wave.2")
        }
        .disabled(viewModel.audioTracks.isEmpty)
    }

    @ViewBuilder
    private var playbackInfoButton: some View {
        if context.hasPlaybackInfo {
            Button {
                viewModel.showPlaybackInfo = true
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
        }
    }
    #else
    private var iOSMenu: some View {
        Menu {
            if context.hasPlaybackInfo {
                Button {
                    viewModel.showPlaybackInfo = true
                } label: {
                    Label("Get Info", systemImage: "info.circle")
                }
            }

            Button {
                viewModel.showQualityPicker = true
            } label: {
                settingsMenuItem(
                    title: "Quality",
                    subtitle: context.qualityControlTitle,
                    icon: "rectangle.compress.vertical"
                )
            }
            .disabled(!context.canSelectQuality || context.isChangingQuality)

            Button {
                viewModel.showAudioPicker = true
            } label: {
                settingsMenuItem(
                    title: "Audio",
                    subtitle: context.audioControlTitle,
                    icon: "speaker.wave.2"
                )
            }
            .disabled(viewModel.audioTracks.isEmpty)

            Button {
                viewModel.showSubtitlePicker = true
            } label: {
                settingsMenuItem(
                    title: "Subtitles",
                    subtitle: context.subtitleControlTitle,
                    icon: viewModel.selectedSubtitleTrack == nil ? "captions.bubble" : "captions.bubble.fill"
                )
            }
            .disabled(viewModel.subtitleTracks.isEmpty)
        } label: {
            Image(systemName: "gearshape")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(hasAvailableSettings ? 1.0 : 0.72))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
                .accessibilityLabel("Playback Settings")
        }
        .disabled(!hasAvailableSettings)
    }

    private func settingsMenuItem(
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)

                Text(subtitle)
                    .font(.caption)
            }
        } icon: {
            Image(systemName: icon)
        }
    }
    #endif

    private func trackMenuItem(
        title: String,
        subtitle: String?,
        isSelected: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.duskTextPrimary)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 20)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.duskAccent)
            }
        }
    }
}
