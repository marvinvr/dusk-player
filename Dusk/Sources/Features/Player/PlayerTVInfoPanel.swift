#if os(tvOS)
import SwiftUI

/// The settings sheet that replaced the old three-level gear menu.
///
/// This is the **only** part of the tvOS player that uses SwiftUI focus. While
/// it is up, `PlayerTVRemoteInputBridge` resigns capture (see
/// `PlayerSessionView.isTVRemoteCaptureEnabled`), so the focus engine owns the
/// remote outright and there is no first-responder fight. Menu closes it and
/// hands the remote back.
struct PlayerTVInfoPanel: View {
    @Environment(PlaybackCoordinator.self) private var playback

    let viewModel: PlayerViewModel
    let controller: PlayerTVHUDController
    let context: PlayerControlsContext
    let tabs: [PlayerTVPanelTab]
    let onClose: () -> Void

    @FocusState private var focusedRow: String?

    private static let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        VStack(spacing: 0) {
            tabStrip

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: PlayerTVHUDLayout.panelRowSpacing) {
                    rows
                }
                .padding(.horizontal, PlayerTVHUDLayout.panelHorizontalPadding)
                .padding(.vertical, 24)
            }
            .focusSection()
        }
        .background {
            RoundedRectangle(cornerRadius: PlayerTVHUDLayout.panelCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: PlayerTVHUDLayout.panelCornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: PlayerTVHUDLayout.panelCornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: PlayerTVHUDLayout.panelCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 32, y: 12)
        .onExitCommand(perform: onClose)
        .onAppear {
            // The panel's first focusable view does not exist yet on the pass
            // that mounts it; yielding once lets the focus engine see it.
            Task { @MainActor in
                await Task.yield()
                focusedRow = Self.tabRowID(controller.panelTab)
            }
        }
        .onChange(of: focusedRow) { _, newValue in
            guard let newValue, let tab = Self.tab(forRowID: newValue) else { return }
            guard controller.panelTab != tab else { return }
            controller.panelTab = tab
        }
    }

    // MARK: - Tabs

    private var tabStrip: some View {
        HStack(spacing: 12) {
            ForEach(tabs) { tab in
                Button {
                    controller.panelTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                        .font(DuskFont.TV.rowValue)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .foregroundStyle(
                            controller.panelTab == tab ? Color.duskTextPrimary : Color.duskTextSecondary
                        )
                        .background {
                            Capsule()
                                .fill(tabBackground(for: tab))
                        }
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    focusedRow == Self.tabRowID(tab)
                                        ? Color.duskAccent.opacity(0.55)
                                        : .white.opacity(0.06),
                                    lineWidth: 1
                                )
                        }
                }
                .duskSuppressTVOSButtonChrome()
                .focusEffectDisabled()
                .focused($focusedRow, equals: Self.tabRowID(tab))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PlayerTVHUDLayout.panelHorizontalPadding)
        .padding(.vertical, 22)
        .focusSection()
    }

    private func tabBackground(for tab: PlayerTVPanelTab) -> Color {
        if focusedRow == Self.tabRowID(tab) {
            return Color.duskSurface.opacity(0.96)
        }
        return controller.panelTab == tab ? Color.duskSurface.opacity(0.7) : .white.opacity(0.04)
    }

    private static func tabRowID(_ tab: PlayerTVPanelTab) -> String {
        "tab.\(tab.rawValue)"
    }

    private static func tab(forRowID id: String) -> PlayerTVPanelTab? {
        guard id.hasPrefix("tab.") else { return nil }
        return PlayerTVPanelTab(rawValue: String(id.dropFirst(4)))
    }

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        switch controller.panelTab {
        case .info:
            infoRows
        case .chapters:
            chapterRows
        case .audio:
            audioRows
        case .subtitles:
            subtitleRows
        case .quality:
            qualityRows
        case .channel:
            channelRows
        case .speed:
            speedRows
        }
    }

    @ViewBuilder
    private var infoRows: some View {
        if let header = context.mediaHeader {
            Text(header.title)
                .font(DuskFont.TV.sectionHeader)
                .foregroundStyle(Color.duskTextPrimary)

            if let secondaryTitle = header.secondaryTitle {
                Text(secondaryTitle)
                    .font(DuskFont.TV.rowValue)
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }

        if let summary = context.summary, !summary.isEmpty {
            Text(summary)
                .font(DuskFont.TV.body)
                .foregroundStyle(Color.duskTextPrimary.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
        }

        ForEach(infoEntries) { entry in
            HStack(alignment: .top, spacing: 24) {
                Text(entry.label.uppercased())
                    .font(DuskFont.TV.groupHeader)
                    .foregroundStyle(Color.duskTextSecondary)
                    .frame(width: 220, alignment: .leading)

                Text(entry.value)
                    .font(DuskFont.TV.rowValue)
                    .foregroundStyle(Color.duskTextPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        }

        if context.hasPlaybackInfo {
            panelRow(
                id: "info.more",
                title: "More…",
                subtitle: "Full playback diagnostics",
                systemImage: "info.circle"
            ) {
                onClose()
                viewModel.showPlaybackInfo = true
            }
        }
    }

    private struct InfoEntry: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private var infoEntries: [InfoEntry] {
        var entries: [InfoEntry] = []
        if let debugInfo = playback.debugInfo {
            entries.append(InfoEntry(label: "Engine", value: debugInfo.engineLabel))
            entries.append(InfoEntry(label: "Mode", value: debugInfo.decisionLabel))
            entries.append(InfoEntry(label: "Video", value: debugInfo.videoLabel))
            entries.append(InfoEntry(label: "Audio", value: debugInfo.audioLabel))
            entries.append(InfoEntry(label: "Resolution", value: debugInfo.resolutionLabel))
        }
        entries.append(InfoEntry(label: "Subtitles", value: context.subtitleControlTitle))
        return entries
    }

    @ViewBuilder
    private var chapterRows: some View {
        ForEach(viewModel.chapterMarkers) { marker in
            let start = TimeInterval(marker.startTimeOffset) / 1000
            panelRow(
                id: "chapter.\(marker.id)",
                title: marker.isIntro ? "Intro" : "Credits",
                subtitle: PlayerTVTimeFormatter.string(start),
                systemImage: marker.isIntro ? "chevron.forward.2" : "forward.end.fill"
            ) {
                viewModel.seek(to: start, revealControls: false)
                onClose()
            }
        }
    }

    @ViewBuilder
    private var audioRows: some View {
        if viewModel.audioTracks.isEmpty {
            emptyRow("No Audio Tracks")
        } else {
            ForEach(viewModel.audioTracks) { track in
                panelRow(
                    id: "audio.\(track.id)",
                    title: track.compactDisplayTitle,
                    subtitle: track.detailDisplayTitle,
                    isSelected: viewModel.selectedAudioTrackID == track.id
                ) {
                    viewModel.selectAudio(track)
                }
            }
        }
    }

    @ViewBuilder
    private var subtitleRows: some View {
        if viewModel.subtitleTracks.isEmpty {
            emptyRow("No Subtitles")
        } else {
            panelRow(
                id: "subtitle.off",
                title: "Off",
                isSelected: viewModel.selectedSubtitleTrack == nil
            ) {
                viewModel.selectSubtitle(nil)
            }

            ForEach(viewModel.subtitleTracks) { track in
                panelRow(
                    id: "subtitle.\(track.id)",
                    title: track.displayTitle,
                    subtitle: track.pickerDetailTitle,
                    isSelected: viewModel.selectedSubtitleTrackID == track.id
                ) {
                    viewModel.selectSubtitle(track)
                }
            }
        }

        if canResizeSubtitles {
            sectionHeader("Size")

            ForEach(SubtitleFontSize.allCases) { size in
                panelRow(
                    id: "subtitleSize.\(size.id)",
                    title: size.displayName,
                    subtitle: size.detailTitle,
                    isSelected: viewModel.subtitleFontSize == size
                ) {
                    viewModel.selectSubtitleFontSize(size)
                }
            }
        }

        if context.canDownloadSubtitles {
            panelRow(
                id: "subtitle.download",
                title: "Download Subtitles",
                systemImage: "arrow.down.circle"
            ) {
                onClose()
                viewModel.showSubtitleSearch = true
            }
        }
    }

    /// Subtitle size only means something for locally rendered subtitles.
    /// AirPlay sessions get theirs burned in by the Plex transcoder.
    private var canResizeSubtitles: Bool {
        !viewModel.subtitleTracks.isEmpty && !viewModel.usesServerTrackSelection
    }

    @ViewBuilder
    private var qualityRows: some View {
        if !context.canSelectQuality {
            emptyRow(context.qualityControlTitle)
        } else {
            ForEach(context.availableQualityPresets) { preset in
                panelRow(
                    id: "quality.\(preset.id)",
                    title: preset.displayName,
                    subtitle: preset.detailTitle,
                    isSelected: context.selectedQualityPreset == preset,
                    isDisabled: context.isChangingQuality
                ) {
                    guard context.selectedQualityPreset != preset else { return }
                    onClose()
                    Task {
                        await playback.switchQuality(to: preset)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var channelRows: some View {
        if let live = context.liveTVContext {
            ForEach(live.lineup.channels) { channel in
                panelRow(
                    id: "channel.\(channel.id)",
                    title: [channel.displayNumber, channel.displayTitle]
                        .compactMap { $0 }
                        .joined(separator: " · "),
                    isSelected: channel.id == live.channel.id
                ) {
                    guard channel.id != live.channel.id else { return }
                    onClose()
                    let program = live.lineup.guide(for: channel)?.currentProgram()
                    Task {
                        await playback.playLiveTV(
                            channel: channel,
                            program: program,
                            lineup: live.lineup
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var speedRows: some View {
        ForEach(Self.speedOptions, id: \.self) { rate in
            panelRow(
                id: "speed.\(rate)",
                title: Self.speedTitle(rate),
                isSelected: abs(viewModel.playbackRate - rate) < 0.001
            ) {
                viewModel.setPlaybackRate(rate)
            }
        }
    }

    private static func speedTitle(_ rate: Float) -> String {
        rate == 1 ? "Normal" : String(format: "%g×", Double(rate))
    }

    // MARK: - Building blocks

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(DuskFont.TV.groupHeader)
            .foregroundStyle(Color.duskTextSecondary)
            .padding(.top, 18)
            .padding(.bottom, 2)
    }

    private func emptyRow(_ title: String) -> some View {
        Text(title)
            .font(DuskFont.TV.rowValue)
            .foregroundStyle(Color.duskTextSecondary)
            .padding(.vertical, 12)
    }

    private func panelRow(
        id: String,
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedRow == id

        return Button(action: action) {
            HStack(alignment: .center, spacing: 18) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(DuskFont.TV.glyphSmall)
                        .foregroundStyle(Color.duskTextSecondary)
                        .frame(width: 34)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DuskFont.TV.rowTitle)
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(1)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(DuskFont.TV.caption)
                            .foregroundStyle(Color.duskTextSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 20)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(DuskFont.TV.glyphSmall.weight(.bold))
                        .foregroundStyle(Color.duskAccent)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isFocused ? Color.duskSurface.opacity(0.96) : Color.duskSurface.opacity(0.55),
                in: RoundedRectangle(cornerRadius: PlayerTVHUDLayout.panelRowCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: PlayerTVHUDLayout.panelRowCornerRadius, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.duskAccent.opacity(0.45) : .white.opacity(0.04),
                        lineWidth: 1
                    )
            }
            .opacity(isDisabled ? 0.5 : 1)
        }
        .duskSuppressTVOSButtonChrome()
        .focusEffectDisabled()
        .focused($focusedRow, equals: id)
        .disabled(isDisabled)
    }
}
#endif
