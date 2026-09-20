import SwiftUI
import UIKit

enum PlayerOverlayLayout {
    static let controlsHorizontalPadding: CGFloat = 16
    // Bottom-trailing overlays (Skip Intro button, Up Next poster) have two
    // resting heights: low near the screen edge while the HUD is hidden, and
    // raised above the play bar while the controls are up. Keep the raised
    // inset in sync with the controls' bottom bar height.
    #if os(tvOS)
    // Clears the whole bottom HUD: bottom inset + the bar row and its
    // readouts + the title block's spacing + the action row.
    static let skipMarkerRaisedBottomInset: CGFloat = 200
    static let skipMarkerRestingBottomInset: CGFloat = 60
    #else
    static let skipMarkerRaisedBottomInset: CGFloat = 108
    static let skipMarkerRestingBottomInset: CGFloat = 48
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
    @Environment(PlexService.self) private var plexService
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
        ) { message in
            if AuthenticationFailure.requiresReauthentication(message: message) {
                Button("Sign In") {
                    AuthenticationFailure.beginReauthentication(
                        plexService: plexService,
                        playback: playback
                    )
                }
            } else {
                Button("OK", role: .cancel) { playback.dismissFailedPlayback() }
            }
        } message: { message in
            Text(message)
        }
        // Attached here, not in `PlayerSessionView`, so a single idle-timer
        // modifier survives across episode transitions (the session view is
        // rebuilt with a fresh `.id` each time). See
        // `PlaybackCoordinator.isIdleTimerSuppressed`.
        .playerIdleTimerDisabled(playback.isIdleTimerSuppressed)
        .playerSharePlayPresentation(isPlayer: true)
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
///
/// Two layout rules hold this screen together:
///
/// * The blurred backdrop is clamped to the proposed size and clipped. A
///   fill-scaled image reports the *scaled* size, not the proposal, so an
///   unclamped one grows every ancestor — including `PlayerSessionView`'s
///   stack, which the HUD then fills — until the top bar and the play bar are
///   pushed off the screen edges. That is a whole-HUD break, not a cosmetic
///   one: it took the play bar out of portrait entirely and clipped the top
///   bar in landscape. `PlayerUpNextOverlayView` clamps its own wash the same
///   way; keep any full-bleed artwork here in that shape.
/// * The content deliberately leaves the middle of the safe area empty,
///   because that is where the HUD keeps its 72pt play/pause button. The
///   artwork takes the half above it and the route status the half below, both
///   halves equally flexible, so the split stays on the safe area's center in
///   every orientation, at every HUD state, and without measuring the HUD.
private struct PlayerAirPlayRemoteBackground: View {
    @Environment(PlexService.self) private var plexService

    let details: PlexMediaDetails?
    let routeName: String?

    /// Vertical space kept clear for the HUD's centered play/pause button. The
    /// button is 72pt, and it does not sit exactly on the safe area's center:
    /// the HUD's equal spacers push it up or down by up to ~15pt depending on
    /// how tall the media header above it grows. The extra margin absorbs that
    /// drift so neither half can ever meet the button.
    private static let centerControlReserve: CGFloat = 132
    private static let maximumArtworkWidth: CGFloat = 150
    private static let minimumArtworkWidth: CGFloat = 84
    /// Below this the half above the transport cannot hold artwork, and the
    /// half below it only has room for the route pill (iPhone landscape).
    private static let compactHeightThreshold: CGFloat = 480

    var body: some View {
        ZStack {
            backdrop
            content
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            if let backdropURL {
                DuskAsyncImage(url: backdropURL) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            // `opaque: true` samples the artwork's own edges, so
                            // the wash reaches the screen edges instead of fading
                            // to transparent corners.
                            .blur(radius: 60, opaque: true)
                            .opacity(0.34)
                            .transition(.opacity)
                    } else {
                        Color.clear
                    }
                }
            }

