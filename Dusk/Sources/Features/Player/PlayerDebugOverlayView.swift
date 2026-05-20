import SwiftUI

struct PlayerPlaybackInfoView: View {
    @Environment(\.dismiss) private var dismiss

    let debugInfo: PlaybackDebugInfo
    let state: PlaybackState
    let isBuffering: Bool

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
            PlaybackInfoEntry(label: "Resolution", value: debugInfo.resolutionLabel),
            PlaybackInfoEntry(label: "File", value: debugInfo.fileSizeLabel),
            PlaybackInfoEntry(label: "Subtitles", value: debugInfo.subtitleLabel),
            PlaybackInfoEntry(label: "State", value: stateLabel),
            PlaybackInfoEntry(label: "URL", value: debugInfo.urlLabel),
        ]
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
                .lineLimit(entry.label == "URL" || entry.label == "Resolver" ? 4 : 2)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.duskSurface)
    }
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
