import SwiftUI
import UIKit

enum PlayerOverlayLayout {
    static let controlsHorizontalPadding: CGFloat = 16
    // Bottom-trailing overlays (Skip Intro button, Up Next poster) have two
    // resting heights: low near the screen edge while the HUD is hidden, and
    // raised above the play bar while the controls are up. Keep the raised
    // inset in sync with the controls' bottom bar height.
    #if os(tvOS)
    static let skipMarkerRaisedBottomInset: CGFloat = 184
    static let skipMarkerRestingBottomInset: CGFloat = 60
    #else
    static let skipMarkerRaisedBottomInset: CGFloat = 108
    static let skipMarkerRestingBottomInset: CGFloat = 48
    #endif
    #if os(tvOS)
    static let remoteSeekInterval: TimeInterval = 10
    #endif

    static let skipMarkerRepositionAnimation: Animation = .snappy(duration: 0.35)

    static func skipMarkerBottomInset(controlsVisible: Bool) -> CGFloat {
        controlsVisible ? skipMarkerRaisedBottomInset : skipMarkerRestingBottomInset
    }

    /// iPad is the only place where hiding the status bar with the HUD actually
    /// changes the container's top safe-area inset (iPhone's inset comes from
    /// the sensor housing and does not move). Everything inside the player cover
    /// ignores that inset so the video, the loading art, and the shared spinner
    /// share one stable full-height region; the HUD reserves the captured height
    /// itself. Without this the spinner is centered in a box that grows and
    /// shrinks by the status-bar height, so it hops on every HUD toggle.
    @MainActor
    static var reservesStatusBarTopInset: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    @MainActor
    static var ignoredStatusBarSafeAreaEdges: Edge.Set {
        reservesStatusBarTopInset ? .top : []
    }

    /// The status-bar height the HUD re-reserves, captured once per session.
    /// A session may be rebuilt during an engine handoff while its status bar is
    /// hidden, in which case UIKit can temporarily report zero.
    @MainActor
    static var capturedStatusBarTopInset: CGFloat {
        #if os(iOS)
        guard reservesStatusBarTopInset else { return 0 }

        let statusBarHeight = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive ||
                    $0.activationState == .foregroundInactive
            }
            .compactMap { $0.statusBarManager?.statusBarFrame.height }
            .max() ?? 0

        return max(statusBarHeight, 24)
        #else
        return 0
        #endif
    }
}

private struct PlayerSeekFeedbackOverlayView: View {
    let presentation: PlayerSeekFeedbackPresentation

    private let badgeSize: CGFloat = 64

    var body: some View {
        GeometryReader { geometry in
            let quarterOffset = geometry.size.width / 4

            ZStack {
                if presentation.direction == .backward {
                    feedbackBadge
                        .offset(x: -quarterOffset, y: -4)
                }

                if presentation.direction == .forward {
                    feedbackBadge
                        .offset(x: quarterOffset, y: -6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private var feedbackBadge: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.08))
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                }

            Image(systemName: presentation.direction.symbolName)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .offset(y: -2)
        }
        .frame(width: badgeSize, height: badgeSize)
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        .opacity(0.7)
    }
}

private struct PlayerSpeedBoostOverlayView: View {
    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "forward.fill")
                    .font(.caption.weight(.semibold))

                Text("2× Speed")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .padding(.top, 28)

            Spacer()
        }
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
        .accessibilityLabel("Playback speed 2x")
    }
}

struct PlayerView: View {
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        ZStack {
            Group {
                if let engine = playback.engine,
                   let playbackSource = playback.playbackSource {
                    PlayerSessionView(
                        engine: engine,
                        playbackSource: playbackSource,
                        presentationID: playback.playerPresentationID,
                        mediaDetails: playback.activeItemDetails,
                        debugInfo: playback.debugInfo
                    )
                    .id(playback.playerPresentationID)
                } else if playback.showPlayer {
                    // Cover is up but no engine yet: we're preparing playback.
                    PlayerLoadingView(
                        placeholder: playback.loadingPlaceholder,
                        onCancel: { playback.dismissFailedPlayback() }
                    )
                    #if os(tvOS)
                    .onExitCommand { playback.dismissFailedPlayback() }
                    #endif
                } else {
                    Color.black.ignoresSafeArea()
                }
            }

            // This instance deliberately lives above the replaceable session
            // identity. It keeps animating while transparent, so swapping from
            // direct play to the Plex server stream cannot restart its phase.
            ProgressView()
                .scaleEffect(playerLoadingIndicatorScale)
                .tint(.white)
                .offset(y: playerLoadingIndicatorVerticalOffset)
                .opacity(playback.playerLoadingState.isVisible ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(!playback.playerLoadingState.isVisible)
        }
        // The cover's own region must not depend on status-bar visibility: the
        // session already draws through the top inset, but the spinner is
        // centered in this stack, so an inset that appears and disappears with
        // the HUD would move it by half the status-bar height mid-fade. See
        // `PlayerOverlayLayout.reservesStatusBarTopInset`.
        .ignoresSafeArea(.container, edges: PlayerOverlayLayout.ignoredStatusBarSafeAreaEdges)
        .alert(
            "Couldn't Play",
            isPresented: loadErrorPresented,
            presenting: playback.loadError
        ) { _ in
            Button("OK", role: .cancel) { playback.dismissFailedPlayback() }
        } message: { message in
            Text(message)
        }
        // Attached here, not in `PlayerSessionView`, so a single idle-timer
        // modifier survives across episode transitions (the session view is
        // rebuilt with a fresh `.id` each time). See
        // `PlaybackCoordinator.isIdleTimerSuppressed`.
        .playerIdleTimerDisabled(playback.isIdleTimerSuppressed)
    }

