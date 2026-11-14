#if os(macOS)
import AppKit
import SwiftUI

/// The Mac player. The shell mounts it over the main window's content while
/// `PlaybackCoordinator.showPlayer` is true (`if playback.showPlayer {
/// MacPlayerView() }`) and does nothing else: closing it, the teardown that
/// `fullScreenCover(onDismiss:)` runs on iOS (`onPlayerDismissed`), full
/// screen, the cursor and display sleep are all handled here.
///
/// Mirrors `PlayerView`'s phases (pre-roll, session, preparing) and reuses the
/// shared view model, overlays and engines; only the HUD (`MacPlayerHUD`) and
/// the input are Mac-specific. Keyboard: Space, ←/→, ↑/↓, F, M and Esc, both
/// through the Playback menu (`MacPlayerCommands`) and, as a fallback when the
/// menu is not routed, `onKeyPress` on the player itself.
struct MacPlayerView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback

    @State private var commandTarget = MacPlayerCommandTarget()
    @State private var displaySleepActivity: NSObjectProtocol?
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Group {
                if playback.prerollPlayback != nil,
                   let engine = playback.engine,
                   let playbackSource = playback.playbackSource {
                    PlayerPrerollView(
                        engine: engine,
                        playbackSource: playbackSource,
                        presentationID: playback.playerPresentationID
                    )
                    .id(playback.playerPresentationID)
                    .onAppear { commandTarget.prerollEngine = engine }
                } else if let engine = playback.engine,
                          let playbackSource = playback.playbackSource {
                    MacPlayerSessionView(
                        engine: engine,
                        playbackSource: playbackSource,
                        presentationID: playback.playerPresentationID,
                        mediaDetails: playback.activeItemDetails,
                        debugInfo: playback.debugInfo,
                        commandTarget: commandTarget,
                        onDismiss: closePlayer
                    )
                    .id(playback.playerPresentationID)
                } else if playback.showPlayer {
                    PlayerLoadingView(
                        placeholder: playback.loadingPlaceholder,
                        onCancel: { playback.dismissFailedPlayback() }
                    )
                } else {
                    Color.black
                }
            }

            // Lives above the replaceable session identity, like `PlayerView`'s,
            // so an engine handoff never restarts its animation.
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .offset(y: loadingIndicatorVerticalOffset)
                .opacity(playback.playerLoadingState.isVisible ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(!playback.playerLoadingState.isVisible)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .environment(playback.preferences)
        .background {
            MacPlayerWindowReader { window in
                commandTarget.attach(to: window)
            }
        }
        .overlay {
            // Pre-playback load failures (no engine yet; see `PlayerView`), as
            // the same card the session shows, over the loading screen.
            if let message = loadErrorMessage {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                    MacPlayerErrorCard(
                        title: playback.loadingPlaceholder?.title,
                        reason: MacPlayerErrorCard.reason(forMessage: message),
                        detail: MacPlayerErrorCard.detail(forMessage: message),
                        primary: AuthenticationFailure.requiresReauthentication(message: message)
                            ? MacPlayerErrorCard.Action(title: "Sign In") {
                                AuthenticationFailure.beginReauthentication(
                                    plexService: plexService,
                                    playback: playback
                                )
                            }
                            : nil,
                        onClose: { playback.dismissFailedPlayback() }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    MacPlayerTopBar(
                        title: playback.loadingPlaceholder?.title,
                        subtitle: playback.loadingPlaceholder?.subtitle,
                        onBack: { playback.dismissFailedPlayback() }
                    )
                }
                .environment(commandTarget)
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handleKeyPress)
        .focusedSceneValue(commandTarget)
        .onChange(of: commandTarget.isKeyboardEnabled) { _, isEnabled in
            // A sheet took the keyboard; take it back once it closes.
            if isEnabled { isFocused = true }
        }
        .onChange(of: playback.prerollPlayback == nil) { _, hasNoPreroll in
            if hasNoPreroll { commandTarget.prerollEngine = nil }
        }
        .onChange(of: playback.isIdleTimerSuppressed, initial: true) { _, isSuppressed in
            updateDisplaySleep(preventsSleep: isSuppressed)
        }
        .onAppear {
            commandTarget.playback = playback
            commandTarget.preferences = playback.preferences
            commandTarget.onClose = closePlayer
            isFocused = true
        }
        .onDisappear {
            updateDisplaySleep(preventsSleep: false)
            NSCursor.setHiddenUntilMouseMoves(false)
            commandTarget.restoreWindow()
            // The iOS cover runs this from `fullScreenCover(onDismiss:)`. It
            // keeps the session alive while Picture in Picture took over.
            playback.onPlayerDismissed()
        }
    }

    /// Only pre-playback load failures (no engine yet); see `PlayerView`.
    private var loadErrorMessage: String? {
        guard playback.engine == nil else { return nil }
        return playback.loadError
    }

    private var loadingIndicatorVerticalOffset: CGFloat {
        guard playback.playerLoadingState == .preparing,
              playback.loadingPlaceholder != nil else {
            return 0
        }
        return 150
    }

    private func closePlayer() {
        if playback.engine == nil {
            playback.dismissFailedPlayback()
        } else {
            playback.showPlayer = false
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return .ignored }

        switch press.key {
        case .escape:
            commandTarget.escape()
        case .space:
            guard commandTarget.acceptsCommands else { return .ignored }
            commandTarget.togglePlayPause()
        case .leftArrow:
            guard commandTarget.canSeek else { return .ignored }
            commandTarget.skip(.backward)
        case .rightArrow:
            guard commandTarget.canSeek else { return .ignored }
            commandTarget.skip(.forward)
        case .upArrow:
            guard commandTarget.acceptsCommands else { return .ignored }
            commandTarget.volume.step(by: MacPlayerVolume.keyboardStep)
        case .downArrow:
            guard commandTarget.acceptsCommands else { return .ignored }
            commandTarget.volume.step(by: -MacPlayerVolume.keyboardStep)
        case "f":
            commandTarget.toggleFullScreen()
        case "m":
            guard commandTarget.acceptsCommands else { return .ignored }
            commandTarget.volume.toggleMute()
        default:
            return .ignored
        }
        return .handled
    }

    /// The Mac's idle timer: an activity that keeps the display awake for as
    /// long as the coordinator says playback should (it drops on pause).
    private func updateDisplaySleep(preventsSleep: Bool) {
        if preventsSleep {
            guard displaySleepActivity == nil else { return }
            displaySleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Video playback"
            )
        } else if let activity = displaySleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            displaySleepActivity = nil
        }
    }
}

