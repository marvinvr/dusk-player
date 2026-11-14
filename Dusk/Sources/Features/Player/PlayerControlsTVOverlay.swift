#if os(tvOS)
import SwiftUI

/// The tvOS play bar.
///
/// Bottom-anchored and deliberately shaped like AVPlayerViewController's:
/// the media title on the leading edge with the circular actions trailing on
/// the same row, then the bar with its elapsed / remaining readouts inline.
/// Selection is drawn from `PlayerTVHUDController.transportFocus` — nothing here is
/// focusable, so the SwiftUI focus engine never takes the remote away from
/// `PlayerTVRemoteInputBridge`. The settings panel is the single exception and
/// owns focus outright while it is up.
struct PlayerControlsTVOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PlaybackCoordinator.self) private var playback

    let viewModel: PlayerViewModel
    let controller: PlayerTVHUDController
    let context: PlayerControlsContext
    let scrubPreviewSource: PlexScrubPreviewSource?

    private var isScrubbing: Bool {
        controller.mode == .scrubbing
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                backdrop

                transport
                    .opacity(controller.mode == .panel ? 0 : 1)
                    .accessibilityHidden(controller.mode == .panel)

                if controller.mode == .panel {
                    PlayerTVInfoPanel(
                        viewModel: viewModel,
                        controller: controller,
                        context: context,
                        tabs: controller.availablePanelTabs,
                        onClose: { controller.closePanel() }
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: geometry.size.height * PlayerTVHUDLayout.panelHeightFraction,
                        alignment: .bottom
                    )
                    .padding(.horizontal, PlayerTVHUDLayout.horizontalInset)
                    .padding(.bottom, PlayerTVHUDLayout.bottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea()
        .animation(
            PlayerTVHUDLayout.animation(PlayerTVHUDLayout.panelTransition, reduceMotion: reduceMotion),
            value: controller.mode
        )
        // The controller needs these while the HUD is hidden too (the first
        // press after a reveal can already move onto the row or open the
        // panel), which is why the whole overlay stays mounted and only
        // fades — see `PlayerSessionView`.
        .onChange(of: actionItems, initial: true) { _, items in
            controller.actions = items
        }
        .onChange(of: panelTabs, initial: true) { _, tabs in
            controller.availablePanelTabs = tabs
        }
    }

    // MARK: - Layers

    private var backdrop: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.32), .black.opacity(0.78)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: PlayerTVHUDLayout.backdropHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title leading, actions trailing, both sitting on the bar. Stacking
            // the actions above the title left them floating a whole title
            // block (up to five lines) away from the bar they belong to.
            HStack(alignment: .bottom, spacing: PlayerTVHUDLayout.actionRowSpacing) {
                if let header = context.mediaHeader {
                    PlayerMediaHeaderView(header: header)
                }

                Spacer(minLength: 0)

                if !controller.actions.isEmpty {
                    PlayerTVActionRow(
                        actions: controller.actions,
                        selectedIndex: selectedActionIndex,
                        reduceMotion: reduceMotion
                    )
                }
            }
            .padding(.bottom, PlayerTVHUDLayout.titleBottomSpacing)
            // The scrub thumbnail is 240x135 and is positioned above the bar
            // row, so it lands on top of this block. Fading rather than
            // removing keeps the bar from jumping as it appears.
            .opacity(isScrubbing ? 0 : 1)

            PlayerTVTransportBar(
                viewModel: viewModel,
                controller: controller,
                scrubPreviewSource: scrubPreviewSource,
                reduceMotion: reduceMotion
            )

            if controller.mode == .scrubbing {
                PlayerTVScrubHint()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 14)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, PlayerTVHUDLayout.horizontalInset)
        .padding(.bottom, PlayerTVHUDLayout.bottomInset)
    }

    // MARK: - Derived state

    private var selectedActionIndex: Int? {
        guard case let .action(index) = controller.transportFocus,
              !controller.actions.isEmpty else {
            return nil
        }
        return min(max(index, 0), controller.actions.count - 1)
    }

    /// Kept short on purpose. Quality, Channel and Chapters are one
    /// Down-press away in the panel's tab strip; crowding the row with nine
    /// circles is exactly what the old gear menu felt like. Advanced playback
    /// controls add skip back / forward at the leading end and a Speed
    /// shortcut; Left/Right on the bar keep seeking either way.
    private var actionItems: [PlayerTVActionItem] {
        var items: [PlayerTVActionItem] = []

        if context.showsSkipButtons {
            items.append(.skipBackward(seconds: Int(controller.backwardSeekInterval)))
            items.append(.skipForward(seconds: Int(controller.forwardSeekInterval)))
        }
        if viewModel.isLiveTV, !viewModel.isAtLiveEdge {
            items.append(.goLive)
        }
        if !viewModel.subtitleTracks.isEmpty || context.canDownloadSubtitles {
            items.append(.panel(.subtitles))
        }
        if !viewModel.audioTracks.isEmpty {
            items.append(.panel(.audio))
        }
        if !panelTabs.isEmpty {
            items.append(.panel(.info))
        }
        if context.speedControl != .hidden {
            items.append(.panel(.speed))
        }
        // Last, so it sits at the trailing end of the row. Only present while
        // there is a next episode to play (and no SharePlay group to leave
        // behind): a dimmed button would still be a stop on the row, and a
        // disabled control should not take selection on tvOS. Left out while
        // the Up Next poster is up: the poster is the same action, one Up away
        // right above the row, and the button's tooltip would run into it.
        if playback.upNextPoster == nil,
           let nextEpisode = playback.adjacentEpisodes?.episode(.next),
           playback.canStepEpisodes {
            items.append(.nextEpisode(
                label: MediaTextFormatter.compactSeasonEpisodeLabel(
                    season: nextEpisode.parentIndex,
                    episode: nextEpisode.index
                ) ?? nextEpisode.title
            ))
        }

        return items
    }

    private var panelTabs: [PlayerTVPanelTab] {
        var tabs: [PlayerTVPanelTab] = []

        if context.hasPlaybackInfo || context.mediaHeader != nil {
            tabs.append(.info)
        }
        if !viewModel.chapterMarkers.isEmpty {
            tabs.append(.chapters)
        }
        if !viewModel.audioTracks.isEmpty {
            tabs.append(.audio)
        }
        if !viewModel.subtitleTracks.isEmpty || context.canDownloadSubtitles {
            tabs.append(.subtitles)
        }
        if context.hasQualityControl {
            tabs.append(.quality)
        }
        if context.liveTVContext != nil {
            tabs.append(.channel)
        }
        if context.speedControl != .hidden {
            tabs.append(.speed)
        }

        return tabs
    }
}
#endif
