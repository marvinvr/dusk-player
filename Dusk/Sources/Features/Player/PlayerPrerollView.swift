import SwiftUI

/// A server pre-roll video playing ahead of a movie (`PrerollPlayback`).
///
/// Deliberately not the full player: a pre-roll has no tracks to pick, no
/// timeline to scrub and no watch state, so it gets the video, a Skip chip
/// where Skip Intro sits, and the way out. Skip moves to the next pre-roll,
/// or to the movie after the last one; a pre-roll that fails to play is
/// skipped the same way, because it must never stand between the viewer and
/// the movie.
struct PlayerPrerollView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.dismiss) private var dismiss

    let engine: any PlaybackEngine
    let playbackSource: PlaybackSource
    let presentationID: UUID

    @State private var engineView: AnyView

    init(engine: any PlaybackEngine, playbackSource: PlaybackSource, presentationID: UUID) {
        self.engine = engine
        self.playbackSource = playbackSource
        self.presentationID = presentationID
        _engineView = State(initialValue: engine.makePlayerView())
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            engineView
                .ignoresSafeArea()

            #if os(tvOS)
            PlayerTVRemoteInputBridge(isCaptureEnabled: true) { input in
                handle(input)
            }
            .ignoresSafeArea()
            #else
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { togglePlayPause() }
                .ignoresSafeArea()
            #endif

            if engine.state == .paused {
                pausedGlyph
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            #if !os(tvOS)
            closeButton
            #endif

            skipButton
        }
        .animation(.easeInOut(duration: 0.2), value: engine.state == .paused)
        .onAppear {
            guard engine.state == .idle else { return }
            engine.load(source: playbackSource)
        }
        .onChange(of: engine.state, initial: true) { _, state in
            playback.noteActivePlaybackState(state)
            if state == .error {
                skip()
            }
        }
        .onChange(of: engine.error != nil) { _, hasError in
            if hasError {
                skip()
            }
        }
        .onChange(of: engine.isBuffering) { _, isBuffering in
            playback.setBufferingPresentationVisible(isBuffering, for: presentationID)
        }
        .persistentSystemOverlays(.hidden)
    }

    private var skipButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                #if os(tvOS)
                // Not a Button, like Skip Intro: the input bridge owns the
                // remote and turns Select into a skip.
                PlayerTVSkipChip(title: "Skip", countdownProgress: nil, isSelected: true)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Skip")
                #else
                Button(action: skip) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.forward.2")
                            .font(DuskFont.glyphSmall(ios: .callout.weight(.semibold)))
                        Text("Skip")
                            .font(DuskFont.buttonLabel(ios: .subheadline.weight(.semibold)))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                }
                .buttonStyle(.plain)
                #endif
            }
        }
        .padding(.horizontal, PlayerOverlayLayout.bottomTrailingHorizontalPadding)
        .padding(.bottom, PlayerOverlayLayout.skipMarkerRestingBottomInset)
        .ignoresSafeArea(edges: PlayerOverlayLayout.bottomTrailingIgnoredSafeAreaEdges)
    }

    #if !os(tvOS)
    private var closeButton: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close Player")
                Spacer()
            }
            Spacer()
        }
        .padding(.horizontal, PlayerOverlayLayout.controlsHorizontalPadding)
        .padding(.top, 8)
    }
    #endif

    private var pausedGlyph: some View {
        Image(systemName: "pause.fill")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 88, height: 88)
            .background(.ultraThinMaterial, in: Circle())
    }

    private func skip() {
        playback.advancePreroll(from: presentationID)
    }

    private func togglePlayPause() {
        if engine.state == .playing {
            engine.pause()
        } else {
            engine.play()
        }
    }

    #if os(tvOS)
    private func handle(_ input: PlayerTVRemoteInput) {
        switch input {
        case .select, .arrowDown(.right):
            skip()
        case .playPause, .touchTap:
            togglePlayPause()
        case .menu:
            dismiss()
        default:
            break
        }
    }
    #endif
}
