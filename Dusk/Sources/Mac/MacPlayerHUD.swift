#if os(macOS)
import AppKit
import SwiftUI

/// Every tunable of the Mac play bar in one place, like `PlayerTVHUDLayout`.
enum MacPlayerHUDLayout {
    static let horizontalInset: CGFloat = 24
    static let barBottomInset: CGFloat = 24
    static let fullScreenBarBottomInset: CGFloat = 40
    /// The bar hugs its controls instead of spanning the window, like
    /// QuickTime's and the TV app's.
    static let barMaxWidth: CGFloat = 680
    static let fullScreenBarMaxWidth: CGFloat = 760
    static let barCornerRadius: CGFloat = 22
    static let barHorizontalPadding: CGFloat = 14
    static let barTopPadding: CGFloat = 8
    static let barBottomPadding: CGFloat = 10
    static let transportRowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 2
    /// Top of the timeline row, measured from the top of the bar; hover
    /// bubbles are lifted above the bar from there.
    static let timelineRowTop: CGFloat = barTopPadding + transportRowHeight + rowSpacing
    /// Approximate height of the two-row bar, for overlays that sit above it.
    static let barHeight: CGFloat = 80
    static let bottomTrailingRaisedInset: CGFloat = barBottomInset + barHeight + 14
    static let bottomTrailingRestingInset: CGFloat = 32
    /// Every icon button's hit target, and the gap between neighbours.
    static let iconSize: CGFloat = 28
    static let iconGlyphSize: CGFloat = 15
    static let iconSpacing: CGFloat = 8
    static let transportSpacing: CGFloat = 18
    static let skipGlyphSize: CGFloat = 20
    static let playGlyphSize: CGFloat = 26
    static let volumeSliderWidth: CGFloat = 76
    /// Below this bar width the volume slider folds away (the mute button stays).
    static let volumeSliderMinimumBarWidth: CGFloat = 560
    /// Title row: right of the traffic lights in a window, clear of the menu
    /// bar's reveal area in full screen.
    static let windowControlsGap: CGFloat = 14
    static let fallbackWindowControlsMaxX: CGFloat = 76
    static let fallbackWindowControlsCenterY: CGFloat = 16
    static let fullScreenInset: CGFloat = 40
    static let topScrimHeight: CGFloat = 140
    static let bottomScrimHeight: CGFloat = 200
}

