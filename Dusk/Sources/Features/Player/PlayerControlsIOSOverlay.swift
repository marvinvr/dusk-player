import SwiftUI

struct PlayerControlsIOSOverlay: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(UserPreferences.self) private var preferences

    let viewModel: PlayerViewModel
    let context: PlayerControlsContext
    let scrubPreviewSource: ScrubPreviewFrameSet?
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

    /// Episode and skip buttons together are five circles, wider than an
    /// iPhone held upright at the usual spacing, so the row tightens until it
    /// fits instead of clipping.
    private var centerControls: some View {
        ViewThatFits(in: .horizontal) {
            centerControlsRow(spacing: 44)
            centerControlsRow(spacing: 24)
            centerControlsRow(spacing: 8)
        }
    }

    private func centerControlsRow(spacing: CGFloat) -> some View {
        let isPlaying = viewModel.state == .playing
        let isSpinnerActive = isLoadingPresentationActive

        return HStack(spacing: spacing) {
            Spacer(minLength: 0)
            if showsEpisodeButtons {
                episodeButton(.previous)
            }
            if context.showsSkipButtons {
                skipButton(direction: -1)
            }
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
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .opacity(isSpinnerActive ? 0 : 1)
            .allowsHitTesting(!isSpinnerActive)
            .accessibilityHidden(isSpinnerActive)
            .animation(.easeInOut(duration: 0.15), value: isSpinnerActive)
            if context.showsSkipButtons {
                skipButton(direction: 1)
            }
            if showsEpisodeButtons {
                episodeButton(.next)
            }
            Spacer(minLength: 0)
        }
    }

    /// Opt-in (`playerEpisodeButtonsEnabled`) and episodes only:
    /// `adjacentEpisodes` is nil for movies, clips and Live TV. The buttons
    /// stay mounted while the lookup runs and at the first / last episode,
    /// just dimmed, so Play never shifts sideways.
    private var showsEpisodeButtons: Bool {
        preferences.playerEpisodeButtonsEnabled && playback.adjacentEpisodes != nil
    }

    private func episodeButton(_ direction: AdjacentEpisodeDirection) -> some View {
        let episode = playback.adjacentEpisodes?.episode(direction)
        let isEnabled = episode != nil && playback.canStepEpisodes

        return Button {
            playback.playAdjacentEpisode(direction, isPastCredits: viewModel.isPastCreditsMarker)
        } label: {
            Image(systemName: direction == .next ? "forward.end.fill" : "backward.end.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial, in: Circle())
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .animation(.easeInOut(duration: 0.15), value: isEnabled)
        .accessibilityLabel(direction == .next ? "Next Episode" : "Previous Episode")
        .accessibilityValue(episode.flatMap {
            MediaTextFormatter.seasonEpisodeLabel(season: $0.parentIndex, episode: $0.index)
        } ?? "")
    }

    /// Advanced playback controls, sized like the episode buttons beside Play.
    /// Same intervals and feedback as the double-tap seek zones.
    private func skipButton(direction: Int) -> some View {
        let interval = direction < 0
            ? preferences.playerDoubleTapBackwardInterval
            : preferences.playerDoubleTapForwardInterval
        let seconds = interval.rawValue

        return Button {
            viewModel.handleSeekJump(by: TimeInterval(direction) * interval.timeInterval)
            viewModel.noteControlsInteraction()
        } label: {
            // Every `PlayerSeekInterval` (5…60 s) has a numbered symbol.
            Image(systemName: direction < 0 ? "gobackward.\(seconds)" : "goforward.\(seconds)")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial, in: Circle())
        }
        .disabled(viewModel.playbackError != nil)
        .accessibilityLabel(direction < 0 ? "Skip Back \(seconds) Seconds" : "Skip Forward \(seconds) Seconds")
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

                if context.speedControl != .hidden {
                    PlayerSpeedMenu(viewModel: viewModel, availability: context.speedControl)
                }

                PlayerTrackSettingsMenu(
                    viewModel: viewModel,
                    context: context
                )
            }
        }
    }
}

/// Playback speed (advanced playback controls). Sits beside the settings gear
/// with the same 36pt chrome; shows the chosen rate once it is not 1×.
private struct PlayerSpeedMenu: View {
    let viewModel: PlayerViewModel
    let availability: PlayerSpeedControlAvailability

    var body: some View {
        Menu {
            if availability == .available {
                Picker("Playback Speed", selection: Binding(
                    get: { viewModel.playbackRate },
                    set: { viewModel.setPlaybackRate($0) }
                )) {
                    ForEach(PlayerViewModel.playbackSpeedOptions, id: \.self) { rate in
                        Text(PlayerViewModel.playbackSpeedTitle(rate)).tag(rate)
                    }
                }
                .pickerStyle(.inline)
            } else {
                Text(PlayerSpeedControlAvailability.unavailableMessage)
            }
        } label: {
            label
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 36, minHeight: 36)
                .padding(.horizontal, isNormalRate ? 0 : 6)
                .background(.white.opacity(0.12), in: Capsule())
                .accessibilityLabel("Playback Speed")
                .accessibilityValue(PlayerViewModel.playbackSpeedTitle(viewModel.playbackRate))
        }
        // Same reason as the settings menu: a native `Menu` has no
        // presentation callback, so the opening tap extends the HUD.
        .simultaneousGesture(TapGesture().onEnded {
            viewModel.noteSettingsMenuInteraction()
        })
    }

    private var isNormalRate: Bool {
        viewModel.playbackRate == 1
    }

    @ViewBuilder
    private var label: some View {
        if isNormalRate {
            Image(systemName: "gauge.with.dots.needle.67percent")
        } else {
            Text(String(format: "%g×", Double(viewModel.playbackRate)))
                .monospacedDigit()
        }
    }
}