/// One playback session: the engine's picture, the shared overlays and the
/// Mac HUD. Wires the view model to the coordinator exactly like the iOS/tvOS
/// `PlayerSessionView` does; keep the two in step when either changes.
private struct MacPlayerSessionView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(UserPreferences.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var viewModel: PlayerViewModel
    @State private var scrubPreviewSource: PlexScrubPreviewSource?
    @State private var playerContainerSize: CGSize = .zero
    @State private var upNextPosterCoveredHeight: CGFloat?
    @State private var isPointerInside = false
    @State private var lastPointerLocation: CGPoint?

    private let playbackSource: PlaybackSource
    private let presentationID: UUID
    private let mediaDetails: PlexMediaDetails?
    private let debugInfo: PlaybackDebugInfo?
    private let commandTarget: MacPlayerCommandTarget
    private let onDismiss: () -> Void
    private let volume = MacPlayerVolume.shared

    init(
        engine: any PlaybackEngine,
        playbackSource: PlaybackSource,
        presentationID: UUID,
        mediaDetails: PlexMediaDetails?,
        debugInfo: PlaybackDebugInfo?,
        commandTarget: MacPlayerCommandTarget,
        onDismiss: @escaping () -> Void
    ) {
        let model = PlayerViewModel(
            engine: engine,
            markers: mediaDetails?.markers ?? [],
            liveTVContext: playbackSource.liveTVContext
        )
        model.iptvCatchUp = playbackSource.iptvCatchUp
        _viewModel = State(initialValue: model)
        self.playbackSource = playbackSource
        self.presentationID = presentationID
        self.mediaDetails = mediaDetails
        self.debugInfo = debugInfo
        self.commandTarget = commandTarget
        self.onDismiss = onDismiss
    }

    /// See `PlayerSessionView.subtitleClearance`.
    private var subtitleClearance: SubtitleClearance? {
        guard playback.upNextPoster != nil,
              playback.upNextPresentation == nil,
              viewModel.playbackError == nil,
              !playback.isPictureInPictureActive,
              let upNextPosterCoveredHeight else { return nil }
        return SubtitleClearance(
            containerSize: playerContainerSize,
            coveredHeight: upNextPosterCoveredHeight,
            spacing: PlayerOverlayLayout.subtitleClearanceSpacing,
            displayScale: displayScale
        )
    }

    var body: some View {
        @Bindable var vm = viewModel

        ZStack {
            Color.black

            viewModel.engineView

            if let upNextPresentation = playback.upNextPresentation {
                PlayerUpNextOverlayView(
                    presentation: upNextPresentation,
                    plexService: plexService,
                    onPlayNow: { playback.playUpNextNow() },
                    onDismiss: dismissPlayer
                )
                .transition(.opacity)
            } else {
                clickLayer

                if let seekFeedback = viewModel.seekFeedback {
                    MacPlayerSeekFeedbackView(presentation: seekFeedback)
                        .transition(.opacity)
                }

                if let error = viewModel.playbackError, hasVisiblePlaybackError {
                    errorOverlay(error)
                }

                if let qualitySwitchError = playback.qualitySwitchError {
                    playerToast(qualitySwitchError)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let marker = viewModel.activeSkipMarker, viewModel.playbackError == nil {
                    skipMarkerOverlay(marker)
                        .transition(PlayerOverlayLayout.bottomTrailingTransition)
                }

                if let poster = playback.upNextPoster, viewModel.playbackError == nil {
                    PlayerUpNextPosterView(
                        presentation: poster,
                        plexService: plexService,
                        controlsVisible: viewModel.showControls,
                        onPlayNow: { playback.playUpNextPosterNow() },
                        onDismiss: { playback.dismissUpNextPoster(userInitiated: true) },
                        onCoveredHeightChange: { upNextPosterCoveredHeight = $0 }
                    )
                    .transition(PlayerOverlayLayout.bottomTrailingTransition)
                }

                if !hasVisiblePlaybackError {
                    controlsOverlay
                }
            }
        }
        .background {
            Color.clear
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { playerContainerSize = $0 }
        }
        // Any pointer movement over the player brings the HUD back, the way
        // every Mac video player behaves; the HUD then fades on its own timer.
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                isPointerInside = true
                // Only real movement counts: the HUD fading in or out changes
                // what is under a resting pointer, which must not re-reveal it.
                guard location != lastPointerLocation else { return }
                lastPointerLocation = location
                viewModel.touchControls()
            case .ended:
                isPointerInside = false
                lastPointerLocation = nil
            }
        }
        .onChange(of: viewModel.showControls) { _, isShowing in
            // Hide the pointer with the HUD; AppKit shows it again on the
            // next move, which also brings the HUD back.
            if !isShowing, isPointerInside, !hasVisiblePlaybackError {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        // The window's traffic lights fade with the HUD; an error keeps them.
        .onChange(of: viewModel.showControls || hasVisiblePlaybackError, initial: true) { _, isVisible in
            commandTarget.setWindowControlsVisible(isVisible)
        }
        .onChange(of: subtitleClearance, initial: true) { _, clearance in
            viewModel.engine.setSubtitleClearance(clearance)
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeSkipMarker?.id)
        .animation(.easeInOut(duration: 0.25), value: playback.upNextPoster?.creditsMarkerID)
        .animation(.easeOut(duration: 0.14), value: viewModel.seekFeedback?.trigger)
        .animation(.easeInOut(duration: 0.25), value: playback.upNextPresentation?.item.id)
        .animation(.easeInOut(duration: 0.2), value: playback.qualitySwitchError)
        .onAppear(perform: configureSession)
        .onDisappear(perform: tearDownSession)
        .onChange(of: scenePhase) { _, newPhase in
            playback.flushTimelineForScenePhase(newPhase)
        }
        .onChange(of: playback.activeLiveTVContext) { _, context in
            guard let context, context.sessionID == viewModel.liveTVContext?.sessionID else { return }
            viewModel.liveTVContext = context
        }
        .onChange(of: playback.externalSubtitleRefreshToken) { _, _ in
            viewModel.reloadExternalSubtitleStreams(
                part: playback.debugInfo?.part ?? viewModel.sourcePart,
                selecting: playback.consumePendingExternalSubtitleStreamID()
            )
        }
        .task(id: scrubPreviewPartID) {
            await loadScrubPreviewSource(partID: scrubPreviewPartID)
        }
        // A manual audio offset moved the item to VLCKit and rebuilt this
        // view, closing the offset sheet the viewer was adjusting.
        .onChange(of: viewModel.audioTracks.isEmpty, initial: true) { _, isEmpty in
            guard !isEmpty, playback.consumeAudioOptionsReopen() else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                viewModel.showAudioPicker = true
            }
        }
        // libvlc only keeps a volume once its audio output exists, so the
        // level is re-applied as the engine moves through its states.
        .onChange(of: viewModel.state, initial: true) { _, _ in
            volume.apply(to: viewModel.engine)
        }
        .onChange(of: volume.level) { _, _ in volume.apply(to: viewModel.engine) }
        .onChange(of: volume.isMuted) { _, _ in volume.apply(to: viewModel.engine) }
        .onChange(of: isKeyboardEnabled, initial: true) { _, isEnabled in
            commandTarget.isKeyboardEnabled = isEnabled
        }
        .sheet(isPresented: $vm.showSubtitleSearch) {
            subtitleSearchView
                .frame(minWidth: 480, idealWidth: 540, minHeight: 460, idealHeight: 560)
        }
        .sheet(isPresented: $vm.showPlaybackInfo) {
            Group {
                if let debugInfo {
                    PlayerPlaybackInfoView(
                        debugInfo: debugInfo,
                        state: viewModel.state,
                        isBuffering: viewModel.isBuffering,
                        selectedAudioTrack: viewModel.selectedAudioTrack,
                        engineDiagnostics: viewModel.engine.playbackDiagnostics,
                        engine: viewModel.engine,
                        videoEnhancementStatus: viewModel.videoEnhancementStatus
                    )
                } else {
                    PlayerPlaybackInfoUnavailableView()
                }
            }
            .frame(minWidth: 480, idealWidth: 560, minHeight: 480, idealHeight: 640)
        }
        .sheet(isPresented: $vm.showAudioPicker) {
            MacPlayerAudioOffsetSheet(onDone: { viewModel.showAudioPicker = false })
        }
    }

    // MARK: - Layers

    /// Click toggles play/pause, double-click toggles full screen. The single
    /// click waits out the double-click interval so a double-click never
    /// pauses and resumes on its way to full screen.
    private var clickLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .onEnded { commandTarget.toggleFullScreen() }
                    .exclusively(before: TapGesture(count: 1).onEnded {
                        guard viewModel.playbackError == nil else { return }
                        viewModel.togglePlayPause()
                    })
            )
            .accessibilityHidden(true)
    }

    /// Faded, never removed, for the reason `PlayerSessionView.controlsOverlay`
    /// documents: the 4 Hz sync re-renders would finalize a removal mid-fade.
    private var controlsOverlay: some View {
        PlayerControlsOverlay(
            viewModel: viewModel,
            mediaDetails: mediaDetails,
            debugInfo: debugInfo,
            scrubPreviewSource: scrubPreviewSource,
            controlsTopSafeAreaInset: 0,
            onDismiss: dismissPlayer
        )
        .environment(commandTarget)
        .opacity(viewModel.showControls ? 1 : 0)
        .allowsHitTesting(viewModel.showControls)
        .accessibilityHidden(!viewModel.showControls)
        .animation(PlayerViewModel.controlsVisibilityAnimation, value: viewModel.showControls)
    }

    @ViewBuilder
    private var subtitleSearchView: some View {
        if let ratingKey = playback.ratingKey {
            SubtitleSearchView(
                plexService: plexService,
                ratingKey: ratingKey,
                serverID: playback.activePlaybackServerID,
                preferredLanguageCode: preferences.defaultSubtitleLanguage,
                onWillDownload: { result in
                    await playback.prepareSubtitleDownload(result)
                },
                onDownloaded: { result in
                    await playback.refreshSubtitleStreamsAfterDownload(downloaded: result)
                },
                onDismiss: {
                    viewModel.showSubtitleSearch = false
                }
            )
        } else {
            EmptyView()
        }
    }

    private func skipMarkerOverlay(_ marker: PlexMarker) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                MacPlayerSkipChip(
                    title: marker.skipButtonTitle ?? "Skip",
                    systemImage: marker.isCredits ? "forward.end.fill" : "chevron.forward.2",
                    countdownProgress: viewModel.autoSkipCountdownProgress,
                    action: { viewModel.handleSkipMarker(marker) }
                )
            }
        }
        .id(marker.id)
        .padding(.horizontal, PlayerOverlayLayout.bottomTrailingHorizontalPadding)
        .padding(.bottom, PlayerOverlayLayout.skipMarkerBottomInset(controlsVisible: viewModel.showControls))
        .animation(PlayerOverlayLayout.skipMarkerRepositionAnimation, value: viewModel.showControls)
    }

    private func playerToast(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 52)

            Spacer()
        }
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
    }

    /// A playback failure keeps the top row (Back, title, traffic lights) and
    /// says what went wrong in a compact card: Try Again replays the item from
    /// where it stopped, Close (Esc) leaves the player.
    private func errorOverlay(_ error: PlaybackError) -> some View {
        let placeholder = playback.activeItemDetails.map { PlaybackPlaceholder(details: $0) }

        return ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            MacPlayerErrorCard(
                // An episode by its own title ("Pilot"), not the show's.
                title: playback.activeItemDetails?.title ?? placeholder?.title,
                reason: MacPlayerErrorCard.reason(for: error),
                detail: MacPlayerErrorCard.detail(for: error),
                primary: errorPrimaryAction(error),
                onClose: dismissPlayer
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MacPlayerTopBar(
                title: placeholder?.title,
                subtitle: placeholder?.subtitle,
                onBack: dismissPlayer
            )
            .environment(commandTarget)
        }
    }

    private func errorPrimaryAction(_ error: PlaybackError) -> MacPlayerErrorCard.Action? {
        if error.requiresReauthentication {
            return MacPlayerErrorCard.Action(title: "Sign In") {
                viewModel.cleanup()
                AuthenticationFailure.beginReauthentication(
                    plexService: plexService,
                    playback: playback
                )
            }
        }
        if playback.isPlayingIPTV {
            return MacPlayerErrorCard.Action(title: "Try Again") {
                Task { await playback.retryActiveIPTVChannel() }
            }
        }
        guard let id = playback.activeItemID, viewModel.liveTVContext == nil else { return nil }
        let position = viewModel.displayPosition
        let placeholder = playback.activeItemDetails.map { PlaybackPlaceholder(details: $0) }
        return MacPlayerErrorCard.Action(title: "Try Again") {
            Task {
                await playback.play(
                    id: id,
                    resumeOffsetMilliseconds: position > 1 ? Int(position * 1000) : nil,
                    placeholder: placeholder
                )
            }
        }
    }

    // MARK: - State

    private var isKeyboardEnabled: Bool {
        !viewModel.showSubtitleSearch &&
            !viewModel.showPlaybackInfo &&
            !viewModel.showAudioPicker
    }

    /// See `PlayerSessionView.hasVisiblePlaybackError`.
    private var hasVisiblePlaybackError: Bool {
        viewModel.playbackError != nil &&
            !playback.isAutomaticDirectPlayFallbackPending
    }

    private var scrubPreviewPartID: Int? {
        guard let debugInfo, debugInfo.canLoadScrubPreviews else { return nil }
        return debugInfo.part.id
    }

    private func dismissPlayer() {
        viewModel.cleanup()
        onDismiss()
    }

    @MainActor
    private func loadScrubPreviewSource(partID: Int?) async {
        scrubPreviewSource = nil
        guard let partID else { return }

        let source = await plexService.scrubPreviewSource(
            forPartID: partID,
            serverID: playback.activePlaybackServerID
        )
        guard !Task.isCancelled else { return }
        scrubPreviewSource = source
    }

    // MARK: - Session wiring (mirrors `PlayerSessionView`)

    private func configureSession() {
        commandTarget.viewModel = viewModel
        commandTarget.prerollEngine = nil
        volume.apply(to: viewModel.engine)
        // A Mac window has no orientation; keep the zoom-to-fill choice in
        // the landscape slot, which is what a desktop picture is.
        viewModel.updateVideoOrientation(isLandscape: true)

        playback.notePlayerUIDidAppear()
        viewModel.externalSubtitleURLProvider = { stream in
            playback.externalSubtitleURL(for: stream)
        }
        viewModel.externalSubtitleRestartHandler = { streamID in
            playback.switchToVLCKitForExternalSubtitle(streamID: streamID)
        }
        viewModel.userTrackSelectionHandler = { type, streamID in
            guard playback.playerPresentationID == presentationID else { return }
            playback.rememberShowTrackChoice(type: type, streamID: streamID)
        }
        viewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: debugInfo?.part ?? mediaDetails?.media.first?.parts.first,
            mediaDetails: mediaDetails,
            usesServerTrackSelection: playback.usesServerTrackSelection,
            rendersServerSubtitleTrack: playback.isSpatialAudioSession,
            selectedAudioStreamID: playback.activeAudioStreamID,
            selectedSubtitleStreamID: playback.activeSubtitleStreamID,
            pendingExternalSubtitleStreamID: playback.consumePendingExternalSubtitleStreamID(),
            explicitTrackSelection: playback.consumePendingExplicitTrackSelection() ?? playback.rememberedShowTrackSelection(),
            spentAutoSkipMarkerIDs: playback.spentAutoSkipMarkerIDs
        )
        viewModel.autoSkipHandler = { marker in
            viewModel.handleSkipMarker(marker)
        }
        viewModel.autoSkipSpentHandler = { markerID in
            playback.noteAutoSkipSpent(markerID: markerID)
        }
        viewModel.upNextPosterHandler = { creditsMarker in
            handleReachedCreditsMarker(creditsMarker)
        }
        viewModel.skipToEndHandler = {
            Task { await playback.handlePlaybackEnded() }
        }
        viewModel.playbackSnapshotHandler = { state, _, _ in
            guard playback.playerPresentationID == presentationID else { return }
            playback.nowPlayingController.updatePlaybackState(
                state: viewModel.engine.state,
                currentTime: viewModel.engine.currentTime,
                duration: viewModel.engine.duration
            )
            playback.noteActivePlaybackState(state)
        }
        viewModel.bufferingPresentationHandler = { isVisible in
            playback.setBufferingPresentationVisible(isVisible, for: presentationID)
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
    }

    private func tearDownSession() {
        commandTarget.setWindowControlsVisible(true)
        if commandTarget.viewModel === viewModel {
            commandTarget.viewModel = nil
        }
        viewModel.playbackSnapshotHandler = nil
        viewModel.upNextPosterHandler = nil
        viewModel.skipToEndHandler = nil
        viewModel.userTrackSelectionHandler = nil
        viewModel.plexTrackSelectionHandler = nil
        viewModel.externalSubtitleRestartHandler = nil
        viewModel.cleanup()
        viewModel.bufferingPresentationHandler = nil
    }

    /// See `PlayerSessionView.handleReachedCreditsMarker`.
    @MainActor
    private func handleReachedCreditsMarker(_ marker: PlexMarker?) {
        guard let marker else {
            playback.dismissUpNextPoster()
            return
        }

        let presentationID = playback.playerPresentationID
        let ratingKey = playback.ratingKey
        Task {
            let nothingFollows = await playback.presentUpNextPosterIfPossible(
                creditsMarkerID: marker.id,
                isEstimated: marker.isEstimated,
                presentationID: presentationID,
                ratingKey: ratingKey
            )
            if nothingFollows, viewModel.reachedCreditsMarker?.id == marker.id {
                viewModel.creditsMarkerWithoutUpNextID = marker.id
            }
        }
    }
}
#endif
