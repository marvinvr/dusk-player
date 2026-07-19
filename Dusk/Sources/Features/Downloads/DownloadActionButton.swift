import SwiftUI

enum DownloadsFeature {
    static var isVisible: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }
}

struct DownloadActionButton: View {
    @Environment(DownloadManager.self) private var downloadManager
    @State private var isStartingDownload = false
    @State private var isShowingDeleteConfirmation = false

    let ratingKey: String
    let type: PlexMediaType
    /// True for video clips (Plex `type == "movie"` + `subtype == "clip"`), so
    /// the queued download record carries the flag for 16:9 artwork and
    /// `.downloadedVideo` routing.
    var isClip = false
    var fillsWidth = false
    /// Icon-only rendering for the iOS detail hero secondary row (the state icon
    /// already conveys download status, so the text label is dropped).
    var iconOnly = false

    @ViewBuilder
    var body: some View {
        if DownloadsFeature.isVisible {
            Button {
                handleTap()
            } label: {
                Group {
                    if iconOnly {
                        icon
                            .frame(minWidth: 24, minHeight: 32)
                    } else {
                        HStack(spacing: 8) {
                            icon
                            Text(title)
                        }
                        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 32)
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(foreground)
                .contentShape(Capsule())
            }
            .detailHeroNativeSecondaryButtonStyle()
            .accessibilityLabel(title)
            .disabled(state.isDeleting || (isStartingDownload && state.status == nil))
            .alert(deleteConfirmationTitle, isPresented: $isShowingDeleteConfirmation) {
                Button("No", role: .cancel) {}
                Button("Yes, Delete", role: .destructive) {
                    downloadManager.deleteDownload(scope: scope)
                }
            } message: {
                Text(deleteConfirmationMessage)
            }
            .onChange(of: state.status) { _, newStatus in
                if newStatus != nil {
                    isStartingDownload = false
                }
            }
            .contextMenu {
                DownloadContextMenuContent(
                    state: state,
                    showsDelete: state.canDelete,
                    showsCancel: state.canCancel,
                    onPause: { downloadManager.pauseDownload(scope: scope) },
                    onResume: { downloadManager.resumeDownload(scope: scope) },
                    onCancel: { downloadManager.cancelDownload(scope: scope) },
                    onDelete: { downloadManager.deleteDownload(scope: scope) },
                    onRetry: retry
                )
            }
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
                .tint(Color.primary)
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
            "Download"
        case .movie:
            "Download"
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
            Color.primary
        case .paused:
            Color.primary
        case .failed:
            .red
        default:
            Color.primary
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
            isShowingDeleteConfirmation = true
        } else {
            startDownload()
        }
    }

    private var deleteConfirmationTitle: String {
        if isClip {
            return "Delete Video Download?"
        }

        return switch type {
        case .episode:
            "Delete Episode Download?"
        case .movie:
            "Delete Movie Download?"
        case .season:
            "Delete Season Downloads?"
        case .show:
            "Delete Show Downloads?"
        default:
            "Delete Download?"
        }
    }

    private var deleteConfirmationMessage: String {
        if isClip {
            return "Remove this video from this device?"
        }

        return switch type {
        case .episode:
            "Remove this episode from this device?"
        case .movie:
            "Remove this movie from this device?"
        case .season:
            "Remove the downloaded episodes in this season from this device?"
        case .show:
            "Remove the downloaded episodes in this show from this device?"
        default:
            "Remove this download from this device?"
        }
    }

    private func startDownload() {
        isStartingDownload = true
        Task {
            await downloadManager.queueDownload(ratingKey: ratingKey, type: type, isClip: isClip)
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
    var showsCancel: Bool
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

            if showsCancel {
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