    /// Only surfaces pre-playback load failures (no engine yet). Errors during
    /// an active session use their own in-player surfaces; Up Next failures are
    /// shown in that overlay while its engine is still around.
    private var loadErrorPresented: Binding<Bool> {
        Binding(
            get: { playback.engine == nil && playback.loadError != nil },
            set: { isPresented in
                if !isPresented {
                    playback.loadError = nil
                }
            }
        )
    }

    private var playerLoadingIndicatorScale: CGFloat {
        playback.playerLoadingState == .preparing ? 1.2 : 1.5
    }

    private var playerLoadingIndicatorVerticalOffset: CGFloat {
        guard playback.playerLoadingState == .preparing,
              playback.loadingPlaceholder != nil else {
            return 0
        }

        #if os(tvOS)
        return 220
        #else
        return 150
        #endif
    }
}

#if !os(tvOS)
/// While AVPlayer renders on the receiver its local layer is intentionally
/// blank. Keep the phone useful as a calm, artwork-led remote rather than
/// leaving a black canvas behind Dusk's transport and track controls.
private struct PlayerAirPlayRemoteBackground: View {
    @Environment(PlexService.self) private var plexService

    let details: PlexMediaDetails?
    let routeName: String?

    var body: some View {
        ZStack {
            if let artworkURL {
                DuskAsyncImage(url: artworkURL) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 28)
                            .opacity(0.32)
                    } else {
                        Color.clear
                    }
                }
                .ignoresSafeArea()
            }

            LinearGradient(
                colors: [.black.opacity(0.42), .black.opacity(0.86)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.white)

                Text(routeName.map { "Playing on \($0)" } ?? "Playing with AirPlay")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                if let title = details?.title {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(32)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var artworkURL: URL? {
        guard let path = details?.art ?? details?.thumb else { return nil }
        return plexService.imageURL(for: path, width: 1280, height: 720)
    }
}
#endif

private struct PlayerSessionView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(UserPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: PlayerViewModel
    @State private var scrubPreviewSource: PlexScrubPreviewSource?
    #if os(tvOS)
    @FocusState private var skipMarkerFocused: Bool
    @FocusState private var backgroundFocused: Bool
    #endif

    private let playbackSource: PlaybackSource
    private let presentationID: UUID
    private let mediaDetails: PlexMediaDetails?
    private let debugInfo: PlaybackDebugInfo?
    private let controlsTopSafeAreaInset: CGFloat

    init(
        engine: any PlaybackEngine,
        playbackSource: PlaybackSource,
        presentationID: UUID,
        mediaDetails: PlexMediaDetails? = nil,
        debugInfo: PlaybackDebugInfo? = nil
    ) {
        _viewModel = State(
            initialValue: PlayerViewModel(
                engine: engine,
                markers: mediaDetails?.markers ?? [],
                liveTVContext: playbackSource.liveTVContext
            )
        )
        self.playbackSource = playbackSource
        self.presentationID = presentationID
        self.mediaDetails = mediaDetails
        self.debugInfo = debugInfo
        self.controlsTopSafeAreaInset = PlayerOverlayLayout.capturedStatusBarTopInset
    }

    var body: some View {
        @Bindable var vm = viewModel

        ZStack {
            Color.black.ignoresSafeArea()

            viewModel.engineView
                .ignoresSafeArea()

            #if !os(tvOS)
            if playback.isAirPlayPlaybackActive {
                PlayerAirPlayRemoteBackground(
                    details: mediaDetails,
                    routeName: playback.airPlayController.routeDisplayName
                )
                .transition(.opacity)
            }
            #endif

            #if os(tvOS)
            PlayerTVRemoteSeekBridge(
                isEnabled: playback.upNextPresentation == nil && viewModel.playbackError == nil,
                showsControls: viewModel.showControls,
                hasActiveSkipMarker: hasBottomTrailingFocusControl,
                backwardSeekInterval: PlayerOverlayLayout.remoteSeekInterval,
                forwardSeekInterval: PlayerOverlayLayout.remoteSeekInterval,
                onSeek: { offset in viewModel.handleSeekJump(by: offset) },
                onPlayPause: { viewModel.togglePlayPause() },
                onRevealControlsWhenHidden: { viewModel.touchControls() }
            )
            .allowsHitTesting(false)
            .ignoresSafeArea()
            #endif

            #if !os(tvOS)
            PlayerKeyboardShortcutBridge(
                isEnabled: playback.upNextPresentation == nil &&
                    !viewModel.showSubtitlePicker &&
                    !viewModel.showAudioPicker &&
                    !viewModel.showQualityPicker &&
                    !viewModel.showPlaybackInfo &&
                    viewModel.playbackError == nil,
                onTogglePlayPause: { viewModel.togglePlayPause() }
            )
            .allowsHitTesting(false)
            .ignoresSafeArea()
            #endif

            if let upNextPresentation = playback.upNextPresentation {
                PlayerUpNextOverlayView(
                    presentation: upNextPresentation,
                    plexService: plexService,
                    onPlayNow: { playback.playUpNextNow() },
                    onDismiss: { dismiss() }
                )
                .transition(.opacity)
            } else {
                interactionOverlay

                #if !os(tvOS)
                if viewModel.isSpeedBoostActive {
                    PlayerSpeedBoostOverlayView()
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                #endif

                if let seekFeedback = viewModel.seekFeedback,
                   shouldShowGlobalSeekFeedback {
                    PlayerSeekFeedbackOverlayView(presentation: seekFeedback)
                        .transition(.opacity)
                }

                if let error = viewModel.playbackError,
                   hasVisiblePlaybackError {
                    errorOverlay(error)
                }

                if let qualitySwitchError = playback.qualitySwitchError {
                    playerToast(qualitySwitchError)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let marker = viewModel.activeSkipMarker,
                   viewModel.playbackError == nil {
                    skipMarkerOverlay(marker)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if let poster = playback.upNextPoster,
                   viewModel.playbackError == nil {
                    PlayerUpNextPosterView(
                        presentation: poster,
                        plexService: plexService,
                        controlsVisible: viewModel.showControls,
                        onPlayNow: { playback.playUpNextPosterNow() },
                        onDismiss: { playback.dismissUpNextPoster(userInitiated: true) }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if !hasVisiblePlaybackError {
                    controlsOverlay
                }
            }
        }
        // On iPad, showing or hiding the status bar changes the system-provided
        // top safe area. Keep the session rooted in the same full-height region
        // and let the HUD reserve the captured inset itself, so neither the
        // video nor centered overlays jump while the two fades run. `PlayerView`
        // already ignores the same edge for the whole cover; this keeps the
        // session correct on its own terms.
        .ignoresSafeArea(.container, edges: PlayerOverlayLayout.ignoredStatusBarSafeAreaEdges)
        #if !os(tvOS)
        // Track the player's orientation from its own layout size (works on
        // iPhone rotation and iPad multitasking alike) so the per-orientation
        // zoom-to-fill preference can be applied and saved. tvOS has no zoom
        // control and no orientation concept.
        .background {
            GeometryReader { proxy in
                let isLandscape = proxy.size.width > proxy.size.height
                Color.clear
                    .onAppear { viewModel.updateVideoOrientation(isLandscape: isLandscape) }
                    .onChange(of: isLandscape) { _, newValue in
                        viewModel.updateVideoOrientation(isLandscape: newValue)
                    }
            }
        }
        #endif
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeSkipMarker?.id)
        .animation(.easeInOut(duration: 0.25), value: playback.upNextPoster?.creditsMarkerID)
        .animation(.easeOut(duration: 0.14), value: viewModel.seekFeedback?.trigger)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isSpeedBoostActive)
        .animation(.easeInOut(duration: 0.25), value: playback.upNextPresentation?.episode.ratingKey)
        .animation(.easeInOut(duration: 0.2), value: playback.qualitySwitchError)
        .duskCaptureStatusBarAppearance()
        .duskStatusBarHidden(!viewModel.showControls)
        .persistentSystemOverlays(viewModel.showControls ? .visible : .hidden)
        #if os(tvOS)
        .onPlayPauseCommand {
            viewModel.togglePlayPause()
        }
        .onExitCommand {
            if viewModel.showControls {
                dismissPlayer()
            } else {
                viewModel.toggleControls()
            }
        }
        #endif
        .onAppear {
            // If we are re-presenting after the user tapped restore on the PiP
            // window, let the system finish animating the video back into place.
            playback.notePlayerUIDidAppear()
            viewModel.configureAutomaticTrackSelection(
                preferences: preferences,
                part: debugInfo?.part ?? mediaDetails?.media.first?.parts.first,
                mediaDetails: mediaDetails,
                usesServerTrackSelection: playback.isAirPlaySession,
                selectedAudioStreamID: playback.activeAudioStreamID,
                selectedSubtitleStreamID: playback.activeSubtitleStreamID,
                spentAutoSkipMarkerIDs: playback.spentAutoSkipMarkerIDs
            )
            viewModel.autoSkipHandler = { marker in
                handleSkipMarker(marker)
            }
            viewModel.autoSkipSpentHandler = { markerID in
                playback.noteAutoSkipSpent(markerID: markerID)
            }
            viewModel.upNextPosterHandler = { creditsMarker in
                handleReachedCreditsMarker(creditsMarker)
            }
            viewModel.playbackSnapshotHandler = { state, currentTime, duration in
                playback.nowPlayingController.updatePlaybackState(
                    state: state,
                    currentTime: currentTime,
                    duration: duration
                )
                playback.noteActivePlaybackState(state)
            }
            viewModel.bufferingPresentationHandler = { isVisible in
                playback.setBufferingPresentationVisible(
                    isVisible,
                    for: presentationID
                )
            }
            viewModel.transcodeAudioFallbackHandler = { track in
                Task {
                    await playback.transcodeForUndecodableAudio(track)
                }
            }
            viewModel.plexTrackSelectionHandler = { audioStreamID, subtitleStreamID in
                playback.selectPlexStreamsForPlayback(
                    audioStreamID: audioStreamID,
                    subtitleStreamID: subtitleStreamID
                )
            }
            viewModel.startPlaybackIfNeeded(source: playbackSource)
            #if os(tvOS)
            if viewModel.activeSkipMarker != nil {
                skipMarkerFocused = true
            }
            #endif
        }
        .onDisappear {
            viewModel.playbackSnapshotHandler = nil
            viewModel.upNextPosterHandler = nil
            viewModel.plexTrackSelectionHandler = nil
            viewModel.cleanup()
            viewModel.bufferingPresentationHandler = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            playback.flushTimelineForScenePhase(newPhase)
        }
        // The coordinator refreshes the tuned channel's schedule during the
        // session; the play bar and header read it from the view model, which
        // was seeded with the snapshot taken at tune time.
        .onChange(of: playback.activeLiveTVContext) { _, context in
            guard let context, context.sessionID == viewModel.liveTVContext?.sessionID else { return }
            viewModel.liveTVContext = context
        }
        .task(id: scrubPreviewPartID) {
            await loadScrubPreviewSource(partID: scrubPreviewPartID)
        }
        #if os(tvOS)
        .onChange(of: viewModel.activeSkipMarker?.id) { _, _ in
            if viewModel.activeSkipMarker != nil {
                Task { @MainActor in
                    skipMarkerFocused = true
                }
            } else {
                skipMarkerFocused = false
            }
        }
        .onChange(of: viewModel.showControls) { _, isShowing in
            if !isShowing && viewModel.activeSkipMarker == nil && playback.upNextPoster == nil {
                Task { @MainActor in
                    backgroundFocused = true
                }
            } else if isShowing {
                backgroundFocused = false
            }
        }
        #endif
        #if !os(tvOS)
        .sheet(isPresented: $vm.showQualityPicker) {
            PlayerSelectionSheet(
                title: "Quality",
                items: debugInfo?.availableQualityPresets ?? [.original],
                selectedID: debugInfo?.qualityPreset.id,
                itemTitle: \.displayName,
                itemSubtitle: \.detailTitle,
                onSelect: { item in
                    guard let item else { return }
                    viewModel.showQualityPicker = false
                    Task {
                        await playback.switchQuality(to: item)
                    }
                },
                onDismiss: {
                    viewModel.showQualityPicker = false
                }
            )
        }
        .sheet(isPresented: $vm.showSubtitlePicker) {
            PlayerSelectionSheet(
                title: "Subtitles",
                allowsDeselection: true,
                deselectionTitle: "Off",
                items: viewModel.subtitleTracks,
                selectedID: viewModel.selectedSubtitleTrackID,
                itemTitle: \.displayTitle,
                itemSubtitle: \.language,
                onSelect: { item in
                    viewModel.selectSubtitle(item)
                },
                onDismiss: {
                    viewModel.showSubtitlePicker = false
                }
            )
        }
        .sheet(isPresented: $vm.showAudioPicker) {
            PlayerSelectionSheet(
                title: "Audio",
                items: viewModel.audioTracks,
                selectedID: viewModel.selectedAudioTrackID,
                itemTitle: \.compactDisplayTitle,
                itemSubtitle: \.detailDisplayTitle,
                onSelect: { item in
                    if let item {
                        viewModel.selectAudio(item)
                    }
                },
                onDismiss: {
                    viewModel.showAudioPicker = false
                }
            )
        }
        #endif
        #if os(tvOS)
        .fullScreenCover(isPresented: $vm.showPlaybackInfo) {
            if let debugInfo {
                PlayerPlaybackInfoView(
                    debugInfo: debugInfo,
                    state: viewModel.state,
                    isBuffering: viewModel.isBuffering,
                    selectedAudioTrack: viewModel.selectedAudioTrack,
                    engineDiagnostics: viewModel.engine.playbackDiagnostics,
                    videoEnhancementStatus: viewModel.videoEnhancementStatus
                )
            } else {
                PlayerPlaybackInfoUnavailableView()
            }
        }
        #else
        .sheet(isPresented: $vm.showPlaybackInfo) {
            if let debugInfo {
                PlayerPlaybackInfoView(
                    debugInfo: debugInfo,
                    state: viewModel.state,
                    isBuffering: viewModel.isBuffering,
                    selectedAudioTrack: viewModel.selectedAudioTrack,
                    engineDiagnostics: viewModel.engine.playbackDiagnostics,
                    videoEnhancementStatus: viewModel.videoEnhancementStatus
                )
            } else {
                PlayerPlaybackInfoUnavailableView()
            }
        }
        #endif
    }

    private func playerToast(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                .padding(.top, 28)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    /// The HUD, faded symmetrically in and out by
    /// `PlayerViewModel.controlsVisibilityAnimation`.
    ///
    /// iOS keeps the overlay mounted for the whole session and animates
    /// `opacity` instead of inserting/removing it. A SwiftUI removal transition
    /// is a lifetime decision the container re-makes on every render pass, and
    /// this one is re-made constantly: the engine sync timer republishes
    /// `currentTime` four times a second, which `activeSkipMarker` derives from,
    /// so `body` re-runs mid-fade with no animation in the transaction and
    /// finalizes the removal on the spot — the HUD vanishes instead of fading.
    /// An `opacity` animation is attached to the view itself and rides through
    /// those passes. Insertion never showed the bug because a fade-in degrades
    /// into an ordinary attribute animation on an already-live view.
    ///
    /// tvOS cannot stay mounted: `PlayerControlsTVOverlay` owns focus state and
    /// restores focus from `onAppear`, and its buttons remain focusable at zero
    /// opacity, so the remote would drive an invisible HUD. It keeps the
    /// conditional mount and binds the curve to the transition so the fade does
    /// not depend on the ambient transaction.
    @ViewBuilder
    private var controlsOverlay: some View {
        #if os(tvOS)
        if viewModel.showControls {
            playerControls
                .transition(.opacity.animation(PlayerViewModel.controlsVisibilityAnimation))
        }
        #else
        playerControls
            .opacity(viewModel.showControls ? 1 : 0)
            .allowsHitTesting(viewModel.showControls)
            // `allowsHitTesting(false)` does not take the hidden HUD out of the
            // accessibility tree on its own.
            .accessibilityHidden(!viewModel.showControls)
        #endif
    }

    private var playerControls: some View {
        PlayerControlsOverlay(
            viewModel: viewModel,
            mediaDetails: mediaDetails,
            debugInfo: debugInfo,
            scrubPreviewSource: scrubPreviewSource,
            hasActiveSkipMarker: hasBottomTrailingFocusControl,
            controlsTopSafeAreaInset: controlsTopSafeAreaInset,
            onDismiss: dismissPlayer
        )
    }

    private var interactionOverlay: some View {
        #if os(tvOS)
        GeometryReader { _ in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable(!viewModel.showControls)
                    .focused($backgroundFocused)
                    .onMoveCommand { _ in
                        if !viewModel.showControls {
                            viewModel.toggleControls()
                        }
                    }
                    .onTapGesture { viewModel.toggleControls() }

                PlayerTVTouchSurfaceTapBridge(
                    isEnabled: !viewModel.showControls,
                    onTap: { viewModel.toggleControls() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(!viewModel.showControls)
            }
        }
        .ignoresSafeArea()
        #else
        PlayerTapInteractionOverlay(
            showsControls: viewModel.showControls,
            doubleTapSeekEnabled: preferences.playerDoubleTapSeekEnabled,
            backwardSeekInterval: preferences.playerDoubleTapBackwardInterval.timeInterval,
            forwardSeekInterval: preferences.playerDoubleTapForwardInterval.timeInterval,
            onToggleControls: { viewModel.toggleControls() },
            onDoubleTapSeek: { offset in viewModel.handleDoubleTapSeek(by: offset) },
            onSpeedBoostBegan: { viewModel.beginSpeedBoost() },
            onSpeedBoostEnded: { viewModel.endSpeedBoost() },
            onPointerMoved: { viewModel.touchControls() }
        )
        .ignoresSafeArea()
        #endif
    }

    private var shouldShowGlobalSeekFeedback: Bool {
        #if os(tvOS)
        !viewModel.showControls
        #else
        true
        #endif
    }

    /// A failed direct-play engine is only an intermediate state while the
    /// automatic Plex server-stream replacement is active. Keep the existing
    /// loading presentation and controls alive until recovery succeeds or this
    /// becomes the final error the user needs to act on.
    private var hasVisiblePlaybackError: Bool {
        viewModel.playbackError != nil &&
            !playback.isAutomaticDirectPlayFallbackAvailable
    }

    private var scrubPreviewPartID: Int? {
        guard let debugInfo,
              debugInfo.canLoadScrubPreviews else {
            return nil
        }

        return debugInfo.part.id
    }

    private func skipMarkerOverlay(_ marker: PlexMarker) -> some View {
        VStack {
            Spacer()

            HStack {
                Spacer()
                Button {
                    handleSkipMarker(marker)
                } label: {
                    skipMarkerButtonLabel(marker)
                }
                #if os(tvOS)
                .focused($skipMarkerFocused)
                .duskSuppressTVOSButtonChrome()
                .contentShape(.interaction, skipMarkerButtonShape)
                .focusEffectDisabled()
                // Like the Up Next poster, this control owns focus while the
                // HUD is hidden. Keep the focus scale without the persistent
                // white halo behind Skip Intro / Skip Credits.
                .duskTVOSFocusedScale(skipMarkerFocused, glow: false)
                #else
                .buttonStyle(.plain)
                #endif
            }
        }
        .id(marker.id)
        #if os(tvOS)
        .onAppear {
            Task { @MainActor in
                skipMarkerFocused = true
            }
        }
        .onDisappear {
            skipMarkerFocused = false
        }
        #endif
        .padding(.horizontal, PlayerOverlayLayout.controlsHorizontalPadding)
        .padding(.bottom, PlayerOverlayLayout.skipMarkerBottomInset(controlsVisible: viewModel.showControls))
        .animation(PlayerOverlayLayout.skipMarkerRepositionAnimation, value: viewModel.showControls)
        .ignoresSafeArea(edges: .bottom)
    }

    private func skipMarkerButtonLabel(_ marker: PlexMarker) -> some View {
        HStack(spacing: 10) {
            Image(systemName: marker.isCredits ? "forward.end.fill" : "chevron.forward.2")
                .font(.callout.weight(.semibold))

            Text(marker.skipButtonTitle ?? "Skip")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        #if os(tvOS)
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        #else
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        #endif
        .background {
            ZStack(alignment: .leading) {
                skipMarkerButtonShape
                    .fill(skipMarkerButtonBackgroundColor)
                    .background(.ultraThinMaterial, in: skipMarkerButtonShape)

                if let progress = viewModel.autoSkipCountdownProgress {
                    GeometryReader { buttonGeometry in
                        Rectangle()
                            .fill(skipMarkerProgressColor)
                            .frame(width: buttonGeometry.size.width * max(0, min(progress, 1)))
                    }
                    .clipShape(skipMarkerButtonShape)
                    .allowsHitTesting(false)
                }
            }
        }
        .overlay {
            skipMarkerButtonShape
                .strokeBorder(skipMarkerBorderColor, lineWidth: 1)
        }
        .shadow(color: skipMarkerShadowColor, radius: skipMarkerShadowRadius, y: skipMarkerShadowYOffset)
        .opacity(0.92)
    }

    private var skipMarkerButtonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 100, style: .continuous)
    }

    // Skip Intro / Skip Credits uses the same translucent native styling on
    // every platform. tvOS used to render a heavy black fill with an
    // accent-colored countdown, which read as flat and non-native next to the
    // iPad capsule; tvOS keeps the shared focus scale without its glow.
    private var skipMarkerButtonBackgroundColor: Color {
        .white.opacity(0.08)
    }

    private var skipMarkerProgressColor: Color {
        .white.opacity(0.18)
    }

    private var skipMarkerBorderColor: Color {
        .white.opacity(0.14)
    }

    private var skipMarkerShadowColor: Color {
        .black.opacity(0.28)
    }

    private var skipMarkerShadowRadius: CGFloat {
        18
    }

    private var skipMarkerShadowYOffset: CGFloat {
        8
    }

    private func errorOverlay(_ error: PlaybackError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Color.duskAccent)

            Text(error.localizedDescription)
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)
                .multilineTextAlignment(.center)

            Button("Close", action: dismissPlayer)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .background(Color.duskAccent, in: Capsule())
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(Capsule())
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
    }

    private func dismissPlayer() {
        viewModel.cleanup()
        dismiss()
    }

    @MainActor
    private func loadScrubPreviewSource(partID: Int?) async {
        scrubPreviewSource = nil
        guard let partID else { return }

        let source = await plexService.scrubPreviewSource(forPartID: partID)
        guard !Task.isCancelled else { return }
        scrubPreviewSource = source
    }

    @MainActor
    private func handleSkipMarker(_ marker: PlexMarker) {
        viewModel.handleSkipMarker(marker)
    }

    /// Called when the reached credits marker changes. Asks the coordinator to
    /// resolve the next episode and raise the bottom-right Up Next poster (or
    /// dismiss it when the user seeked back out of the credits).
    @MainActor
    private func handleReachedCreditsMarker(_ marker: PlexMarker?) {
        guard let marker else {
            playback.dismissUpNextPoster()
            return
        }

        let presentationID = playback.playerPresentationID
        let ratingKey = playback.ratingKey
        Task {
            await playback.presentUpNextPosterIfPossible(
                creditsMarkerID: marker.id,
                isEstimated: marker.isEstimated,
                presentationID: presentationID,
                ratingKey: ratingKey
            )
        }
    }

    /// Whether a bottom-trailing control (Skip Intro button or Up Next poster)
    /// is on screen. tvOS uses it to hand remote focus to that control and pause
    /// its own remote-seek capture so the two don't fight.
    private var hasBottomTrailingFocusControl: Bool {
        viewModel.activeSkipMarker != nil || playback.upNextPoster != nil
    }
}

private extension View {
    func playerIdleTimerDisabled(_ isDisabled: Bool) -> some View {
        modifier(PlayerIdleTimerModifier(isDisabled: isDisabled))
    }
}

private struct PlayerIdleTimerModifier: ViewModifier {
    let isDisabled: Bool
    @State private var previousIdleTimerDisabled: Bool?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: updateIdleTimer)
            .onChange(of: isDisabled) { _, _ in
                updateIdleTimer()
            }
            .onDisappear(perform: restoreIdleTimer)
    }

    private func updateIdleTimer() {
        if isDisabled {
            if previousIdleTimerDisabled == nil {
                previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            }
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            restoreIdleTimer()
        }
    }

    private func restoreIdleTimer() {
        guard let previousIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        self.previousIdleTimerDisabled = nil
    }
}

#if os(tvOS)
private struct PlayerTVTouchSurfaceTapBridge: UIViewRepresentable {
    var isEnabled: Bool
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PlayerTVTouchSurfaceTapView {
        let view = PlayerTVTouchSurfaceTapView()
        view.backgroundColor = .clear
        context.coordinator.tapRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        context.coordinator.tapRecognizer.allowedPressTypes = []
        context.coordinator.tapRecognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(context.coordinator.tapRecognizer)
        context.coordinator.sync(view, with: self)
        return view
    }

    func updateUIView(_ uiView: PlayerTVTouchSurfaceTapView, context: Context) {
        context.coordinator.sync(uiView, with: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        private var parent: PlayerTVTouchSurfaceTapBridge
        let tapRecognizer = UITapGestureRecognizer()

        init(parent: PlayerTVTouchSurfaceTapBridge) {
            self.parent = parent
            super.init()
            tapRecognizer.numberOfTapsRequired = 1
            tapRecognizer.addTarget(self, action: #selector(handleTap(_:)))
        }

        func sync(_ view: PlayerTVTouchSurfaceTapView, with parent: PlayerTVTouchSurfaceTapBridge) {
            self.parent = parent
            view.isTapEnabled = parent.isEnabled
        }

        @objc
        private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard parent.isEnabled,
                  recognizer.state == .ended else {
                return
            }

            parent.onTap()
        }
    }
}

private final class PlayerTVTouchSurfaceTapView: UIView {
    var isTapEnabled = false {
        didSet {
            isUserInteractionEnabled = isTapEnabled
        }
    }

    override var canBecomeFocused: Bool {
        false
    }
}

private struct PlayerTVRemoteSeekBridge: UIViewRepresentable {
    var isEnabled: Bool
    var showsControls: Bool
    var hasActiveSkipMarker: Bool
    var backwardSeekInterval: TimeInterval
    var forwardSeekInterval: TimeInterval
    var onSeek: (TimeInterval) -> Void
    var onPlayPause: () -> Void
    var onRevealControlsWhenHidden: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PlayerTVRemoteSeekView {
        let view = PlayerTVRemoteSeekView()
        view.backgroundColor = .clear
        context.coordinator.sync(view, with: self)
        return view
    }

    func updateUIView(_ uiView: PlayerTVRemoteSeekView, context: Context) {
        context.coordinator.sync(uiView, with: self)
    }

    @MainActor
    final class Coordinator {
        private var parent: PlayerTVRemoteSeekBridge

        init(parent: PlayerTVRemoteSeekBridge) {
            self.parent = parent
        }

        func sync(_ view: PlayerTVRemoteSeekView, with parent: PlayerTVRemoteSeekBridge) {
            self.parent = parent
            view.isRemoteCaptureEnabled = parent.isEnabled &&
                !parent.showsControls &&
                !parent.hasActiveSkipMarker
            view.showsControls = parent.showsControls
            view.hasActiveSkipMarker = parent.hasActiveSkipMarker
            view.backwardSeekInterval = parent.backwardSeekInterval
            view.forwardSeekInterval = parent.forwardSeekInterval
            view.onSeek = parent.onSeek
            view.onPlayPause = parent.onPlayPause
            view.onRevealControlsWhenHidden = parent.onRevealControlsWhenHidden
            view.refreshFirstResponderStatus()
        }
    }
}

private final class PlayerTVRemoteSeekView: UIView {
    var isRemoteCaptureEnabled = false {
        didSet {
            refreshFirstResponderStatus()
        }
    }

    var showsControls = true {
        didSet {
            refreshFirstResponderStatus()
        }
    }

    var hasActiveSkipMarker = false {
        didSet {
            refreshFirstResponderStatus()
        }
    }

    var backwardSeekInterval: TimeInterval = 0
    var forwardSeekInterval: TimeInterval = 0
    var onSeek: ((TimeInterval) -> Void)?
    var onPlayPause: (() -> Void)?
    var onRevealControlsWhenHidden: (() -> Void)?

    override var canBecomeFirstResponder: Bool {
        isRemoteCaptureEnabled && window != nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshFirstResponderStatus()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isRemoteCaptureEnabled else {
            super.pressesBegan(presses, with: event)
            return
        }

        if presses.contains(where: { $0.type == .playPause }) {
            onPlayPause?()
            return
        }

        if presses.contains(where: { $0.type == .menu }) {
            onRevealControlsWhenHidden?()
            return
        }

        if presses.contains(where: { $0.type == .leftArrow }) {
            onSeek?(-backwardSeekInterval)
            return
        }

        if presses.contains(where: { $0.type == .rightArrow }) {
            onSeek?(forwardSeekInterval)
            return
        }

        if presses.contains(where: { $0.type == .select }),
           !showsControls,
           !hasActiveSkipMarker {
            onRevealControlsWhenHidden?()
            return
        }

        super.pressesBegan(presses, with: event)
    }

    func refreshFirstResponderStatus() {
        guard window != nil else { return }

        if isRemoteCaptureEnabled {
            guard !isFirstResponder else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRemoteCaptureEnabled, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        } else if isFirstResponder {
            resignFirstResponder()
        }
    }
}
#endif

#if !os(tvOS)
private struct PlayerTapInteractionOverlay: UIViewRepresentable {
    var showsControls: Bool
    var doubleTapSeekEnabled: Bool
    var backwardSeekInterval: TimeInterval
    var forwardSeekInterval: TimeInterval
    var onToggleControls: () -> Void
    var onDoubleTapSeek: (TimeInterval) -> Void
    var onSpeedBoostBegan: () -> Bool
    var onSpeedBoostEnded: () -> Void
    var onPointerMoved: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PlayerTapInteractionView {
        let view = PlayerTapInteractionView()
        view.backgroundColor = .clear
        view.addGestureRecognizer(context.coordinator.tapRecognizer)
        view.addGestureRecognizer(context.coordinator.longPressRecognizer)

        // Hide the mouse pointer along with the on-screen controls, and bring
        // both back the instant the pointer moves. Without this the arrow cursor
        // sits on top of the video while you watch on a Mac (or an iPad with a
        // trackpad/mouse). The pointer interaction supplies the hidden style; the
        // hover recognizer detects movement to reveal the HUD again. Touch-only
        // devices never drive either, so plain iPad playback is unaffected.
        view.addGestureRecognizer(context.coordinator.hoverRecognizer)
        let pointerInteraction = UIPointerInteraction(delegate: context.coordinator)
        view.addInteraction(pointerInteraction)
        context.coordinator.pointerInteraction = pointerInteraction

        context.coordinator.sync(with: self)
        return view
    }

    func updateUIView(_ uiView: PlayerTapInteractionView, context: Context) {
        context.coordinator.sync(with: self)
    }

    @MainActor
    final class Coordinator: NSObject, UIPointerInteractionDelegate {
        private enum TapZone {
            case left
            case right
        }

        private struct PendingTap {
            let timestamp: CFTimeInterval
            let zone: TapZone
            let flashControlsOnDoubleTap: Bool
        }

        private static let doubleTapWindow: CFTimeInterval = 0.35
        private static let postDoubleTapSuppression: CFTimeInterval = 0.6

        var parent: PlayerTapInteractionOverlay
        let tapRecognizer = UITapGestureRecognizer()
        let longPressRecognizer = UILongPressGestureRecognizer()
        let hoverRecognizer = UIHoverGestureRecognizer()
        weak var pointerInteraction: UIPointerInteraction?

        private var pendingTap: PendingTap?
        private var pendingSingleTapWorkItem: DispatchWorkItem?
        private var suppressSingleTapUntil: CFTimeInterval = 0
        private var controlsAreVisible: Bool
        private var lastReportedControlsVisible: Bool?

        init(parent: PlayerTapInteractionOverlay) {
            self.parent = parent
            self.controlsAreVisible = parent.showsControls
            super.init()
            tapRecognizer.numberOfTapsRequired = 1
            tapRecognizer.cancelsTouchesInView = false
            tapRecognizer.addTarget(self, action: #selector(handleTap(_:)))
            longPressRecognizer.minimumPressDuration = 0.5
            longPressRecognizer.allowableMovement = 24
            longPressRecognizer.cancelsTouchesInView = false
            longPressRecognizer.addTarget(self, action: #selector(handleLongPress(_:)))
            tapRecognizer.require(toFail: longPressRecognizer)
            hoverRecognizer.addTarget(self, action: #selector(handleHover(_:)))
        }

        func sync(with parent: PlayerTapInteractionOverlay) {
            self.parent = parent
            controlsAreVisible = parent.showsControls

            if !parent.doubleTapSeekEnabled {
                pendingTap = nil
                pendingSingleTapWorkItem?.cancel()
                pendingSingleTapWorkItem = nil
                suppressSingleTapUntil = 0
            }

            // Re-query the pointer style whenever control visibility flips so the
            // cursor hides with the HUD and reappears with it.
            if lastReportedControlsVisible != parent.showsControls {
                lastReportedControlsVisible = parent.showsControls
                pointerInteraction?.invalidate()
            }
        }

        @objc
        private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                parent.onPointerMoved()
            default:
                break
            }
        }

        @objc
        private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard parent.onSpeedBoostBegan() else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .ended, .cancelled:
                parent.onSpeedBoostEnded()
            default:
                break
            }
        }

        // MARK: - UIPointerInteractionDelegate

        func pointerInteraction(
            _ interaction: UIPointerInteraction,
            styleFor region: UIPointerRegion
        ) -> UIPointerStyle? {
            // While the controls are up the pointer stays visible so it can reach
            // the buttons; once they auto-hide, hide the pointer too.
            parent.showsControls ? nil : UIPointerStyle.hidden()
        }

        @objc
        private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = recognizer.view,
                  view.bounds.width > 0 else {
                return
            }

            let location = recognizer.location(in: view)
            let zone: TapZone = location.x < (view.bounds.width / 2) ? .left : .right
            let now = CACurrentMediaTime()

            if let pendingTap,
               now - pendingTap.timestamp <= Self.doubleTapWindow {
                pendingSingleTapWorkItem?.cancel()
                pendingSingleTapWorkItem = nil
                self.pendingTap = nil

                if parent.doubleTapSeekEnabled, pendingTap.zone == zone {
                    if pendingTap.flashControlsOnDoubleTap {
                        toggleControls()
                    }

                    let offset = zone == .left ? -parent.backwardSeekInterval : parent.forwardSeekInterval
                    parent.onDoubleTapSeek(offset)
                    suppressSingleTapUntil = now + Self.postDoubleTapSuppression
                    return
                }
            }

            if !parent.doubleTapSeekEnabled {
                toggleControls()
                return
            }

            if now < suppressSingleTapUntil {
                scheduleDelayedSingleTap(at: now, zone: zone)
                return
            }

            let flashControlsOnDoubleTap = !controlsAreVisible
            toggleControls()
            registerPendingTap(
                at: now,
                zone: zone,
                flashControlsOnDoubleTap: flashControlsOnDoubleTap,
                workItem: nil
            )
        }

        private func toggleControls() {
            parent.onToggleControls()
            controlsAreVisible.toggle()
        }

        private func scheduleDelayedSingleTap(at now: CFTimeInterval, zone: TapZone) {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.toggleControls()
                self.pendingTap = nil
                self.pendingSingleTapWorkItem = nil
            }

            registerPendingTap(
                at: now,
                zone: zone,
                flashControlsOnDoubleTap: false,
                workItem: workItem
            )

            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.doubleTapWindow,
                execute: workItem
            )
        }

        private func registerPendingTap(
            at now: CFTimeInterval,
            zone: TapZone,
            flashControlsOnDoubleTap: Bool,
            workItem: DispatchWorkItem?
        ) {
            pendingSingleTapWorkItem?.cancel()
            pendingSingleTapWorkItem = workItem
            pendingTap = PendingTap(
                timestamp: now,
                zone: zone,
                flashControlsOnDoubleTap: flashControlsOnDoubleTap
            )

            guard workItem == nil else { return }

            let clearPendingTapWorkItem = DispatchWorkItem { [weak self] in
                self?.pendingTap = nil
                self?.pendingSingleTapWorkItem = nil
            }
            pendingSingleTapWorkItem = clearPendingTapWorkItem

            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.doubleTapWindow,
                execute: clearPendingTapWorkItem
            )
        }
    }
}

