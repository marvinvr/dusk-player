import SwiftUI

struct DownloadActionButton: View {
    @Environment(DownloadManager.self) private var downloadManager
    @State private var isStartingDownload = false

    let ratingKey: String
    let type: PlexMediaType
    var fillsWidth = false

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 8) {
                icon
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, fillsWidth ? 0 : 18)
            .background(Color.duskSurface)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
            )
        }
        .duskSuppressTVOSButtonChrome()
        .duskTVOSFocusEffectShape(Capsule())
        .disabled(state.isDeleting || (isStartingDownload && state.status == nil))
        .onChange(of: state.status) { _, newStatus in
            if newStatus != nil {
                isStartingDownload = false
            }
        }
        .contextMenu {
            DownloadContextMenuContent(
                state: state,
                showsDelete: state.canDelete,
                onPause: { downloadManager.pauseDownload(scope: scope) },
                onResume: { downloadManager.resumeDownload(scope: scope) },
                onCancel: { downloadManager.cancelDownload(scope: scope) },
                onDelete: { downloadManager.deleteDownload(scope: scope) },
                onRetry: retry
            )
        }
    }

    private var scope: DownloadScope {
        DownloadScope(ratingKey: ratingKey, type: type)
    }

    private var state: DownloadControlState {
        downloadManager.downloadState(for: scope)
    }

    @ViewBuilder
    private var icon: some View {
        if state.isDeleting || (isStartingDownload && state.status == nil) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.duskTextPrimary)
        } else {
            switch state.status {
            case .queued, .preparing:
                Image(systemName: "clock")
            case .downloading:
                CircularProgressView(progress: state.progress)
                    .frame(width: 16, height: 16)
            case .paused:
                Image(systemName: "pause.circle")
            case .completed:
                Image(systemName: "checkmark.circle.fill")
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
            case .cancelled:
                Image(systemName: "arrow.down.circle")
            case nil:
                Image(systemName: "arrow.down.circle")
            }
        }
    }

    private var title: String {
        if state.isDeleting {
            return "Deleting Download"
        }

        if isStartingDownload && state.status == nil {
            return "Starting Download"
        }

        return switch state.status {
        case .queued:
            "Queued"
        case .preparing:
            "Preparing"
        case .downloading:
            "\(Int((state.progress * 100).rounded()))%"
        case .paused:
            "Resume Download"
        case .completed:
            "Downloaded"
        case .failed:
            "Retry Download"
        case .cancelled:
            "Download"
        case nil:
            downloadTitle
        }
    }

    private var downloadTitle: String {
        switch type {
        case .episode:
            "Download Episode"
        case .movie:
            "Download Movie"
        case .season:
            "Download Season"
        case .show:
            "Download Show"
        default:
            "Download"
        }
    }

    private var foreground: Color {
        if state.isDeleting {
            return Color.duskTextSecondary
        }

        return switch state.status {
        case .completed:
            Color.duskAccent
        case .paused:
            Color.duskAccent
        case .failed:
            .red
        default:
            Color.duskTextPrimary
        }
    }

    private func handleTap() {
        if state.isDeleting || (isStartingDownload && state.status == nil) {
            return
        } else if state.canPause {
            downloadManager.pauseDownload(scope: scope)
        } else if state.status == .paused {
            downloadManager.resumeDownload(scope: scope)
        } else if state.status == .failed {
            retry()
        } else if state.status == .completed {
            return
        } else {
            startDownload()
        }
    }

    private func startDownload() {
        isStartingDownload = true
        Task {
            await downloadManager.queueDownload(ratingKey: ratingKey, type: type)
            isStartingDownload = false
        }
    }

    private func retry() {
        if type == .season || type == .show {
            startDownload()
        } else {
            downloadManager.retryDownload(ratingKey: ratingKey)
        }
    }
}

struct DownloadContextMenuContent: View {
    let state: DownloadControlState
    var showsDelete: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onRetry: () -> Void

    var body: some View {
        if !state.isDeleting {
            if state.canPause {
                Button(action: onPause) {
                    Label("Pause Download", systemImage: "pause")
                }
            }

            if state.status == .paused {
                Button(action: onResume) {
                    Label("Resume Download", systemImage: "play")
                }
            }

            if state.status == .failed {
                Button(action: onRetry) {
                    Label("Retry Download", systemImage: "arrow.clockwise")
                }
            }

            if state.canCancel {
                Button(role: .destructive, action: onCancel) {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            }

            if showsDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Download", systemImage: "trash")
                }
            }
        }
    }
}
