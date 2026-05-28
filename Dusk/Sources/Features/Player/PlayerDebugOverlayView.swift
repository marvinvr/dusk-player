import SwiftUI

struct PlayerPlaybackInfoView: View {
    @Environment(\.dismiss) private var dismiss

    let debugInfo: PlaybackDebugInfo
    let state: PlaybackState
    let isBuffering: Bool
    let selectedAudioTrack: AudioTrack?
    let engineDiagnostics: [PlaybackEngineDiagnostic]

    var body: some View {
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

    private var infoEntries: [PlaybackInfoEntry] {
        [
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
            PlaybackInfoEntry(label: "File", value: debugInfo.fileSizeLabel),
            PlaybackInfoEntry(label: "Subtitles", value: debugInfo.subtitleLabel),
            PlaybackInfoEntry(label: "State", value: stateLabel),
            PlaybackInfoEntry(label: "URL", value: debugInfo.urlLabel),
        ] + engineDiagnostics.map {
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
        "Audio Route",
        "Selected Audio",
        "VLC Audio Track",
        "VLC Audio Output",
    ]
}

struct PlayerPlaybackInfoUnavailableView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
}

private struct PlaybackInfoEntry: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}