/// The Mac HUD: the window's own traffic lights with a Back button and the
/// title next to them along the top, and a floating Liquid Glass play bar
/// along the bottom, in the shape of QuickTime and the TV app. Mounted through
/// `PlayerControlsOverlay` so it shares the iOS/tvOS context (titles, quality,
/// track availability); `MacPlayerSessionView` fades it with the view model's
/// `showControls`, and the pointer reveals it.
struct MacPlayerHUD: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(UserPreferences.self) private var preferences
    @Environment(MacPlayerCommandTarget.self) private var commandTarget

    let viewModel: PlayerViewModel
    let context: PlayerControlsContext
    let scrubPreviewSource: PlexScrubPreviewSource?
    let onDismiss: () -> Void

    @State private var isHoveringBar = false
    @State private var isMenuTracking = false
    @State private var barWidth: CGFloat = 0

    var body: some View {
        ZStack {
            MacPlayerScrims()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                MacPlayerTopBar(
                    title: context.mediaHeader?.title,
                    subtitle: headerSubtitle,
                    onBack: onDismiss
                )

                Spacer(minLength: 0)

                playBar
                    .frame(maxWidth: commandTarget.isFullScreen
                        ? MacPlayerHUDLayout.fullScreenBarMaxWidth
                        : MacPlayerHUDLayout.barMaxWidth)
                    .padding(.horizontal, MacPlayerHUDLayout.horizontalInset)
                    .padding(.bottom, commandTarget.isFullScreen
                        ? MacPlayerHUDLayout.fullScreenBarBottomInset
                        : MacPlayerHUDLayout.barBottomInset)
            }
        }
        // An open menu (a play-bar menu, or the menu bar) holds the HUD up:
        // the pointer has left the bar for the menu, and the auto-hide would
        // otherwise fade the bar out from under it.
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSMenu.didBeginTrackingNotification) {
                guard !isMenuTracking else { continue }
                isMenuTracking = true
                viewModel.beginControlsInteractionHold()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSMenu.didEndTrackingNotification) {
                guard isMenuTracking else { continue }
                isMenuTracking = false
                viewModel.endControlsInteractionHold()
            }
        }
        .onChange(of: windowTitle, initial: true) { _, title in
            commandTarget.setWindowTitle(title)
        }
        .onDisappear {
            if isHoveringBar {
                viewModel.endControlsInteractionHold()
            }
            if isMenuTracking {
                viewModel.endControlsInteractionHold()
            }
        }
    }

    /// "S1, E3 · Episode Title" for an episode, the edition (never the year)
    /// for a movie; Live TV keeps the shared header's program/channel line.
    private var headerSubtitle: String? {
        guard let header = context.mediaHeader else { return nil }
        if !viewModel.isLiveTV, viewModel.iptvCatchUp == nil, let details = playback.activeItemDetails {
            if details.type == .episode {
                let code: String? = switch (details.parentIndex, details.index) {
                case let (season?, episode?): "S\(season), E\(episode)"
                case let (nil, episode?): "E\(episode)"
                case let (season?, nil): "S\(season)"
                default: nil
                }
                let episodeTitle = details.grandparentTitle == nil ? nil : details.title
                return [code, episodeTitle].compactMap { $0?.nilIfEmpty }.joined(separator: " · ").nilIfEmpty
            }
            return details.editionTitle?.nilIfEmpty
        }
        let parts = [header.secondaryTitle, header.subtitle].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the window is called while the player covers it (Window menu,
    /// Mission Control, VoiceOver): the show and episode, or the movie.
    private var windowTitle: String? {
        guard let header = context.mediaHeader else { return nil }
        if let details = playback.activeItemDetails, details.type == .episode,
           details.grandparentTitle != nil, !viewModel.isLiveTV {
            return "\(header.title) – \(details.title)"
        }
        return header.title
    }

    // MARK: - Play bar

    private var playBar: some View {
        VStack(spacing: MacPlayerHUDLayout.rowSpacing) {
            transportRow
                .frame(height: MacPlayerHUDLayout.transportRowHeight)
            timelineRow
        }
        .padding(.horizontal, MacPlayerHUDLayout.barHorizontalPadding)
        .padding(.top, MacPlayerHUDLayout.barTopPadding)
        .padding(.bottom, MacPlayerHUDLayout.barBottomPadding)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { barWidth = $0 }
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: MacPlayerHUDLayout.barCornerRadius, style: .continuous)
        )
        // Swallow clicks between the buttons so they never reach the click
        // layer underneath (which would pause).
        .contentShape(RoundedRectangle(cornerRadius: MacPlayerHUDLayout.barCornerRadius, style: .continuous))
        .onTapGesture {}
        // The pointer resting on the bar holds it up; leaving releases it.
        .onHover { isInside in
            guard isInside != isHoveringBar else { return }
            isHoveringBar = isInside
            if isInside {
                viewModel.beginControlsInteractionHold()
            } else {
                viewModel.endControlsInteractionHold()
            }
        }
    }

    private var transportRow: some View {
        HStack(spacing: 0) {
            MacPlayerVolumeControl(
                showsSlider: barWidth == 0 || barWidth >= MacPlayerHUDLayout.volumeSliderMinimumBarWidth
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            transportButtons

            trailingButtons
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var transportButtons: some View {
        let isPlaying = viewModel.state == .playing

        return HStack(spacing: MacPlayerHUDLayout.transportSpacing) {
            if showsEpisodeButtons {
                episodeSlot(.previous)
            }
            if !viewModel.isLiveTV {
                skipButton(direction: -1)
            }

            Button {
                viewModel.togglePlayPause()
            } label: {
                MacPlayerHUDIcon(
                    systemName: isPlaying ? "pause.fill" : "play.fill",
                    size: 36,
                    glyphSize: MacPlayerHUDLayout.playGlyphSize
                )
                .contentTransition(.symbolEffect(.replace, options: .speed(2)))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(viewModel.playbackError != nil)
            .help(isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            if !viewModel.isLiveTV {
                skipButton(direction: 1)
            }
            if showsEpisodeButtons {
                episodeSlot(.next)
            }
        }
    }

    private var trailingButtons: some View {
        HStack(spacing: MacPlayerHUDLayout.iconSpacing) {
            airPlayButton

            MacPlayerMenuButton(
                systemName: "captions.bubble",
                help: "Audio & Subtitles",
                accessibilityLabel: "Audio and Subtitles",
                accessibilityValue: context.subtitleControlTitle,
                items: mediaMenuItems
            )
            .disabled(viewModel.audioTracks.isEmpty && viewModel.subtitleTracks.isEmpty && !context.canDownloadSubtitles)

            MacPlayerMenuButton(
                systemName: "ellipsis.circle",
                help: "More",
                accessibilityLabel: "More",
                items: moreMenuItems
            )

            if showsPictureInPicture {
                pictureInPictureButton
            }

            Button {
                commandTarget.toggleFullScreen()
            } label: {
                MacPlayerHUDIcon(
                    systemName: commandTarget.isFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    alignment: .trailing
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(commandTarget.isFullScreen ? "Exit Full Screen (F)" : "Enter Full Screen (F)")
            .accessibilityLabel(commandTarget.isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
        }
    }

    /// AirPlay is an AVPlayer feature; a VLCKit session has no button at all
    /// rather than a permanently dimmed one.
    @ViewBuilder
    private var airPlayButton: some View {
        if let engine = viewModel.engine as? AVPlayerEngine {
            MacPlayerAirPlayButton(
                player: engine.routePickerPlayer,
                isActive: playback.isAirPlayPlaybackActive
            )
        }
    }

    /// Picture in Picture exists only for AVPlayer on the Mac (VLCKit's
    /// sample-buffer PiP is iOS-only), so VLCKit sessions drop the button.
    private var showsPictureInPicture: Bool {
        viewModel.engine is AVPlayerEngine || viewModel.engine.isPictureInPictureActive
    }

    private var pictureInPictureButton: some View {
        let isActive = viewModel.engine.isPictureInPictureActive
        let isAvailable = viewModel.engine.isPictureInPicturePossible || isActive

        return Button {
            viewModel.togglePictureInPicture()
        } label: {
            MacPlayerHUDIcon(systemName: isActive ? "pip.exit" : "pip.enter")
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isAvailable)
        .help(isAvailable
            ? (isActive ? "Exit Picture in Picture" : "Picture in Picture")
            : "Picture in Picture isn't available for this video")
        .accessibilityLabel("Picture in Picture")
    }

    private var timelineRow: some View {
        HStack(spacing: 10) {
            if viewModel.isLiveTV {
                PlayerTimeStatusView(viewModel: viewModel)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize()
            } else {
                timeLabel(MacPlayerTime.format(viewModel.displayPosition), template: timeTemplate, alignment: .leading)
            }

            MacPlayerScrubber(viewModel: viewModel, scrubPreviewSource: scrubPreviewSource)

            if !viewModel.isLiveTV {
                timeLabel(
                    "\u{2212}" + MacPlayerTime.format(max(viewModel.duration - viewModel.displayPosition, 0)),
                    template: "\u{2212}" + timeTemplate,
                    alignment: .trailing
                )
            }
        }
    }

    /// The longest time this item can show, all digits zero: both labels
    /// are sized from it so the track never changes length while playing.
    private var timeTemplate: String {
        MacPlayerTime.format(viewModel.duration)
            .map { $0.isNumber ? "0" : String($0) }
            .joined()
    }

    private func timeLabel(_ text: String, template: String, alignment: Alignment) -> some View {
        Text(template)
            .hidden()
            .overlay(alignment: alignment) {
                Text(text)
                    .fixedSize()
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    // MARK: - Buttons

    /// Every episode with a neighbour gets the buttons on the Mac (the iOS
    /// opt-in has no Mac setting); each side keeps its slot, empty when there
    /// is no episode that way, so play stays centred.
    private var showsEpisodeButtons: Bool {
        guard let adjacent = playback.adjacentEpisodes else { return false }
        return adjacent.episode(.previous) != nil || adjacent.episode(.next) != nil
    }

    private func episodeSlot(_ direction: AdjacentEpisodeDirection) -> some View {
        let exists = playback.adjacentEpisodes?.episode(direction) != nil
        return episodeButton(direction)
            .opacity(exists ? 1 : 0)
            .allowsHitTesting(exists)
            .accessibilityHidden(!exists)
    }

    private func episodeButton(_ direction: AdjacentEpisodeDirection) -> some View {
        let isEnabled = playback.adjacentEpisodes?.episode(direction) != nil && playback.canStepEpisodes

        return Button {
            playback.playAdjacentEpisode(direction, isPastCredits: viewModel.isPastCreditsMarker)
        } label: {
            MacPlayerHUDIcon(
                systemName: direction == .next ? "forward.end.fill" : "backward.end.fill",
                glyphSize: 17
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isEnabled)
        .help(direction == .next ? "Next Episode (⌘→)" : "Previous Episode (⌘←)")
        .accessibilityLabel(direction == .next ? "Next Episode" : "Previous Episode")
    }

    private func skipButton(direction: Int) -> some View {
        let interval = direction < 0
            ? preferences.playerDoubleTapBackwardInterval
            : preferences.playerDoubleTapForwardInterval
        let seconds = interval.rawValue
        let title = direction < 0 ? "Skip Back \(seconds) Seconds" : "Skip Forward \(seconds) Seconds"

        return Button {
            viewModel.handleSeekJump(by: TimeInterval(direction) * interval.timeInterval)
            viewModel.noteControlsInteraction()
        } label: {
            MacPlayerHUDIcon(
                systemName: direction < 0 ? "gobackward.\(seconds)" : "goforward.\(seconds)",
                size: 32,
                glyphSize: MacPlayerHUDLayout.skipGlyphSize
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(viewModel.playbackError != nil)
        .help(title + (direction < 0 ? " (←)" : " (→)"))
        .accessibilityLabel(title)
    }

    // MARK: - Menus

    /// Audio and Subtitles in one menu with a section each, like AVKit's.
    private func mediaMenuItems() -> [MacPlayerMenuItem] {
        var items: [MacPlayerMenuItem] = []

        if !viewModel.audioTracks.isEmpty {
            items.append(.header("Audio"))
            let selectedAudioID = viewModel.selectedAudioTrackID ?? viewModel.engine.selectedAudioTrackID
            for (track, label) in MacPlayerTrackLabel.audioRows(viewModel.audioTracks) {
                items.append(.action(label.title, subtitle: label.detail, isOn: track.id == selectedAudioID) {
                    guard track.id != viewModel.selectedAudioTrackID else { return }
                    viewModel.selectAudio(track)
                })
            }
        }

        if !viewModel.subtitleTracks.isEmpty || context.canDownloadSubtitles {
            items.append(.separator)
            items.append(.header("Subtitles"))
            let selectedSubtitleID = viewModel.selectedSubtitleTrackID
            items.append(.action("Off", isOn: selectedSubtitleID == nil) {
                guard viewModel.selectedSubtitleTrackID != nil else { return }
                viewModel.selectSubtitle(nil)
            })
            for (track, label) in MacPlayerTrackLabel.subtitleRows(
                viewModel.subtitleTracks,
                selectedID: selectedSubtitleID
            ) {
                items.append(.action(label.title, subtitle: label.detail, isOn: track.id == selectedSubtitleID) {
                    guard track.id != viewModel.selectedSubtitleTrackID else { return }
                    viewModel.selectSubtitle(track)
                })
            }

            items.append(.separator)
            // Server-rendered (AirPlay/burned-in) subtitles have no local size.
            if !viewModel.subtitleTracks.isEmpty, !viewModel.usesServerTrackSelection {
                items.append(.submenu(
                    "Subtitle Size",
                    SubtitleFontSize.allCases.map { size in
                        .action(size.displayName, isOn: size == viewModel.subtitleFontSize) {
                            viewModel.selectSubtitleFontSize(size)
                        }
                    }
                ))
            }
            if context.canDownloadSubtitles {
                items.append(.action("Download Subtitles…") {
                    viewModel.showSubtitleSearch = true
                })
            }
        }
        return items
    }

    /// Everything else: quality, speed, channel, sync, zoom, SharePlay, Get Info.
    private func moreMenuItems() -> [MacPlayerMenuItem] {
        var items: [MacPlayerMenuItem] = []

        if let summary = playingQualitySummary {
            items.append(.header(summary))
        }

        if let live = context.liveTVContext {
            items.append(.submenu("Channel", subtitle: live.channel.displayTitle, live.lineup.channels.map { channel in
                let title = [channel.displayNumber, channel.displayTitle].compactMap { $0 }.joined(separator: " · ")
                return .action(title, isOn: channel.id == live.channel.id) {
                    guard channel.id != live.channel.id else { return }
                    let program = live.lineup.guide(for: channel)?.currentProgram()
                    Task {
                        await playback.playLiveTV(channel: channel, program: program, lineup: live.lineup)
                    }
                }
            }))
        }

        if context.hasQualityControl {
            let selected = context.selectedQualityPreset
            items.append(.submenu(
                "Quality",
                subtitle: selected.displayName,
                isEnabled: context.canSelectQuality && !context.isChangingQuality,
                context.availableQualityPresets.map { preset in
                    .action(preset.displayName, subtitle: preset.detailTitle, isOn: preset == selected) {
                        guard preset != context.selectedQualityPreset else { return }
                        Task { await playback.switchQuality(to: preset) }
                    }
                }
            ))
        }

        if !viewModel.isLiveTV, !playback.isSharePlayActive {
            items.append(.submenu(
                "Playback Speed",
                subtitle: PlayerViewModel.playbackSpeedTitle(viewModel.playbackRate),
                PlayerViewModel.playbackSpeedOptions.map { rate in
                    .action(PlayerViewModel.playbackSpeedTitle(rate), isOn: rate == viewModel.playbackRate) {
                        viewModel.setPlaybackRate(rate)
                    }
                }
            ))
        }

        items.append(.separator)

        if !viewModel.audioTracks.isEmpty {
            items.append(.action("Audio Offset…") {
                viewModel.showAudioPicker = true
            })
        }

        items.append(.submenu(
            "Zoom",
            subtitle: viewModel.aspectFillEnabled ? "Fill Window" : "Fit to Window",
            [
                .action("Fit to Window", isOn: !viewModel.aspectFillEnabled) {
                    if viewModel.aspectFillEnabled { viewModel.toggleAspectFill() }
                },
                .action("Fill Window", isOn: viewModel.aspectFillEnabled) {
                    if !viewModel.aspectFillEnabled { viewModel.toggleAspectFill() }
                },
            ]
        ))

        if context.hasSharePlayControl {
            items.append(.action(
                context.isStartingSharePlay
                    ? "Starting SharePlay…"
                    : (context.isSharePlayActive ? "Leave SharePlay" : "Start SharePlay"),
                isEnabled: !context.isStartingSharePlay
            ) {
                Task { await playback.toggleSharePlay() }
            })
        }

        if context.hasPlaybackInfo {
            items.append(.separator)
            items.append(.action("Get Info", shortcut: ("i", .command)) {
                viewModel.showPlaybackInfo = true
            })
        }
        return items
    }

    /// What is playing right now, as the More menu's quiet section title.
    private var playingQualitySummary: String? {
        let live = viewModel.engine.currentVideoQuality
        return (playback.debugInfo?.currentVideoQuality(live: live) ?? live)?.summary
    }
}

// MARK: - Top bar

/// Back button and title, lined up with the window's traffic lights (or clear
/// of the menu bar in full screen). Shared by the HUD and the error state.
struct MacPlayerTopBar: View {
    @Environment(MacPlayerCommandTarget.self) private var commandTarget

    let title: String?
    let subtitle: String?
    let onBack: () -> Void

    private let backButtonSize: CGFloat = 28

    var body: some View {
        let isFullScreen = commandTarget.isFullScreen
        let centerY = isFullScreen
            ? MacPlayerHUDLayout.fullScreenInset
            : (commandTarget.windowControlsCenterY ?? MacPlayerHUDLayout.fallbackWindowControlsCenterY)
        let leading = isFullScreen
            ? MacPlayerHUDLayout.fullScreenInset
            : (commandTarget.windowControlsMaxX ?? MacPlayerHUDLayout.fallbackWindowControlsMaxX)
                + MacPlayerHUDLayout.windowControlsGap
        let titleSize: CGFloat = isFullScreen ? 17 : 14

        HStack(alignment: .top, spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: backButtonSize, height: backButtonSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .glassEffect(.regular.interactive(), in: Circle())
            .help("Back (Esc)")
            .accessibilityLabel("Back")

            if let title {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundStyle(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: isFullScreen ? 13 : 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .lineLimit(1)
                // First line centred on the back button (and the lights).
                .padding(.top, (backButtonSize - titleSize * 1.25) / 2)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 1)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, leading)
        .padding(.trailing, MacPlayerHUDLayout.horizontalInset)
        .padding(.top, max(centerY - backButtonSize / 2, 0))
    }
}

/// A soft dark gradient under the title row and the play bar, so white type
/// reads over any picture. Fades with the HUD.
private struct MacPlayerScrims: View {
    var body: some View {
        VStack(spacing: 0) {
            // Holds most of its strength across the title row before it
            // eases off, so the title stays legible on bright footage.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.42), location: 0.35),
                    .init(color: .black.opacity(0.14), location: 0.7),
                    .init(color: .black.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: MacPlayerHUDLayout.topScrimHeight)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.4)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: MacPlayerHUDLayout.bottomScrimHeight)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Timeline

enum MacPlayerTime {
    static func format(_ seconds: TimeInterval) -> String {
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

/// The Mac timeline: a thin track that thickens under the pointer, a knob on
/// hover or drag, and a bubble above the bar with the time (and the preview
/// frame when the server has thumbnails) at the pointer, without seeking until
/// the viewer clicks or drags. An accessible "Playback Position" slider.
private struct MacPlayerScrubber: View {
    let viewModel: PlayerViewModel
    let scrubPreviewSource: PlexScrubPreviewSource?

    @State private var hoverX: CGFloat?
    @State private var width: CGFloat = 0

    private let height: CGFloat = 16
    private let idleTrackHeight: CGFloat = 4
    private let activeTrackHeight: CGFloat = 7
    private let knobSize: CGFloat = 12

    var body: some View {
        let isActive = hoverX != nil || viewModel.isScrubbing
        let progress = max(0, min(viewModel.timelineProgress(for: viewModel.displayPosition), 1))
        let trackHeight = isActive ? activeTrackHeight : idleTrackHeight

        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(height: trackHeight)

            if let reachable = viewModel.liveReachableTrackRange, width > 0 {
                let start = width * reachable.lowerBound
                let reachableWidth = width * (reachable.upperBound - reachable.lowerBound)
                if reachableWidth >= trackHeight {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(width: reachableWidth, height: trackHeight)
                        .offset(x: start)
                }
            }

            // Under the pointer: the track lightens up to it, the way
            // QuickTime's does, so the hover reads before the bubble.
            if let hoverX, !viewModel.isScrubbing, width > 0 {
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(width: max(min(max(hoverX, 0), width), trackHeight), height: trackHeight)
            }

            Capsule()
                .fill(.white.opacity(0.95))
                .frame(width: max(width * progress, trackHeight), height: trackHeight)
                .opacity(progress > 0 ? 1 : 0)

            if let hoverX, !viewModel.isScrubbing, width > 0 {
                // A slim marker at the pointer, over the played part too.
                Capsule()
                    .fill(.white)
                    .frame(width: 2, height: activeTrackHeight + 5)
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .offset(x: min(max(hoverX, 1), width - 1) - 1)
                    .allowsHitTesting(false)
            }

            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .frame(width: knobSize, height: knobSize)
                .offset(x: width * progress - knobSize / 2)
                .opacity(isActive ? 1 : 0)
                .scaleEffect(isActive ? 1 : 0.5)
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: isActive)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { newWidth in
            width = newWidth
            #if DEBUG
            // `-DuskScreenshotScrubHover 0.4`: screenshot mode parks a pointer
            // over the track, for captures of the hover state.
            if ScreenshotMode.isActive, hoverX == nil,
               let fraction = UserDefaults.standard.object(forKey: "DuskScreenshotScrubHover") as? Double
                ?? Double(UserDefaults.standard.string(forKey: "DuskScreenshotScrubHover") ?? "") {
                hoverX = newWidth * fraction
            }
            #endif
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                hoverX = location.x
            case .ended:
                hoverX = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard width > 0 else { return }
                    if !viewModel.isScrubbing {
                        viewModel.beginScrub()
                    }
                    let fraction = max(0, min(1, value.location.x / width))
                    viewModel.updateScrub(to: viewModel.timelinePosition(for: fraction))
                }
                .onEnded { _ in
                    viewModel.endScrub()
                }
        )
        .overlay(alignment: .topLeading) {
            if width > 0, let bubbleX {
                bubble(at: bubbleX)
            }
        }
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { viewModel.displayPosition },
                    set: { viewModel.seek(to: $0, revealControls: false) }
                ),
                in: positionRange
            ) {
                Text("Playback Position")
            }
            .accessibilityValue(MacPlayerTime.format(viewModel.displayPosition))
        }
    }

    private var positionRange: ClosedRange<TimeInterval> {
        let lower = viewModel.timelinePosition(for: 0)
        let upper = viewModel.timelinePosition(for: 1)
        return upper > lower ? lower...upper : 0...1
    }

    /// The pointer while hovering; the playhead while dragging.
    private var bubbleX: CGFloat? {
        if viewModel.isScrubbing {
            return width * max(0, min(viewModel.timelineProgress(for: viewModel.displayPosition), 1))
        }
        guard let hoverX else { return nil }
        return min(max(hoverX, 0), width)
    }

    @ViewBuilder
    private func bubble(at x: CGFloat) -> some View {
        let position = viewModel.isScrubbing
            ? viewModel.displayPosition
            : viewModel.timelinePosition(for: width > 0 ? x / width : 0)
        // From the top of this row to just above the glass bar.
        let barTop = -MacPlayerHUDLayout.timelineRowTop - 10

        Group {
            if let scrubPreviewSource, scrubPreviewSource.isAvailable {
                PlayerScrubPreviewPopup(source: scrubPreviewSource, position: position)
                    .position(
                        x: clampedX(x, halfWidth: PlayerScrubPreviewPopup.width / 2),
                        y: barTop - PlayerScrubPreviewPopup.height / 2
                    )
            } else if let clock = viewModel.liveClockLabel(for: position) {
                timeBubble(clock)
                    .position(x: clampedX(x, halfWidth: 36), y: barTop - 13)
            } else if !viewModel.isLiveTV, viewModel.duration > 0 {
                timeBubble(MacPlayerTime.format(position))
                    .position(x: clampedX(x, halfWidth: 36), y: barTop - 13)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func timeBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
            .fixedSize()
    }

    /// Keeps the bubble inside the bar's width (it may overhang the track by
    /// the time labels' width).
    private func clampedX(_ x: CGFloat, halfWidth: CGFloat) -> CGFloat {
        let overhang: CGFloat = 54
        let minX = halfWidth - overhang
        let maxX = width - halfWidth + overhang
        guard maxX > minX else { return width / 2 }
        return min(max(x, minX), maxX)
    }
}

// MARK: - Volume

private struct MacPlayerVolumeControl: View {
    let showsSlider: Bool

    private let volume = MacPlayerVolume.shared

    var body: some View {
        HStack(spacing: 4) {
            Button {
                volume.toggleMute()
            } label: {
                MacPlayerHUDIcon(systemName: volume.symbolName, alignment: .leading)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(volume.isMuted ? "Unmute (M)" : "Mute (M)")
            .accessibilityLabel("Mute")
            .accessibilityValue(volume.isMuted ? "On" : "Off")
            .accessibilityAddTraits(volume.isMuted ? .isSelected : [])

            if showsSlider {
                MacPlayerThinSlider(
                    value: Binding(
                        get: { Double(volume.isMuted ? 0 : volume.level) },
                        set: { newValue in
                            volume.level = Float(newValue)
                            if volume.isMuted { volume.isMuted = false }
                        }
                    ),
                    accessibilityLabel: "Volume"
                )
                .frame(width: MacPlayerHUDLayout.volumeSliderWidth)
                .help("Volume (↑/↓)")
            }
        }
    }
}

/// A thin white slider in the timeline's style: 3 pt track, a small knob on
/// hover or drag. Accessible as a standard slider.
private struct MacPlayerThinSlider: View {
    @Binding var value: Double
    let accessibilityLabel: String

    @State private var isHovered = false
    @State private var isDragging = false
    @State private var width: CGFloat = 0

    var body: some View {
        let isActive = isHovered || isDragging
        let fraction = max(0, min(value, 1))
        let trackHeight: CGFloat = isActive ? 5 : 3

        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(height: trackHeight)
            Capsule()
                .fill(.white.opacity(0.95))
                .frame(width: max(width * fraction, trackHeight), height: trackHeight)
                .opacity(fraction > 0 ? 1 : 0)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .frame(width: 10, height: 10)
                .offset(x: width * fraction - 5)
                .opacity(isActive ? 1 : 0)
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: isActive)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard width > 0 else { return }
                    isDragging = true
                    value = max(0, min(1, drag.location.x / width))
                }
                .onEnded { _ in isDragging = false }
        )
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...1) {
                Text(accessibilityLabel)
            }
        }
    }
}

// MARK: - Chrome

/// An icon in the play bar: a white glyph that brightens under the pointer.
/// A soft platter appears only while the button's menu is open (`isActive`).
struct MacPlayerHUDIcon: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    let systemName: String
    var size: CGFloat = MacPlayerHUDLayout.iconSize
    var glyphSize: CGFloat = MacPlayerHUDLayout.iconGlyphSize
    var alignment: Alignment = .center
    var isActive = false
    /// Draws the icon disabled without disabling a surrounding control.
    var isEnabledOverride: Bool?

    var body: some View {
        let enabled = isEnabledOverride ?? isEnabled

        Image(systemName: systemName)
            .font(.system(size: glyphSize, weight: .medium))
            .imageScale(.medium)
            .foregroundStyle(.white.opacity(enabled ? (isHovered || isActive ? 1 : 0.85) : 0.3))
            .frame(width: size, height: size, alignment: alignment)
            .background {
                Circle()
                    .fill(.white.opacity(isActive ? 0.16 : 0))
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}
#endif
