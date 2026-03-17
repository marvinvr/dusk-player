import SwiftUI
import UIKit

enum PlayerOverlayLayout {
    static let controlsHorizontalPadding: CGFloat = 16
    static let skipMarkerBottomInset: CGFloat = 108
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

struct PlayerView: View {
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        Group {
            if let engine = playback.engine,
               let playbackSource = playback.playbackSource {
                PlayerSessionView(
                    engine: engine,
                    playbackSource: playbackSource,
                    mediaDetails: playback.activeItemDetails,
                    debugInfo: playback.debugInfo
                )
                .id(playback.playerPresentationID)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }
}

private struct PlayerSessionView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(UserPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlayerViewModel

    private let playbackSource: PlaybackSource
    private let mediaDetails: PlexMediaDetails?
    private let debugInfo: PlaybackDebugInfo?

    init(
        engine: any PlaybackEngine,
        playbackSource: PlaybackSource,
        mediaDetails: PlexMediaDetails? = nil,
        debugInfo: PlaybackDebugInfo? = nil
    ) {
        _viewModel = State(
            initialValue: PlayerViewModel(
                engine: engine,
                markers: mediaDetails?.markers ?? []
            )
        )
        self.playbackSource = playbackSource
        self.mediaDetails = mediaDetails
        self.debugInfo = debugInfo
    }

    var body: some View {
        @Bindable var vm = viewModel

        ZStack {
            Color.black.ignoresSafeArea()

            viewModel.engineView
                .ignoresSafeArea()

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

                if let seekFeedback = viewModel.seekFeedback {
                    PlayerSeekFeedbackOverlayView(presentation: seekFeedback)
                        .transition(.opacity)
                }

                if viewModel.shouldShowBufferingIndicator {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                }

                if let error = viewModel.playbackError {
                    errorOverlay(error)
                }

                if preferences.playerDebugOverlayEnabled,
                   let debugInfo,
                   viewModel.playbackError == nil {
                    PlayerDebugOverlayView(
                        debugInfo: debugInfo,
                        state: viewModel.state,
                        isBuffering: viewModel.isBuffering
                    )
                }

                if let marker = viewModel.activeSkipMarker,
                   viewModel.playbackError == nil {
                    skipMarkerOverlay(marker)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if viewModel.playbackError == nil {
                    PlayerControlsOverlay(
                        viewModel: viewModel,
                        mediaDetails: mediaDetails,
                        onDismiss: dismissPlayer
                    )
                    .opacity(viewModel.showControls ? 1 : 0)
                    .allowsHitTesting(viewModel.showControls)
                    .accessibilityHidden(!viewModel.showControls)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeSkipMarker?.id)
        .animation(.easeOut(duration: 0.14), value: viewModel.seekFeedback?.trigger)
        .animation(.easeInOut(duration: 0.25), value: playback.upNextPresentation?.episode.ratingKey)
        .duskStatusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            viewModel.configureAutomaticTrackSelection(
                preferences: preferences,
                part: debugInfo?.part ?? mediaDetails?.media.first?.parts.first
            )
            viewModel.autoSkipHandler = { marker in
                if marker.isCredits {
                    Task { @MainActor in
                        let didPresentUpNext = await playback.skipCreditsToUpNextIfPossible()
                        if !didPresentUpNext {
                            viewModel.skipActiveMarker()
                        }
                    }
                } else {
                    viewModel.skipActiveMarker()
                }
            }
            viewModel.startPlaybackIfNeeded(source: playbackSource)
        }
        .onDisappear { viewModel.cleanup() }
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
                itemTitle: \.displayTitle,
                itemSubtitle: \.language,
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
    }

    private var interactionOverlay: some View {
        #if os(tvOS)
        GeometryReader { _ in
            Color.clear
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { viewModel.toggleControls() }
        }
        .ignoresSafeArea()
        #else
        PlayerTapInteractionOverlay(
            showsControls: viewModel.showControls,
            doubleTapSeekEnabled: preferences.playerDoubleTapSeekEnabled,
            backwardSeekInterval: preferences.playerDoubleTapBackwardInterval.timeInterval,
            forwardSeekInterval: preferences.playerDoubleTapForwardInterval.timeInterval,
            onToggleControls: { viewModel.toggleControls() },
            onDoubleTapSeek: { offset in viewModel.handleDoubleTapSeek(by: offset) }
        )
        .ignoresSafeArea()
        #endif
    }

    private func skipMarkerOverlay(_ marker: PlexMarker) -> some View {
        VStack {
            Spacer()

            HStack {
                Spacer()
                Button {
                    viewModel.cancelAutoSkipCountdown()
                    if marker.isCredits {
                        Task { @MainActor in
                            let didPresentUpNext = await playback.skipCreditsToUpNextIfPossible()
                            if !didPresentUpNext {
                                viewModel.skipActiveMarker()
                            }
                        }
                    } else {
                        viewModel.skipActiveMarker()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: marker.isCredits ? "forward.end.fill" : "chevron.forward.2")
                            .font(.callout.weight(.semibold))

                        Text(marker.skipButtonTitle ?? "Skip")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .background {
                        Capsule().fill(.ultraThinMaterial)
                    }
                    .overlay(alignment: .leading) {
                        if let progress = viewModel.autoSkipCountdownProgress {
                            GeometryReader { buttonGeometry in
                                Rectangle()
                                    .fill(.white.opacity(0.18))
                                    .frame(width: buttonGeometry.size.width * progress)
                            }
                            .clipShape(Capsule())
                        }
                    }
                    .overlay {
                        Capsule()
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                    .opacity(0.92)
                }
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(Capsule())
            }
        }
        .padding(.horizontal, PlayerOverlayLayout.controlsHorizontalPadding)
        .padding(.bottom, max(PlayerOverlayLayout.skipMarkerBottomInset, 24))
        .ignoresSafeArea(edges: .bottom)
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
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
    }

    private func dismissPlayer() {
        viewModel.cleanup()
        dismiss()
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

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PlayerTapInteractionView {
        let view = PlayerTapInteractionView()
        view.backgroundColor = .clear
        view.addGestureRecognizer(context.coordinator.tapRecognizer)
        context.coordinator.sync(with: self)
        return view
    }

    func updateUIView(_ uiView: PlayerTapInteractionView, context: Context) {
        context.coordinator.sync(with: self)
    }

    @MainActor
    final class Coordinator: NSObject {
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

        private var pendingTap: PendingTap?
        private var pendingSingleTapWorkItem: DispatchWorkItem?
        private var suppressSingleTapUntil: CFTimeInterval = 0
        private var controlsAreVisible: Bool

        init(parent: PlayerTapInteractionOverlay) {
            self.parent = parent
            self.controlsAreVisible = parent.showsControls
            super.init()
            tapRecognizer.numberOfTapsRequired = 1
            tapRecognizer.cancelsTouchesInView = false
            tapRecognizer.addTarget(self, action: #selector(handleTap(_:)))
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
#endif
