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
        .disabled(isDeleting || (isStartingDownload && status == nil))
        .onChange(of: status) { _, newStatus in
            if newStatus != nil {
                isStartingDownload = false
            }
        }
        .contextMenu {
            if !isDeleting {
                if status == .queued || status == .preparing || status == .downloading {
                    Button {
                        downloadManager.pauseDownload(ratingKey: ratingKey, type: type)
                    } label: {
                        Label("Pause Download", systemImage: "pause")
                    }
                }

                if status == .paused {
                    Button {
                        downloadManager.resumeDownload(ratingKey: ratingKey, type: type)
                    } label: {
                        Label("Resume Download", systemImage: "play")
                    }
                }

                if status == .queued || status == .preparing || status == .downloading || status == .paused {
                    Button(role: .destructive) {
                        downloadManager.cancelDownload(ratingKey: ratingKey, type: type)
                    } label: {
                        Label("Cancel Download", systemImage: "xmark.circle")
                    }
                }

                if status == .completed || status == .failed || status == .cancelled || status == .paused {
                    Button(role: .destructive) {
                        downloadManager.deleteDownload(ratingKey: ratingKey)
                    } label: {
                        Label("Delete Download", systemImage: "trash")
                    }
                }

                if status == .failed {
                    Button {
                        downloadManager.retryDownload(ratingKey: ratingKey)
                    } label: {
                        Label("Retry Download", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var status: DownloadStatus? {
        downloadManager.status(for: ratingKey, type: type)
    }

    private var progress: Double {
        downloadManager.progress(for: ratingKey, type: type) ?? 0
    }

    private var isDeleting: Bool {
        downloadManager.isDeletingDownload(ratingKey: ratingKey, type: type)
    }

    @ViewBuilder
    private var icon: some View {
        if isDeleting || (isStartingDownload && status == nil) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.duskTextPrimary)
        } else {
            switch status {
            case .queued, .preparing:
                Image(systemName: "clock")
            case .downloading:
                CircularProgressView(progress: progress)
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
        if isDeleting {
            return "Deleting Download"
        }

        if isStartingDownload && status == nil {
            return "Starting Download"
        }

        return switch status {
        case .queued:
            "Queued"
        case .preparing:
            "Preparing"
        case .downloading:
            "\(Int((progress * 100).rounded()))%"
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
        if isDeleting {
            return Color.duskTextSecondary
        }

        return switch status {
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
        if isDeleting || (isStartingDownload && status == nil) {
            return
        } else if status == .queued || status == .preparing || status == .downloading {
            downloadManager.pauseDownload(ratingKey: ratingKey, type: type)
        } else if status == .paused {
            downloadManager.resumeDownload(ratingKey: ratingKey, type: type)
        } else if status == .failed {
            if type == .season || type == .show {
                startDownload()
            } else {
                downloadManager.retryDownload(ratingKey: ratingKey)
            }
        } else if status == .completed {
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
}
