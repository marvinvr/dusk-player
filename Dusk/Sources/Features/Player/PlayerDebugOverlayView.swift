import SwiftUI

struct PlayerPlaybackInfoView: View {
    @Environment(\.dismiss) private var dismiss

    let debugInfo: PlaybackDebugInfo
    let state: PlaybackState
    let isBuffering: Bool
    let selectedAudioTrack: AudioTrack?
    let engineDiagnostics: [PlaybackEngineDiagnostic]
    let videoEnhancementStatus: VideoEnhancementStatus

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        iOSBody
        #endif
    }

    private var iOSBody: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(infoEntries) { entry in
                        playbackInfoRow(entry)
                    }
                } header: {
                    Text(debugInfo.title)
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
            .duskScrollContentBackgroundHidden()
            .background(Color.duskBackground)
            .duskNavigationTitle("Playback Info")
            .duskNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .duskSuppressTVOSButtonChrome()
                }
            }
        }
        .presentationBackground(Color.duskBackground)
    }

    #if os(tvOS)
    private var tvOSBody: some View {
        ZStack {
            Color.duskBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Playback Info")
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(Color.duskTextPrimary)

                        Text(debugInfo.title)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(Color.duskTextSecondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 32)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.duskTextPrimary)
                            .frame(width: 72, height: 72)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                            }
                    }
                    .duskSuppressTVOSButtonChrome()
                    .duskTVOSFocusEffectShape(Circle())
                    .accessibilityLabel("Close")
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(infoEntries) { entry in
                            tvOSPlaybackInfoRow(entry)
                        }
                    }
                    .padding(28)
                }
                .scrollIndicators(.visible)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
            }
            .padding(.horizontal, 96)
            .padding(.vertical, 64)
        }
        .onExitCommand {
            dismiss()
        }
    }

    private func tvOSPlaybackInfoRow(_ entry: PlaybackInfoEntry) -> some View {
        HStack(alignment: .top, spacing: 28) {
            Text(entry.label.uppercased())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.duskTextSecondary)
                .frame(width: 230, alignment: .leading)

            Text(entry.value)
                .font(.subheadline.monospaced())
                .foregroundStyle(Color.duskTextPrimary)
                .lineLimit(Self.extendedLineLabels.contains(entry.label) ? 5 : 2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.duskSurface.opacity(0.76), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    #endif

    private var infoEntries: [PlaybackInfoEntry] {
        var entries = [
            PlaybackInfoEntry(label: "Engine", value: debugInfo.engineLabel),
            PlaybackInfoEntry(label: "Mode", value: debugInfo.decisionLabel),
            PlaybackInfoEntry(label: "Attempt", value: debugInfo.attemptLabel),
            PlaybackInfoEntry(label: "Resolver", value: debugInfo.resolverLabel),
            PlaybackInfoEntry(label: "Transcode", value: debugInfo.transcodeLabel),
            PlaybackInfoEntry(label: "Container", value: debugInfo.containerLabel),
            PlaybackInfoEntry(label: "Bitrate", value: debugInfo.bitrateLabel),
            PlaybackInfoEntry(label: "Video", value: debugInfo.videoLabel),
            PlaybackInfoEntry(label: "Audio", value: debugInfo.audioLabel),
            PlaybackInfoEntry(label: "Selected Audio", value: selectedAudioTrackLabel),
            PlaybackInfoEntry(label: "Resolution", value: debugInfo.resolutionLabel),
            PlaybackInfoEntry(label: "Enhancement", value: videoEnhancementStatus.stateLabel),
        ]

        let enhancementDetail = videoEnhancementStatus.detailLabel
        if !enhancementDetail.isEmpty {
            entries.append(PlaybackInfoEntry(label: "Enhancement Detail", value: enhancementDetail))
        }

        entries += [
            PlaybackInfoEntry(label: "File", value: debugInfo.fileSizeLabel),
            PlaybackInfoEntry(label: "Subtitles", value: debugInfo.subtitleLabel),
            PlaybackInfoEntry(label: "State", value: stateLabel),
            PlaybackInfoEntry(label: "URL", value: debugInfo.urlLabel),
        ]

        return entries + engineDiagnostics.map {
            PlaybackInfoEntry(label: $0.label, value: $0.value)
        }
    }

    private var selectedAudioTrackLabel: String {
        guard let selectedAudioTrack else { return "Unknown" }

        var details: [String] = [selectedAudioTrack.compactDisplayTitle]
        if let codec = selectedAudioTrack.codec, !codec.isEmpty {
            details.append(codec.uppercased())
        }
        if let channels = selectedAudioTrack.channels {
            details.append("\(channels)ch")
        }
        if let layout = selectedAudioTrack.channelLayout, !layout.isEmpty {
            details.append(layout)
        }

        return details.joined(separator: " / ")
    }

    private var stateLabel: String {
        let stateText: String
        switch state {
        case .idle:
            stateText = "Idle"
        case .loading:
            stateText = "Loading"
        case .playing:
            stateText = "Playing"
        case .paused:
            stateText = "Paused"
        case .stopped:
            stateText = "Stopped"
        case .error:
            stateText = "Error"
        }

        return isBuffering ? "\(stateText) / Buffering" : stateText
    }

    private func playbackInfoRow(_ entry: PlaybackInfoEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.duskTextSecondary)

            Text(entry.value)
                .font(.caption.monospaced())
                .foregroundStyle(Color.duskTextPrimary)
                .lineLimit(Self.extendedLineLabels.contains(entry.label) ? 4 : 2)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.duskSurface)
    }

    private static let extendedLineLabels: Set<String> = [
        "URL",
        "Resolver",
        "Enhancement Detail",
        "Audio Route",
        "Selected Audio",
        "VLC Audio Track",
        "VLC Audio Output",
    ]
}

struct PlayerPlaybackInfoUnavailableView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        iOSBody
        #endif
    }

    private var iOSBody: some View {
        NavigationStack {
            ContentUnavailableView(
                "Playback Info Unavailable",
                systemImage: "info.circle",
                description: Text("No playback statistics are available for this session.")
            )
            .foregroundStyle(Color.duskTextSecondary)
            .background(Color.duskBackground)
            .duskNavigationTitle("Playback Info")
            .duskNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .duskSuppressTVOSButtonChrome()
                }
            }
        }
        .presentationBackground(Color.duskBackground)
    }

    #if os(tvOS)
    private var tvOSBody: some View {
        ZStack {
            Color.duskBackground
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "info.circle")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(Color.duskTextSecondary)

                Text("Playback Info Unavailable")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.duskTextPrimary)

                Text("No playback statistics are available for this session.")
                    .font(.body)
                    .foregroundStyle(Color.duskTextSecondary)
                    .multilineTextAlignment(.center)

                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .font(.headline)
                        .foregroundStyle(Color.duskTextPrimary)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(Capsule())
                .padding(.top, 12)
            }
            .padding(42)
            .frame(width: 620)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
        }
        .onExitCommand {
            dismiss()
        }
    }
    #endif
}

private struct PlaybackInfoEntry: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}