private final class PlayerTapInteractionView: UIView {}

private struct PlayerKeyboardShortcutBridge: UIViewRepresentable {
    var isEnabled: Bool
    var onTogglePlayPause: () -> Void

    func makeUIView(context: Context) -> PlayerKeyboardShortcutView {
        let view = PlayerKeyboardShortcutView()
        view.backgroundColor = .clear
        context.coordinator.sync(view, with: self)
        return view
    }

    func updateUIView(_ uiView: PlayerKeyboardShortcutView, context: Context) {
        context.coordinator.sync(uiView, with: self)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator {
        private var parent: PlayerKeyboardShortcutBridge

        init(parent: PlayerKeyboardShortcutBridge) {
            self.parent = parent
        }

        func sync(_ view: PlayerKeyboardShortcutView, with parent: PlayerKeyboardShortcutBridge) {
            self.parent = parent
            view.isShortcutEnabled = parent.isEnabled
            view.onTogglePlayPause = parent.onTogglePlayPause
        }
    }
}

private final class PlayerKeyboardShortcutView: UIView {
    var isShortcutEnabled = false {
        didSet {
            refreshFirstResponderStatus()
        }
    }

    var onTogglePlayPause: (() -> Void)?

    override var canBecomeFirstResponder: Bool {
        isShortcutEnabled && window != nil
    }

    override var keyCommands: [UIKeyCommand]? {
        guard isShortcutEnabled else { return [] }

        let playPauseCommand = UIKeyCommand(
            input: " ",
            modifierFlags: [],
            action: #selector(handlePlayPauseCommand)
        )
        playPauseCommand.wantsPriorityOverSystemBehavior = true
        playPauseCommand.discoverabilityTitle = "Play/Pause"
        return [playPauseCommand]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshFirstResponderStatus()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isShortcutEnabled else {
            super.pressesBegan(presses, with: event)
            return
        }

        if presses.contains(where: { $0.type == .playPause }) {
            onTogglePlayPause?()
            return
        }

        super.pressesBegan(presses, with: event)
    }

    @objc
    private func handlePlayPauseCommand() {
        onTogglePlayPause?()
    }

    private func refreshFirstResponderStatus() {
        guard window != nil else { return }

        if isShortcutEnabled {
            guard !isFirstResponder else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isShortcutEnabled, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        } else if isFirstResponder {
            resignFirstResponder()
        }
    }
}
#endif