            LinearGradient(
                colors: [.black.opacity(0.42), .black.opacity(0.86)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
        .ignoresSafeArea()
    }

    // MARK: - Content

    private var content: some View {
        GeometryReader { geometry in
            let halfHeight = max((geometry.size.height - Self.centerControlReserve) / 2, 0)
            let isCompact = geometry.size.height < Self.compactHeightThreshold

            VStack(spacing: 0) {
                artwork(availableHeight: halfHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, Self.centerControlReserve / 2)

                routeStatus(isCompact: isCompact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, Self.centerControlReserve / 2)
            }
            .padding(.horizontal, 24)
        }
    }

    /// The item's poster, sized to the space above the transport button so it
    /// never has to be clipped, or an AirPlay tile when the session has no
    /// artwork to lead with (Live TV, or playback started without metadata).
    @ViewBuilder
    private func artwork(availableHeight: CGFloat) -> some View {
        if let width = artworkWidth(availableHeight: availableHeight) {
            Group {
                if let posterPath = placeholder?.posterPath {
                    PosterArtwork(
                        imageURL: plexService.imageURL(
                            for: posterPath,
                            serverID: placeholder?.serverID,
                            width: Int(width),
                            height: Int(width * 1.5)
                        ),
                        width: width
                    )
                } else {
                    airPlayTile(width: width)
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        }
    }

    private func airPlayTile(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)
            .fill(.white.opacity(0.08))
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)
            )
            .overlay {
                Image(systemName: "airplayvideo")
                    .font(.system(size: width * 0.34, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .overlay {
                RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
            .frame(width: width, height: width)
    }

    private func routeStatus(isCompact: Bool) -> some View {
        VStack(spacing: 12) {
            routePill

            if !isCompact, let placeholder {
                VStack(spacing: 2) {
                    Text(placeholder.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)

                    if let subtitle = placeholder.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
            }
        }
    }

    private var routePill: some View {
        HStack(spacing: 8) {
            Image(systemName: "airplayvideo")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.duskAccent)

            Text(routeLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.white.opacity(0.07))
                .background(.ultraThinMaterial, in: Capsule())
        }
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
    }

    // MARK: - Derived state

    /// `nil` when the space above the transport button cannot hold artwork at a
    /// size worth showing, which keeps a short landscape layout to the pill.
    private func artworkWidth(availableHeight: CGFloat) -> CGFloat? {
        let artworkHeight = availableHeight - 12
        guard artworkHeight >= Self.minimumArtworkWidth * 1.5 else { return nil }

        return min(Self.maximumArtworkWidth, artworkHeight * (2.0 / 3.0)).rounded()
    }

    private var placeholder: PlaybackPlaceholder? {
        details.map(PlaybackPlaceholder.init(details:))
    }

    private var backdropURL: URL? {
        plexService.imageURL(
            for: placeholder?.backdropPath,
            serverID: placeholder?.serverID,
            width: 1280,
            height: 720
        )
    }

    private var routeLabel: String {
        routeName.map { "Playing on \($0)" } ?? "Playing with AirPlay"
    }

    private var accessibilityLabel: String {
        [routeLabel, placeholder?.title]
            .compactMap { $0 }
            .joined(separator: ". ")
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
    /// Owns the tvOS HUD state machine for the whole session. Lives here, not
    /// in the overlay, because the remote bridge drives it while the HUD is
    /// hidden as well.
    @State private var hudController = PlayerTVHUDController()
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
            // The player's only remote-input owner. It resigns capture the
            // moment something else needs the focus engine — the settings
            // panel, the subtitle search cover, the playback info cover, the
            // full Up Next overlay or a surfaced playback error — and forwards
            // anything it does not understand up the responder chain.
            PlayerTVRemoteInputBridge(
                isCaptureEnabled: isTVRemoteCaptureEnabled,
                onInput: { hudController.handle($0) }
            )
            .allowsHitTesting(isTVRemoteCaptureEnabled)
            .ignoresSafeArea()
            #endif

            #if !os(tvOS)
            PlayerKeyboardShortcutBridge(
                isEnabled: playback.upNextPresentation == nil &&
                    !viewModel.showSubtitlePicker &&
                    !viewModel.showSubtitleSizePicker &&
                    !viewModel.showSubtitleSearch &&
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
                #if !os(tvOS)
                interactionOverlay
                #endif

                #if os(tvOS)
                if let badge = hudController.transientBadge,
                   hudController.mode == .hidden {
                    PlayerTVTransientBadgeOverlay(badge: badge)
                        .transition(.opacity)
                }
                #endif

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
                        isSelected: isTVBottomTrailingControlSelected,
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
        // No `onExitCommand` / `onPlayPauseCommand` on tvOS: the remote bridge
        // is the single owner of those presses, and a SwiftUI command modifier
        // here would double-fire against it.
        .onAppear {
            // If we are re-presenting after the user tapped restore on the PiP
            // window, let the system finish animating the video back into place.
            playback.notePlayerUIDidAppear()
            // Set before configuring: the first track sync already needs to be
            // able to resolve and mount the part's Plex sidecar subtitles.
            viewModel.externalSubtitleURLProvider = { stream in
                playback.plexService.externalSubtitleURL(
                    for: stream,
                    serverID: playback.activePlaybackServerID
                )
            }
            viewModel.externalSubtitleRestartHandler = { streamID in
                playback.switchToVLCKitForExternalSubtitle(streamID: streamID)
            }
            viewModel.configureAutomaticTrackSelection(
                preferences: preferences,
                part: debugInfo?.part ?? mediaDetails?.media.first?.parts.first,
                mediaDetails: mediaDetails,
                usesServerTrackSelection: playback.isAirPlaySession,
                selectedAudioStreamID: playback.activeAudioStreamID,
                selectedSubtitleStreamID: playback.activeSubtitleStreamID,
                pendingExternalSubtitleStreamID: playback.consumePendingExternalSubtitleStreamID(),
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
            configureTVHUDController()
            #endif
        }
        .onDisappear {
            viewModel.playbackSnapshotHandler = nil
            viewModel.upNextPosterHandler = nil
            viewModel.plexTrackSelectionHandler = nil
            viewModel.externalSubtitleRestartHandler = nil
            viewModel.cleanup()
            viewModel.bufferingPresentationHandler = nil
            #if os(tvOS)
            hudController.cleanup()
            #endif
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
        // A sidecar subtitle installed mid-session replaces the coordinator's
        // part snapshot; re-read it in place so the new stream is mounted and
        // selected without rebuilding the session.
        .onChange(of: playback.externalSubtitleRefreshToken) { _, _ in
            viewModel.reloadExternalSubtitleStreams(
                part: playback.debugInfo?.part ?? viewModel.sourcePart,
                selecting: playback.consumePendingExternalSubtitleStreamID()
            )
        }
        .task(id: scrubPreviewPartID) {
            await loadScrubPreviewSource(partID: scrubPreviewPartID)
        }
        #if os(tvOS)
        // The HUD controller and `showControls` mirror each other: the
        // controller writes the flag when the viewer drives it, and reads it
        // back here when playback code reveals the HUD on its own (an
        // auto-skip, a marker jump).
        .onChange(of: viewModel.showControls) { _, isShowing in
            hudController.syncControlsVisibility(isShowing)
        }
        .onChange(of: hasBottomTrailingFocusControl, initial: true) { _, isVisible in
            hudController.isBottomTrailingControlVisible = isVisible
        }
        .onChange(of: preferences.playerDoubleTapBackwardInterval, initial: true) { _, interval in
            hudController.backwardSeekInterval = interval.timeInterval
        }
        .onChange(of: preferences.playerDoubleTapForwardInterval, initial: true) { _, interval in
            hudController.forwardSeekInterval = interval.timeInterval
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
                itemSubtitle: \.pickerDetailTitle,
                onSelect: { item in
                    viewModel.selectSubtitle(item)
                },
                onDismiss: {
                    viewModel.showSubtitlePicker = false
                }
            )
        }
        .sheet(isPresented: $vm.showSubtitleSizePicker) {
            PlayerSelectionSheet(
                title: "Subtitle Size",
                items: SubtitleFontSize.allCases,
                selectedID: viewModel.subtitleFontSize.id,
                itemTitle: \.displayName,
                itemSubtitle: \.detailTitle,
                onSelect: { item in
                    guard let item else { return }
                    viewModel.selectSubtitleFontSize(item)
                },
                onDismiss: {
                    viewModel.showSubtitleSizePicker = false
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
        .sheet(isPresented: $vm.showSubtitleSearch) {
            subtitleSearchView
        }
        #endif
        #if os(tvOS)
        .fullScreenCover(isPresented: $vm.showSubtitleSearch) {
            subtitleSearchView
        }
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

    /// Plex's OpenSubtitles search for the item that is playing. On success the
    /// coordinator refetches the item and mounts (or burns in) the new sidecar
    /// without leaving the session.
    @ViewBuilder
    private var subtitleSearchView: some View {
        if let ratingKey = playback.ratingKey {
            SubtitleSearchView(
                plexService: plexService,
                ratingKey: ratingKey,
                serverID: playback.activePlaybackServerID,
                preferredLanguageCode: preferences.defaultSubtitleLanguage,
                onDownloaded: { _ in
                    await playback.refreshSubtitleStreamsAfterDownload()
                },
                onDismiss: {
                    viewModel.showSubtitleSearch = false
                }
            )
        } else {
            EmptyView()
        }
    }

    private func playerToast(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(DuskFont.buttonLabel(ios: .subheadline.weight(.semibold)))
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
    /// tvOS now stays mounted too. Nothing in the transport is focusable any
    /// more (the action row draws its own selection from the HUD controller),
    /// and the settings panel — the one part that does take focus — is only
    /// built while it is open. Staying mounted also means the controller's
    /// action list and panel tabs are known while the HUD is hidden, which is
    /// what lets a Down press open the panel straight from the video.
    @ViewBuilder
    private var controlsOverlay: some View {
        playerControls
            .opacity(viewModel.showControls ? 1 : 0)
            .allowsHitTesting(viewModel.showControls)
            // `allowsHitTesting(false)` does not take the hidden HUD out of the
            // accessibility tree on its own.
            .accessibilityHidden(!viewModel.showControls)
            .animation(PlayerViewModel.controlsVisibilityAnimation, value: viewModel.showControls)
    }

    private var playerControls: some View {
        #if os(tvOS)
        PlayerControlsOverlay(
            viewModel: viewModel,
            hudController: hudController,
            mediaDetails: mediaDetails,
            debugInfo: debugInfo,
            scrubPreviewSource: scrubPreviewSource,
            controlsTopSafeAreaInset: controlsTopSafeAreaInset,
            onDismiss: dismissPlayer
        )
        #else
        PlayerControlsOverlay(
            viewModel: viewModel,
            mediaDetails: mediaDetails,
            debugInfo: debugInfo,
            scrubPreviewSource: scrubPreviewSource,
            controlsTopSafeAreaInset: controlsTopSafeAreaInset,
            onDismiss: dismissPlayer
        )
        #endif
    }

    #if !os(tvOS)
    private var interactionOverlay: some View {
        PlayerTapInteractionOverlay(
            showsControls: viewModel.showControls,
            doubleTapSeekEnabled: preferences.playerDoubleTapSeekEnabled,
            backwardSeekInterval: preferences.playerDoubleTapBackwardInterval.timeInterval,
            forwardSeekInterval: preferences.playerDoubleTapForwardInterval.timeInterval,
            onToggleControls: { viewModel.toggleControls() },
            onDoubleTapSeek: { offset in viewModel.handleDoubleTapSeek(by: offset) },
            onSpeedBoostBegan: {
                guard !playback.isSharePlayActive else { return false }
                return viewModel.beginSpeedBoost()
            },
            onSpeedBoostEnded: { viewModel.endSpeedBoost() },
            onPointerMoved: { viewModel.touchControls() }
        )
        .ignoresSafeArea()
    }
    #endif

    /// tvOS draws its own seek feedback from the HUD controller's accumulator
    /// (see `PlayerTVTransientBadgeOverlay`), so the shared badge stays off.
    private var shouldShowGlobalSeekFeedback: Bool {
        #if os(tvOS)
        false
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
                #if os(tvOS)
                // Not a Button: a focusable control here would be handed the
                // remote by the focus engine and would fight the input bridge.
                // The chip is "selected" while the HUD is hidden, and the
                // controller turns Select into `handleSkipMarker`.
                skipMarkerButtonLabel(marker)
                    .duskTVOSFocusedScale(isTVBottomTrailingControlSelected, glow: false)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(marker.skipButtonTitle ?? "Skip")
                #else
                Button {
                    handleSkipMarker(marker)
                } label: {
                    skipMarkerButtonLabel(marker)
                }
                .buttonStyle(.plain)
                #endif
            }
        }
        .id(marker.id)
        .padding(.horizontal, PlayerOverlayLayout.controlsHorizontalPadding)
        .padding(.bottom, PlayerOverlayLayout.skipMarkerBottomInset(controlsVisible: viewModel.showControls))
        .animation(PlayerOverlayLayout.skipMarkerRepositionAnimation, value: viewModel.showControls)
        .ignoresSafeArea(edges: .bottom)
    }

    private func skipMarkerButtonLabel(_ marker: PlexMarker) -> some View {
        HStack(spacing: 10) {
            Image(systemName: marker.isCredits ? "forward.end.fill" : "chevron.forward.2")
                .font(DuskFont.glyphSmall(ios: .callout.weight(.semibold)))

            Text(marker.skipButtonTitle ?? "Skip")
                .font(DuskFont.buttonLabel(ios: .subheadline.weight(.semibold)))
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
                .font(DuskFont.sectionHeader(ios: .headline))
                .foregroundStyle(Color.duskTextPrimary)
                .multilineTextAlignment(.center)

            Button(error.requiresReauthentication ? "Sign In" : "Close") {
                if error.requiresReauthentication {
                    viewModel.cleanup()
                    AuthenticationFailure.beginReauthentication(
                        plexService: plexService,
                        playback: playback
                    )
                } else {
                    dismissPlayer()
                }
            }
            .font(DuskFont.buttonLabel(ios: .headline))
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

        let source = await plexService.scrubPreviewSource(
            forPartID: partID,
            serverID: playback.activePlaybackServerID
        )
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

    /// Whether a bottom-trailing control (Skip Intro chip or Up Next poster) is
    /// on screen. On tvOS the HUD controller gives it Select and Down while the
    /// HUD is hidden — without taking the remote away from the input bridge.
    private var hasBottomTrailingFocusControl: Bool {
        viewModel.activeSkipMarker != nil || playback.upNextPoster != nil
    }

    /// Drawn as "selected" only while the HUD is hidden: that is exactly when
    /// the chip / poster owns Select on the remote.
    private var isTVBottomTrailingControlSelected: Bool {
        #if os(tvOS)
        hudController.mode == .hidden && hasBottomTrailingFocusControl
        #else
        false
        #endif
    }

    #if os(tvOS)
    /// The bridge resigns first responder whenever something else needs the
    /// focus engine. Every one of these presents a focusable surface of its
    /// own, and two responders would double-handle Menu and Select.
    private var isTVRemoteCaptureEnabled: Bool {
        playback.upNextPresentation == nil &&
            !hasVisiblePlaybackError &&
            !viewModel.showSubtitleSearch &&
            !viewModel.showPlaybackInfo &&
            !hudController.isPanelPresented
    }

    private func configureTVHUDController() {
        hudController.viewModel = viewModel
        hudController.onDismissPlayer = dismissPlayer
        hudController.onSharePlay = {
            Task { await playback.toggleSharePlay() }
        }
        hudController.onActivateBottomTrailingControl = {
            if let marker = viewModel.activeSkipMarker {
                handleSkipMarker(marker)
            } else if playback.upNextPoster != nil {
                playback.playUpNextPosterNow()
            }
        }
        hudController.onDismissBottomTrailingControl = {
            // The Skip Intro chip has nothing to dismiss; returning false lets
            // Down fall through to opening the settings panel.
            guard playback.upNextPoster != nil else { return false }
            playback.dismissUpNextPoster(userInitiated: true)
            return true
        }
        hudController.isBottomTrailingControlVisible = hasBottomTrailingFocusControl
        hudController.backwardSeekInterval = preferences.playerDoubleTapBackwardInterval.timeInterval
        hudController.forwardSeekInterval = preferences.playerDoubleTapForwardInterval.timeInterval
        hudController.syncControlsVisibility(viewModel.showControls)
    }
    #endif
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
