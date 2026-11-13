#if os(macOS)
import AppKit
import SwiftUI

/// Every tunable of the Mac play bar in one place, like `PlayerTVHUDLayout`.
enum MacPlayerHUDLayout {
    static let horizontalInset: CGFloat = 24
    static let barBottomInset: CGFloat = 20
    static let barMaxWidth: CGFloat = 860
    static let barCornerRadius: CGFloat = 22
    /// Approximate height of the two-row bar, for overlays that sit above it.
    static let barHeight: CGFloat = 92
    static let bottomTrailingRaisedInset: CGFloat = barBottomInset + barHeight + 14
    static let bottomTrailingRestingInset: CGFloat = 32
    /// Keeps the top bar clear of the window's traffic lights. Full screen has
    /// no title bar, so the bar moves up.
    static let windowedTopInset: CGFloat = 40
    static let fullScreenTopInset: CGFloat = 20
    static let iconSize: CGFloat = 30
    static let playButtonSize: CGFloat = 40
}

/// The Mac HUD: a title bar along the top and a floating Liquid Glass play bar
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

    var body: some View {
        ZStack {
            PlayerControlsGradientBackdrop()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, MacPlayerHUDLayout.horizontalInset)
                    .padding(.top, commandTarget.isFullScreen
                        ? MacPlayerHUDLayout.fullScreenTopInset
                        : MacPlayerHUDLayout.windowedTopInset)

                Spacer(minLength: 0)

                playBar
                    .frame(maxWidth: MacPlayerHUDLayout.barMaxWidth)
                    .padding(.horizontal, MacPlayerHUDLayout.horizontalInset)
                    .padding(.bottom, MacPlayerHUDLayout.barBottomInset)
            }
        }
        // An open menu (a track menu, or the menu bar) holds the HUD up: the
        // pointer has left the bar for the menu, and the auto-hide would
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
        .onDisappear {
            if isHoveringBar {
                viewModel.endControlsInteractionHold()
            }
            if isMenuTracking {
                viewModel.endControlsInteractionHold()
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .help("Close Player")
            .accessibilityLabel("Close Player")

            if let header = context.mediaHeader {
                PlayerMediaHeaderView(header: header)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Play bar

    private var playBar: some View {
        VStack(spacing: 6) {
            transportRow
            timelineRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            RoundedRectangle(cornerRadius: MacPlayerHUDLayout.barCornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(.black.opacity(0.22)),
                    in: RoundedRectangle(cornerRadius: MacPlayerHUDLayout.barCornerRadius, style: .continuous)
                )
        }
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
            MacPlayerVolumeControl()
                .frame(maxWidth: .infinity, alignment: .leading)

            transportButtons

            trailingButtons
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var transportButtons: some View {
        let isPlaying = viewModel.state == .playing

        return HStack(spacing: 10) {
            if showsEpisodeButtons {
                episodeButton(.previous)
            }
            if !viewModel.isLiveTV {
                skipButton(direction: -1)
            }

            Button {
                viewModel.togglePlayPause()
            } label: {
                MacPlayerHUDIcon(
                    systemName: isPlaying ? "pause.fill" : "play.fill",
                    size: MacPlayerHUDLayout.playButtonSize,
                    glyphSize: 22
                )
                .contentTransition(.symbolEffect(.replace, options: .speed(2)))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.playbackError != nil)
            .help(isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            if !viewModel.isLiveTV {
                skipButton(direction: 1)
            }
            if showsEpisodeButtons {
                episodeButton(.next)
            }
        }
    }

    private var trailingButtons: some View {
        HStack(spacing: 4) {
            MacPlayerSubtitlesMenu(viewModel: viewModel, context: context)
            MacPlayerAudioMenu(viewModel: viewModel)
            MacPlayerSettingsMenu(viewModel: viewModel, context: context)

            if viewModel.engine.isPictureInPicturePossible || viewModel.engine.isPictureInPictureActive {
                Button {
                    viewModel.togglePictureInPicture()
                } label: {
                    MacPlayerHUDIcon(
                        systemName: viewModel.engine.isPictureInPictureActive ? "pip.exit" : "pip.enter"
                    )
                }
                .buttonStyle(.plain)
                .help("Picture in Picture")
                .accessibilityLabel("Picture in Picture")
            }

            Button {
                commandTarget.toggleFullScreen()
            } label: {
                MacPlayerHUDIcon(
                    systemName: commandTarget.isFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
            }
            .buttonStyle(.plain)
            .help(commandTarget.isFullScreen ? "Exit Full Screen (F)" : "Enter Full Screen (F)")
            .accessibilityLabel(commandTarget.isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
        }
    }

    private var timelineRow: some View {
        HStack(spacing: 12) {
            if viewModel.isLiveTV {
                PlayerTimeStatusView(viewModel: viewModel)
                    .font(.callout)
                    .fixedSize()
            } else {
                timeLabel(formatTime(viewModel.displayPosition))
            }

            MacPlayerTimeline(viewModel: viewModel, scrubPreviewSource: scrubPreviewSource)

            if !viewModel.isLiveTV {
                timeLabel("-" + formatTime(max(viewModel.duration - viewModel.displayPosition, 0)))
            }
        }
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .frame(minWidth: 52)
    }

    // MARK: - Buttons

    /// Opt-in like on iOS (`playerEpisodeButtonsEnabled`); the Playback menu
    /// always offers Previous/Next Episode.
    private var showsEpisodeButtons: Bool {
        preferences.playerEpisodeButtonsEnabled && playback.adjacentEpisodes != nil
    }

    private func episodeButton(_ direction: AdjacentEpisodeDirection) -> some View {
        let isEnabled = playback.adjacentEpisodes?.episode(direction) != nil && playback.canStepEpisodes

        return Button {
            playback.playAdjacentEpisode(direction, isPastCredits: viewModel.isPastCreditsMarker)
        } label: {
            MacPlayerHUDIcon(systemName: direction == .next ? "forward.end.fill" : "backward.end.fill")
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(direction == .next ? "Next Episode" : "Previous Episode")
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
            MacPlayerHUDIcon(systemName: direction < 0 ? "gobackward.\(seconds)" : "goforward.\(seconds)")
        }
        .buttonStyle(.plain)
        .disabled(viewModel.playbackError != nil)
        .help(title + (direction < 0 ? " (←)" : " (→)"))
        .accessibilityLabel(title)
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

// MARK: - Timeline

/// The shared seek bar plus a hover readout: pointing at the bar shows the
/// preview frame (or the time) under the pointer without seeking, the way the
/// TV app and QuickTime do. Dragging uses the seek bar's own scrub preview.
private struct MacPlayerTimeline: View {
    let viewModel: PlayerViewModel
    let scrubPreviewSource: PlexScrubPreviewSource?

    @State private var hoverX: CGFloat?
    @State private var width: CGFloat = 0

    var body: some View {
        PlayerSeekBar(
            viewModel: viewModel,
            isInteractive: true,
            scrubPreviewSource: scrubPreviewSource
        )
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                hoverX = location.x
            case .ended:
                hoverX = nil
            }
        }
        .overlay(alignment: .topLeading) {
            if let hoverX, !viewModel.isScrubbing, width > 0 {
                hoverReadout(at: hoverX)
            }
        }
    }

    @ViewBuilder
    private func hoverReadout(at x: CGFloat) -> some View {
        let fraction = max(0, min(1, x / width))
        let position = viewModel.timelinePosition(for: fraction)
        let clampedX = min(max(x, 0), width)

        Group {
            if let scrubPreviewSource, scrubPreviewSource.isAvailable {
                PlayerScrubPreviewPopup(source: scrubPreviewSource, position: position)
                    .position(
                        x: popupX(clampedX, halfWidth: PlayerScrubPreviewPopup.width / 2),
                        y: PlayerScrubPreviewPopup.verticalPosition
                    )
            } else if let clock = viewModel.liveClockLabel(for: position) {
                PlayerLiveClockBubble(label: clock)
                    .position(x: popupX(clampedX, halfWidth: 34), y: PlayerLiveClockBubble.verticalPosition)
            } else if !viewModel.isLiveTV, viewModel.duration > 0 {
                PlayerLiveClockBubble(label: Self.formatTime(position))
                    .position(x: popupX(clampedX, halfWidth: 34), y: PlayerLiveClockBubble.verticalPosition)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func popupX(_ x: CGFloat, halfWidth: CGFloat) -> CGFloat {
        guard width > halfWidth * 2 else { return width / 2 }
        return min(max(x, halfWidth), width - halfWidth)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
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

// MARK: - Volume

private struct MacPlayerVolumeControl: View {
    private let volume = MacPlayerVolume.shared

    var body: some View {
        HStack(spacing: 6) {
            Button {
                volume.toggleMute()
            } label: {
                MacPlayerHUDIcon(systemName: volume.symbolName, glyphSize: 13)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(volume.isMuted ? "Unmute (M)" : "Mute (M)")
            .accessibilityLabel(volume.isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { Double(volume.isMuted ? 0 : volume.level) },
                    set: { newValue in
                        volume.level = Float(newValue)
                        if volume.isMuted { volume.isMuted = false }
                    }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .frame(width: 88)
            .accessibilityLabel("Volume")
        }
    }
}

// MARK: - Menus

/// Subtitle tracks, size and Download Subtitles, as a native menu.
private struct MacPlayerSubtitlesMenu: View {
    let viewModel: PlayerViewModel
    let context: PlayerControlsContext

    var body: some View {
        Menu {
            Picker("Subtitles", selection: selection) {
                Text("Off").tag(Int?.none)
                ForEach(viewModel.subtitleTracks) { track in
                    Text(menuTitle(track.displayTitle, detail: track.pickerDetailTitle))
                        .tag(Optional(track.id))
                }
            }
            .pickerStyle(.inline)

            Divider()

            Picker("Subtitle Size", selection: sizeSelection) {
                ForEach(SubtitleFontSize.allCases) { size in
                    Text(size.displayName).tag(size)
                }
            }
            .pickerStyle(.menu)
            // Server-rendered (AirPlay/burned-in) subtitles have no local size.
            .disabled(viewModel.subtitleTracks.isEmpty || viewModel.usesServerTrackSelection)

            if context.canDownloadSubtitles {
                Button("Download Subtitles…") {
                    viewModel.showSubtitleSearch = true
                }
            }
        } label: {
            MacPlayerHUDIcon(
                systemName: viewModel.selectedSubtitleTrack == nil ? "captions.bubble" : "captions.bubble.fill"
            )
        }
        .macPlayerHUDMenuStyle()
        .disabled(viewModel.subtitleTracks.isEmpty && !context.canDownloadSubtitles)
        .help("Subtitles")
        .accessibilityLabel("Subtitles")
        .accessibilityValue(context.subtitleControlTitle)
    }

    private var selection: Binding<Int?> {
        Binding(
            get: { viewModel.selectedSubtitleTrackID },
            set: { id in
                let track = id.flatMap { id in viewModel.subtitleTracks.first { $0.id == id } }
                viewModel.selectSubtitle(track)
            }
        )
    }

    private var sizeSelection: Binding<SubtitleFontSize> {
        Binding(
            get: { viewModel.subtitleFontSize },
            set: { viewModel.selectSubtitleFontSize($0) }
        )
    }
}

/// Audio tracks and the manual audio offset.
private struct MacPlayerAudioMenu: View {
    let viewModel: PlayerViewModel

    var body: some View {
        Menu {
            Picker("Audio", selection: selection) {
                ForEach(viewModel.audioTracks) { track in
                    Text(menuTitle(track.compactDisplayTitle, detail: track.detailDisplayTitle))
                        .tag(Optional(track.id))
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button("Audio Offset…") {
                viewModel.showAudioPicker = true
            }
        } label: {
            MacPlayerHUDIcon(systemName: "waveform")
        }
        .macPlayerHUDMenuStyle()
        .disabled(viewModel.audioTracks.isEmpty)
        .help("Audio")
        .accessibilityLabel("Audio")
    }

    private var selection: Binding<Int?> {
        Binding(
            get: { viewModel.selectedAudioTrackID },
            set: { id in
                guard let id, let track = viewModel.audioTracks.first(where: { $0.id == id }) else { return }
                viewModel.selectAudio(track)
            }
        )
    }
}

/// Quality, speed, Live TV channels, zoom, SharePlay and Get Info: the iOS
/// gear menu's contents, as a Mac menu.
private struct MacPlayerSettingsMenu: View {
    @Environment(PlaybackCoordinator.self) private var playback

    let viewModel: PlayerViewModel
    let context: PlayerControlsContext

    var body: some View {
        Menu {
            if let playingQualitySummary {
                Section(playingQualitySummary) {
                    sessionItems
                }
            } else {
                sessionItems
            }

            Divider()

            Toggle("Zoom to Fill", isOn: Binding(
                get: { viewModel.aspectFillEnabled },
                set: { _ in viewModel.toggleAspectFill() }
            ))

            if context.hasSharePlayControl {
                Button(
                    context.isStartingSharePlay
                        ? "Starting SharePlay…"
                        : (context.isSharePlayActive ? "Leave SharePlay" : "Start SharePlay")
                ) {
                    Task { await playback.toggleSharePlay() }
                }
                .disabled(context.isStartingSharePlay)
            }

            if context.hasPlaybackInfo {
                Divider()
                Button("Get Info") {
                    viewModel.showPlaybackInfo = true
                }
            }
        } label: {
            MacPlayerHUDIcon(systemName: "gearshape")
        }
        .macPlayerHUDMenuStyle()
        .help("Playback Settings")
        .accessibilityLabel("Playback Settings")
    }

    @ViewBuilder
    private var sessionItems: some View {
        if let live = context.liveTVContext {
            Menu("Channel") {
                ForEach(live.lineup.channels) { channel in
                    Toggle(
                        [channel.displayNumber, channel.displayTitle]
                            .compactMap { $0 }
                            .joined(separator: " · "),
                        isOn: Binding(
                            get: { channel.id == live.channel.id },
                            set: { _ in
                                guard channel.id != live.channel.id else { return }
                                let program = live.lineup.guide(for: channel)?.currentProgram()
                                Task {
                                    await playback.playLiveTV(
                                        channel: channel,
                                        program: program,
                                        lineup: live.lineup
                                    )
                                }
                            }
                        )
                    )
                }
            }
        }

        if context.hasQualityControl {
            Picker("Quality", selection: qualitySelection) {
                ForEach(context.availableQualityPresets) { preset in
                    Text(menuTitle(preset.displayName, detail: preset.detailTitle)).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .disabled(!context.canSelectQuality || context.isChangingQuality)
        }

        if !viewModel.isLiveTV, !playback.isSharePlayActive {
            Picker("Speed", selection: Binding(
                get: { viewModel.playbackRate },
                set: { viewModel.setPlaybackRate($0) }
            )) {
                ForEach(PlayerViewModel.playbackSpeedOptions, id: \.self) { rate in
                    Text(PlayerViewModel.playbackSpeedTitle(rate)).tag(rate)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var qualitySelection: Binding<PlaybackQualityPreset> {
        Binding(
            get: { context.selectedQualityPreset },
            set: { preset in
                guard preset != context.selectedQualityPreset else { return }
                Task { await playback.switchQuality(to: preset) }
            }
        )
    }

    /// What is playing right now, as the menu's quiet section title.
    private var playingQualitySummary: String? {
        let live = viewModel.engine.currentVideoQuality
        return (playback.debugInfo?.currentVideoQuality(live: live) ?? live)?.summary
    }
}

private func menuTitle(_ title: String, detail: String?) -> String {
    guard let detail, !detail.isEmpty else { return title }
    return "\(title) · \(detail)"
}

// MARK: - Chrome

/// An icon in the play bar: white glyph, a soft platter on hover. Used as the
/// label of plain buttons and menus so both read as one row of controls.
struct MacPlayerHUDIcon: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    let systemName: String
    var size: CGFloat = MacPlayerHUDLayout.iconSize
    var glyphSize: CGFloat = 15

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.35))
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(.white.opacity(isHovered && isEnabled ? 0.14 : 0))
            }
            .contentShape(Circle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private extension View {
    func macPlayerHUDMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
#endif
