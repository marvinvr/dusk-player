#if os(tvOS)
import SwiftUI

struct PlayerControlsTVOverlay: View {
    @FocusState private var focusedControl: FocusTarget?

    let viewModel: PlayerViewModel
    let context: PlayerControlsContext
    let hasActiveSkipMarker: Bool
    let onDismiss: () -> Void

    private let skipInterval: TimeInterval = 10

    private enum FocusTarget: Hashable {
        case close
        case skipBackward
        case playPause
        case skipForward
        case subtitles
        case audio
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                PlayerControlsGradientBackdrop()

                VStack(spacing: 26) {
                    topBar
                    Spacer()
                    transportControls
                    Spacer()
                    bottomBar
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 28)
                .focusSection()
            }
        }
        .defaultFocus($focusedControl, .playPause)
        .onAppear {
            if viewModel.showControls && !hasActiveSkipMarker {
                focusedControl = .playPause
            }
        }
        .onChange(of: viewModel.showControls) { _, isShowing in
            focusedControl = isShowing && !hasActiveSkipMarker ? .playPause : nil
        }
        .onChange(of: hasActiveSkipMarker) { _, isVisible in
            if !isVisible, viewModel.showControls {
                focusedControl = .playPause
            }
        }
        .onMoveCommand(perform: handleMoveCommand)
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 18) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .duskSuppressTVOSButtonChrome()
            .duskTVOSFocusEffectShape(Circle())
            .focused($focusedControl, equals: .close)

            if let header = context.mediaHeader {
                PlayerMediaHeaderView(header: header)
            }

            Spacer()
        }
    }

    private var transportControls: some View {
        let isPlaying = viewModel.state == .playing

        return HStack(spacing: 28) {
            transportButton(systemImage: "gobackward.10") {
                viewModel.handleDoubleTapSeek(by: -skipInterval)
            }
            .focused($focusedControl, equals: .skipBackward)

            transportButton(
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                font: .system(size: 46, weight: .medium)
            ) {
                viewModel.togglePlayPause()
            }
            .focused($focusedControl, equals: .playPause)

            transportButton(systemImage: "goforward.10") {
                viewModel.handleDoubleTapSeek(by: skipInterval)
            }
            .focused($focusedControl, equals: .skipForward)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 18) {
            PlayerSeekBar(viewModel: viewModel, isInteractive: false)
                .frame(height: 36)

            HStack(alignment: .center, spacing: 18) {
                PlayerTimeStatusView(viewModel: viewModel)

                Spacer()

                subtitleMenu
                audioMenu
            }
        }
    }

    private var subtitleMenu: some View {
        Menu {
            if viewModel.subtitleTracks.isEmpty {
                Button("No Subtitles") {}
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
            trackMenuLabel(
                icon: viewModel.selectedSubtitleTrack == nil ? "captions.bubble" : "captions.bubble.fill",
                title: context.subtitleControlTitle,
                isEnabled: !viewModel.subtitleTracks.isEmpty
            )
        }
        .disabled(viewModel.subtitleTracks.isEmpty)
        .focused($focusedControl, equals: .subtitles)
        .duskSuppressTVOSButtonChrome()
        .duskTVOSFocusEffectShape(Capsule())
    }

    private var audioMenu: some View {
        Menu {
            if viewModel.audioTracks.isEmpty {
                Button("No Audio Tracks") {}
            } else {
                ForEach(viewModel.audioTracks) { track in
                    Button {
                        viewModel.selectAudio(track)
                    } label: {
                        trackMenuItem(
                            title: track.displayTitle,
                            subtitle: track.language,
                            isSelected: viewModel.selectedAudioTrackID == track.id
                        )
                    }
                }
            }
        } label: {
            trackMenuLabel(
                icon: "speaker.wave.2",
                title: context.audioControlTitle,
                isEnabled: !viewModel.audioTracks.isEmpty
            )
        }
        .disabled(viewModel.audioTracks.isEmpty)
        .focused($focusedControl, equals: .audio)
        .duskSuppressTVOSButtonChrome()
        .duskTVOSFocusEffectShape(Capsule())
    }

    private func transportButton(
        systemImage: String,
        font: Font = .system(size: 34, weight: .medium),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .duskSuppressTVOSButtonChrome()
        .duskTVOSFocusEffectShape(Circle())
    }

    private func trackMenuLabel(
        icon: String,
        title: String,
        isEnabled: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.72))
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.white.opacity(0.12), in: Capsule())
    }

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

    // Explicit routing keeps the custom tvOS layout from trapping focus on the dismiss button.
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        let currentFocus = focusedControl ?? .playPause

        switch direction {
        case .up:
            focusedControl = focusTargetAbove(currentFocus)
        case .down:
            focusedControl = focusTargetBelow(currentFocus)
        case .left:
            focusedControl = focusTargetLeft(currentFocus)
        case .right:
            focusedControl = focusTargetRight(currentFocus)
        default:
            break
        }
    }

    private func focusTargetAbove(_ current: FocusTarget) -> FocusTarget? {
        switch current {
        case .close:
            return nil
        case .skipBackward, .playPause, .skipForward:
            return .close
        case .subtitles, .audio:
            return .playPause
        }
    }

    private func focusTargetBelow(_ current: FocusTarget) -> FocusTarget? {
        switch current {
        case .close:
            return .playPause
        case .skipBackward, .playPause:
            return subtitlesOrAudioTarget(preferSubtitles: true)
        case .skipForward:
            return subtitlesOrAudioTarget(preferSubtitles: false)
        case .subtitles, .audio:
            return nil
        }
    }

    private func focusTargetLeft(_ current: FocusTarget) -> FocusTarget? {
        switch current {
        case .close:
            return nil
        case .skipBackward:
            return .close
        case .playPause:
            return .skipBackward
        case .skipForward:
            return .playPause
        case .subtitles:
            return .playPause
        case .audio:
            return viewModel.subtitleTracks.isEmpty ? .playPause : .subtitles
        }
    }

    private func focusTargetRight(_ current: FocusTarget) -> FocusTarget? {
        switch current {
        case .close:
            return .playPause
        case .skipBackward:
            return .playPause
        case .playPause:
            return .skipForward
        case .skipForward:
            return viewModel.audioTracks.isEmpty ? nil : .audio
        case .subtitles:
            return viewModel.audioTracks.isEmpty ? nil : .audio
        case .audio:
            return nil
        }
    }

    private func subtitlesOrAudioTarget(preferSubtitles: Bool) -> FocusTarget? {
        if preferSubtitles {
            if !viewModel.subtitleTracks.isEmpty {
                return .subtitles
            }
            if !viewModel.audioTracks.isEmpty {
                return .audio
            }
        } else {
            if !viewModel.audioTracks.isEmpty {
                return .audio
            }
            if !viewModel.subtitleTracks.isEmpty {
                return .subtitles
            }
        }

        return nil
    }
}
#endif
