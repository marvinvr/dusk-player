import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(iOS)
#if canImport(UIKit)
import UIKit
#endif
#endif

struct DownloadsView: View {
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            DownloadsRootContent(path: $path)
                .duskAppNavigationDestinations()
        }
    }
}

/// The downloads screen without its own `NavigationStack`, usable both as the
/// Downloads tab's root and as a destination pushed from the More tab. `path`
/// is the enclosing stack's path, used to push routes from the queue sheet.
struct DownloadsRootContent: View {
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager
    @Binding var path: NavigationPath
    @State private var isShowingQueue = false

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(macOS)
    /// The Mac's Downloads: one list, the queue (with progress) above the
    /// saved titles, size and state per row, hover and context actions.
    /// Replaces the iOS poster grid and the queue sheet.
    private var macBody: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if downloadedItems.isEmpty, downloadManager.queuedRecords.isEmpty {
                emptyDownloadsState
            } else {
                MacDownloadsList(
                    queued: downloadManager.queuedRecords,
                    downloaded: downloadedItems,
                    pendingSyncBanner: offlinePlaybackSyncManager.pendingSyncCount > 0 ? AnyView(pendingSyncBanner) : nil,
                    open: { path.append($0) }
                )
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            if !downloadManager.queuedRecords.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    if downloadManager.queuedRecords.contains(where: { $0.status.canPause }) {
                        Button {
                            downloadManager.pauseAllDownloads()
                        } label: {
                            Label("Pause All", systemImage: "pause")
                        }
                        .help("Pause All Downloads")
                    } else {
                        Button {
                            downloadManager.resumeAllDownloads()
                        } label: {
                            Label("Resume All", systemImage: "play")
                        }
                        .help("Resume All Downloads")
                        .disabled(!downloadManager.queuedRecords.contains { $0.status == .paused })
                    }
                }
            }
        }
    }
    #endif

    private var iosBody: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                if downloadedItems.isEmpty {
                    if offlinePlaybackSyncManager.pendingSyncCount > 0 {
                        pendingSyncBanner
                    }

                    emptyDownloadsState
                } else {
                    downloadsGrid
                }
            }
            .padding(.top, 12)
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                #if os(iOS)
                if DuskDuoDisplay.isActive {
                    // iPhone Duo's vertical bar only takes standard bar
                    // buttons; the custom progress-ring view floated over the
                    // content instead.
                    Button {
                        isShowingQueue = true
                    } label: {
                        Image(systemName: "arrow.down")
                            .foregroundStyle(Color.primary)
                    }
                    .tint(Color.primary)
                    .badge(downloadManager.queuedRecords.count)
                    .accessibilityLabel("Open download queue")
                } else {
                    queueToolbarButton
                }
                #else
                queueToolbarButton
                #endif
            }
        }
        .sheet(isPresented: $isShowingQueue) {
            queueSheet
        }
    }

    private var queueToolbarButton: some View {
        Button {
            isShowingQueue = true
        } label: {
            DownloadQueueToolbarButton(
                progress: aggregateQueueProgress,
                queuedCount: downloadManager.queuedRecords.count,
                isActive: downloadManager.activeDownloadCount > 0
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open download queue")
    }

    private var downloadedItems: [DownloadedLibraryItem] {
        let shows = downloadManager.downloadedShows.map(DownloadedLibraryItem.show)
        let movies = downloadManager.downloadedMovies.map(DownloadedLibraryItem.movie)
        return (shows + movies)
            .sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
    }

    private var downloadsGrid: some View {
        DownloadsPosterGrid(
            items: downloadedItems,
            header: offlinePlaybackSyncManager.pendingSyncCount > 0 ? AnyView(pendingSyncBanner) : nil
        ) { width, item in
            let state = downloadManager.downloadState(for: item.scope)

            PosterNavigationCard(
                route: item.route,
                imageURL: downloadManager.localArtworkURL(for: item.imagePath),
                title: item.title,
                subtitle: item.subtitle,
                width: width,
                imageAspectRatio: item.imageAspectRatio,
                availabilityBadge: state.isDeleting ? "Deleting" : nil,
                isDimmed: state.isDeleting
            ) {
                if !state.isDeleting {
                    Button(role: .destructive) {
                        downloadManager.deleteDownload(scope: item.scope)
                    } label: {
                        Label("Delete Download", systemImage: "trash")
                    }
                }
            }
            .disabled(state.isDeleting)
        }
    }

    /// A frame, not `Spacer().overlay`: a lone Spacer in the VStack has no
    /// width, so the overlay laid the title and message out 0pt wide and only
    /// the icon showed.
    private var emptyDownloadsState: some View {
        FeatureEmptyStateView(
            systemImage: "arrow.down.circle",
            title: "No Downloads Yet",
            message: downloadManager.queuedRecords.isEmpty
                ? "Movies, shows, and videos saved for offline playback will appear here."
                : "Your saved downloads will appear here once the queue finishes."
        )
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueSheet: some View {
        NavigationStack {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                VStack(spacing: 16) {
                    if downloadManager.queuedRecords.isEmpty {
                        emptyQueueState
                    } else {
                        queueControls
                        queueList
                    }
                }
            }
            .navigationTitle("Download Queue")
            .duskNavigationBarTitleDisplayModeInline()
            .downloadQueueIdleTimerDisabled(downloadManager.activeDownloadCount > 0)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isShowingQueue = false
                    }
                }
            }
            .duskAppNavigationDestinations()
        }
        #if os(macOS)
        .macUISheetSize()
        #endif
    }

    private var pendingSyncBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.duskTextSecondary)

            Text("\(offlinePlaybackSyncManager.pendingSyncCount) watch progress update\(offlinePlaybackSyncManager.pendingSyncCount == 1 ? "" : "s") waiting to sync.")
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task {
                    await offlinePlaybackSyncManager.syncPendingActions(force: true)
                }
            } label: {
                Text(offlinePlaybackSyncManager.isSyncing ? "Syncing" : "Sync")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.duskTextPrimary)
            }
            .disabled(offlinePlaybackSyncManager.isSyncing)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
    }

    private var queueList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(downloadManager.queuedRecords) { record in
                    DownloadQueueRow(record: record) { route in
                        isShowingQueue = false
                        path.append(route)
                    }
                        .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 40)
        }
    }

    private var queueControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(queueSummaryText)
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)

            HStack(spacing: 10) {
                Button {
                    downloadManager.pauseAllDownloads()
                } label: {
                    Label("Pause All", systemImage: "pause.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .disabled(!downloadManager.queuedRecords.contains { $0.status.canPause })
                .background(Color.duskSurface, in: Capsule())

                Button {
                    downloadManager.resumeAllDownloads()
                } label: {
                    Label("Resume All", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .disabled(!downloadManager.queuedRecords.contains { $0.status == .paused })
                .background(Color.duskSurface, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.duskTextPrimary)

            Label(queueActivityHint, systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(Color.duskTextSecondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var queueActivityHint: String {
        let hasPendingConversion = downloadManager.queuedRecords.contains {
            $0.downloadQuality != .original && ($0.status == .queued || $0.status == .preparing)
        }
        if hasPendingConversion {
            return "Keep Dusk open while Plex prepares converted downloads. Your device stays awake while this queue is open."
        }
        return "Your device will stay awake while this queue is open and downloads are active."
    }

    private var emptyQueueState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.duskTextSecondary)
                .frame(width: 72, height: 72)
                .background(Color.duskSurface, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                )

            VStack(spacing: 6) {
                Text("No Downloads Queued")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.duskTextPrimary)

                Text("Start downloading a movie, episode, or video and it will show up here with progress, pause, and retry controls.")
                    .font(.subheadline)
                    .foregroundStyle(Color.duskTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 96)
    }

    private var queueSummaryText: String {
        let records = downloadManager.queuedRecords
        let itemText = records.count == 1 ? "1 item" : "\(records.count) items"
        let activeText = downloadManager.activeDownloadCount == 1
            ? "1 active"
            : "\(downloadManager.activeDownloadCount) active"
        let totalBytes = records.compactMap(\.totalBytes).reduce(Int64(0), +)
        let downloadedBytes = records.reduce(Int64(0)) { $0 + $1.downloadedBytes }
        var parts = [
            itemText,
            activeText
        ]
        if totalBytes > 0 {
            let remainingBytes = max(totalBytes - downloadedBytes, 0)
            parts.append("\(formattedBytes(remainingBytes)) remaining")
        }
        if let bytesPerSecond = downloadManager.queueDownloadSpeedBytesPerSecond {
            parts.append(formattedTransferRate(bytesPerSecond))
        }
        if let timeRemaining = downloadManager.estimatedQueueTimeRemaining {
            parts.append("\(formattedRemainingTime(timeRemaining)) left")
        }
        return parts.joined(separator: " · ")
    }

    private var aggregateQueueProgress: Double? {
        let records = downloadManager.queuedRecords
        guard !records.isEmpty else { return nil }
        let totalBytes = records.compactMap(\.totalBytes).reduce(Int64(0), +)
        guard totalBytes > 0 else { return 0 }
        let downloadedBytes = records.reduce(Int64(0)) { $0 + $1.downloadedBytes }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func formattedRemainingTime(_ value: TimeInterval) -> String {
        DownloadTimeRemainingFormatter.string(from: value)
    }

    private func formattedTransferRate(_ value: Double) -> String {
        DownloadTransferRateFormatter.string(from: value)
    }
}

#if os(macOS)
/// The Mac's Downloads list. Rows open the title; hover shows Show in Finder
/// and Remove, the context menu has the same plus the queue controls.
private struct MacDownloadsList: View {
    @Environment(DownloadManager.self) private var downloadManager

    let queued: [DownloadedMediaRecord]
    let downloaded: [DownloadedLibraryItem]
    let pendingSyncBanner: AnyView?
    let open: (AppNavigationRoute) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacUILayout.sectionSpacing) {
                if let pendingSyncBanner {
                    pendingSyncBanner
                        // The banner brings its own 20pt iOS inset.
                        .padding(.horizontal, -20)
                }

                if !queued.isEmpty {
                    section("Downloading") {
                        ForEach(queued) { record in
                            MacDownloadQueueRow(record: record, open: open)
                        }
                    }
                }

                if !downloaded.isEmpty {
                    section(queued.isEmpty ? nil : "Downloaded") {
                        ForEach(downloaded) { item in
                            MacDownloadedRow(item: item, open: open)
                        }
                    }
                }
            }
            .padding(.horizontal, MacUILayout.contentInset)
            .padding(.vertical, MacUILayout.contentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Rows: View>(_ title: String?, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            VStack(spacing: 0) {
                rows()
            }
        }
    }
}

/// Thumbnail, title and subtitle: the leading part of every Downloads row.
private struct MacDownloadRowLabel: View {
    let imageURL: URL?
    let aspectRatio: CGFloat
    let title: String
    let subtitle: String?
    var progress: Double? = nil

    var body: some View {
        HStack(spacing: 12) {
            PosterArtwork(
                imageURL: imageURL,
                progress: progress,
                width: aspectRatio < 1 ? 36 : 80,
                imageAspectRatio: aspectRatio,
                cornerRadius: 4
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// A row's hover highlight and click target, list-style.
private struct MacDownloadRowChrome<Label: View, Trailing: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @ViewBuilder let trailing: (Bool) -> Trailing

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trailing(isHovered)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear))
        )
        .onHover { isHovered = $0 }
    }
}

private struct MacDownloadedRow: View {
    @Environment(DownloadManager.self) private var downloadManager

    let item: DownloadedLibraryItem
    let open: (AppNavigationRoute) -> Void

    var body: some View {
        let state = downloadManager.downloadState(for: item.scope)

        MacDownloadRowChrome {
            open(item.route)
        } label: {
            MacDownloadRowLabel(
                imageURL: downloadManager.localArtworkURL(for: item.imagePath),
                aspectRatio: item.imageAspectRatio,
                title: item.title,
                subtitle: item.subtitle
            )
        } trailing: { isHovered in
            HStack(spacing: 14) {
                if isHovered, !state.isDeleting {
                    HStack(spacing: 4) {
                        if !fileURLs.isEmpty {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .help("Show in Finder")
                        }
                        Button {
                            downloadManager.deleteDownload(scope: item.scope)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Remove Download")
                    }
                    .buttonStyle(.borderless)
                }

                Text(sizeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)

                Group {
                    if state.isDeleting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20)
                .help(state.isDeleting ? "Removing" : "Downloaded")
            }
        }
        .opacity(state.isDeleting ? 0.5 : 1)
        .disabled(state.isDeleting)
        .contextMenu {
            if !state.isDeleting {
                Button("Open") { open(item.route) }
                if !fileURLs.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
                    }
                }
                Divider()
                Button("Remove Download", role: .destructive) {
                    downloadManager.deleteDownload(scope: item.scope)
                }
            }
        }
    }

    private var records: [DownloadedMediaRecord] {
        switch item {
        case .movie(let record):
            return [record]
        case .show(let show):
            return downloadManager.downloadedEpisodes.filter {
                $0.serverID == show.serverID
                    && ($0.grandparentRatingKey ?? $0.parentRatingKey ?? $0.ratingKey) == show.ratingKey
            }
        }
    }

    private var fileURLs: [URL] {
        records.compactMap { downloadManager.localPlaybackURL(for: $0.itemID) }
    }

    private var sizeText: String {
        let bytes = records.reduce(Int64(0)) { $0 + ($1.totalBytes ?? $1.downloadedBytes) }
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct MacDownloadQueueRow: View {
    @Environment(DownloadManager.self) private var downloadManager

    let record: DownloadedMediaRecord
    let open: (AppNavigationRoute) -> Void

    private var scope: DownloadScope {
        DownloadScope(id: record.itemID, type: record.type)
    }

    var body: some View {
        let state = downloadManager.downloadState(for: scope)

        MacDownloadRowChrome {
            open(record.isClip ? .downloadedVideo(id: record.itemID) : .downloadedMedia(type: record.type, id: record.itemID))
        } label: {
            MacDownloadRowLabel(
                imageURL: downloadManager.localArtworkURL(for: record.thumbPath),
                aspectRatio: record.type == .episode || record.isClip ? 16.0 / 9.0 : 2.0 / 3.0,
                title: record.displayTitle,
                subtitle: statusText(state)
            )
        } trailing: { isHovered in
            HStack(spacing: 14) {
                if isHovered, !state.isDeleting {
                    HStack(spacing: 4) {
                        if state.canPause {
                            Button { downloadManager.pauseDownload(scope: scope) } label: {
                                Image(systemName: "pause")
                            }
                            .help("Pause Download")
                        } else if state.status == .paused {
                            Button { downloadManager.resumeDownload(scope: scope) } label: {
                                Image(systemName: "play")
                            }
                            .help("Resume Download")
                        } else if state.status == .failed {
                            Button { downloadManager.retryDownload(id: record.itemID) } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("Retry Download")
                        }
                        if state.canCancel {
                            Button { downloadManager.cancelDownload(scope: scope) } label: {
                                Image(systemName: "xmark")
                            }
                            .help("Cancel Download")
                        }
                    }
                    .buttonStyle(.borderless)
                }

                Group {
                    if record.status == .downloading {
                        ProgressView(value: record.progress)
                    } else if record.status == .preparing, let progress = record.preparationProgress {
                        ProgressView(value: progress)
                    } else if record.status == .failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 120)
            }
        }
        .contextMenu {
            DownloadContextMenuContent(
                state: state,
                showsDelete: false,
                showsCancel: state.canCancel,
                onPause: { downloadManager.pauseDownload(scope: scope) },
                onResume: { downloadManager.resumeDownload(scope: scope) },
                onCancel: { downloadManager.cancelDownload(scope: scope) },
                onDelete: { downloadManager.deleteDownload(scope: scope) },
                onRetry: { downloadManager.retryDownload(id: record.itemID) }
            )
        }
    }

    private func statusText(_ state: DownloadControlState) -> String {
        if state.isDeleting { return "Removing" }
        if let waitReason = downloadManager.queueWaitReason(for: record) { return waitReason }
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        switch record.status {
        case .queued:
            return record.totalBytes.map { "Queued · \(size($0))" } ?? "Queued"
        case .preparing:
            return record.downloadQuality == .original ? "Preparing" : "Preparing on Plex"
        case .downloading:
            var parts = ["\(Int((record.progress * 100).rounded()))%"]
            if let total = record.totalBytes, total > 0 {
                parts.append("\(size(record.downloadedBytes)) of \(size(total))")
            }
            if let remaining = downloadManager.estimatedTimeRemaining(for: record) {
                parts.append("\(DownloadTimeRemainingFormatter.string(from: remaining)) left")
            }
            return parts.joined(separator: " · ")
        case .paused:
            return "Paused"
        case .completed:
            return "Downloaded"
        case .failed:
            return record.errorMessage ?? "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}
#endif

private enum DownloadedLibraryItem: Identifiable {
    case movie(DownloadedMediaRecord)
    case show(DownloadedShowSummary)

    var id: String {
        switch self {
        case .movie(let record):
            return record.id
        case .show(let show):
            return show.id
        }
    }

    var title: String {
        switch self {
        case .movie(let record):
            return record.title
        case .show(let show):
            return show.title
        }
    }

    var subtitle: String? {
        switch self {
        case .movie(let record):
            return record.subtitle
        case .show(let show):
            return show.subtitle
        }
    }

    var imagePath: String? {
        switch self {
        case .movie(let record):
            return record.thumbPath
        case .show(let show):
            return show.thumbPath
        }
    }

    var route: AppNavigationRoute {
        switch self {
        case .movie(let record):
            let id = record.itemID
            return record.isClip
                ? .downloadedVideo(id: id)
                : .downloadedMedia(type: .movie, id: id)
        case .show(let show):
            return .downloadedMedia(
                type: .show,
                id: show.itemID
            )
        }
    }

    /// Clip artwork is a 16:9 frame grab; everything else stays 2:3.
    var imageAspectRatio: CGFloat {
        switch self {
        case .movie(let record):
            return record.isClip ? 16.0 / 9.0 : 2.0 / 3.0
        case .show:
            return 2.0 / 3.0
        }
    }

    var scope: DownloadScope {
        switch self {
        case .movie(let record):
            return DownloadScope(id: record.itemID, type: record.type)
        case .show(let show):
            return DownloadScope(id: show.itemID, type: .show)
        }
    }

    var sortTitle: String {
        title
    }
}

private struct DownloadQueueToolbarButton: View {
    let progress: Double?
    let queuedCount: Int
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if let progress, isActive {
                    Circle()
                        .stroke(Color.duskTextSecondary.opacity(0.15), lineWidth: 2.5)
                        .frame(width: 30, height: 30)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.duskTextPrimary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 30, height: 30)
                }

                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.duskTextPrimary)
            }
            .frame(width: 34, height: 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            if queuedCount > 0 {
                Text(badgeText)
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.duskBackground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: badgeWidth, height: 18)
                    .background(Color.duskTextPrimary, in: Capsule())
                    .padding(.top, 5)
                    .padding(.trailing, 3)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var badgeText: String {
        "\(min(queuedCount, 99))"
    }

    private var badgeWidth: CGFloat {
        min(queuedCount, 99) > 9 ? 22 : 18
    }
}

private struct DownloadsPosterGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let header: AnyView?
    @ViewBuilder let content: (CGFloat, Item) -> Content

    init(
        items: [Item],
        header: AnyView? = nil,
        @ViewBuilder content: @escaping (CGFloat, Item) -> Content
    ) {
        self.items = items
        self.header = header
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = AdaptivePosterGridLayout.make(
                containerWidth: geometry.size.width,
                horizontalPadding: DuskPosterMetrics.detailHorizontalPadding,
                gridSpacing: DuskPosterMetrics.detailGridSpacing,
                preferredPosterWidth: DuskPosterMetrics.detailGridPreferredWidth,
                minimumColumnCount: 2
            )

            ScrollView {
                if let header {
                    header
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }

                LazyVGrid(columns: layout.columns, alignment: .leading, spacing: DuskPosterMetrics.detailGridRowSpacing) {
                    ForEach(items) { item in
                        content(layout.posterWidth, item)
                    }
                }
                .padding(.horizontal, DuskPosterMetrics.detailHorizontalPadding)
                .padding(.bottom, 40)
            }
        }
    }
}

private struct DownloadQueueRow: View {
    @Environment(DownloadManager.self) private var downloadManager

    let record: DownloadedMediaRecord
    let onOpen: (AppNavigationRoute) -> Void

    private var scope: DownloadScope {
        DownloadScope(id: record.itemID, type: record.type)
    }

    private var state: DownloadControlState {
        downloadManager.downloadState(for: scope)
    }

    var body: some View {
        Button {
            let id = PlexItemID(serverID: record.serverID, ratingKey: record.ratingKey)
            onOpen(
                record.isClip
                    ? .downloadedVideo(id: id)
                    : .downloadedMedia(type: record.type, id: id)
            )
        } label: {
            HStack(spacing: 12) {
                PosterArtwork(
                    imageURL: downloadManager.localArtworkURL(for: record.thumbPath),
                    progress: record.status == .downloading ? record.progress : nil,
                    width: 72,
                    imageAspectRatio: record.type == .episode || record.isClip ? 16.0 / 9.0 : 2.0 / 3.0,
                    cornerRadius: 8
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(record.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(2)

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)

                    if record.downloadQuality != .original {
                        Text(record.downloadQuality.displayName)
                            .font(.caption2)
                            .foregroundStyle(Color.duskTextSecondary)
                    }

                    if let error = record.errorMessage, record.status == .failed {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(Color.duskTextSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                statusIcon
            }
            .padding(12)
            .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(state.isDeleting ? 0.65 : 1)
        }
        .buttonStyle(.plain)
        .disabled(state.isDeleting)
        .contextMenu {
            DownloadContextMenuContent(
                state: state,
                showsDelete: false,
                showsCancel: state.canCancel,
                onPause: { downloadManager.pauseDownload(scope: scope) },
                onResume: { downloadManager.resumeDownload(scope: scope) },
                onCancel: { downloadManager.cancelDownload(scope: scope) },
                onDelete: { downloadManager.deleteDownload(scope: scope) },
                onRetry: { downloadManager.retryDownload(id: record.itemID) }
            )
        }
    }

    private var statusText: String {
        if state.isDeleting {
            return "Deleting"
        }

        // A queued download whose server is off or unreachable would otherwise
        // sit at "Queued" with no hint that nothing is going to happen.
        if let waitReason = downloadManager.queueWaitReason(for: record) {
            return record.totalBytes.map { "\(waitReason) · \(formattedBytes($0))" } ?? waitReason
        }

        return switch record.status {
        case .queued:
            record.totalBytes.map { "Queued · \(formattedBytes($0))" } ?? "Queued"
        case .preparing:
            preparationStatusText
        case .downloading:
            downloadingStatusText
        case .paused:
            "Paused · \(downloadedSizeText)"
        case .completed:
            "Downloaded"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }

    private var preparationStatusText: String {
        guard record.downloadQuality != .original else { return "Preparing" }
        guard let progress = record.preparationProgress else { return "Preparing on Plex" }
        return "Preparing on Plex · \(Int((progress * 100).rounded()))%"
    }

    private var statusColor: Color {
        if state.isDeleting {
            return Color.duskTextSecondary
        }

        return record.status == .failed ? .red : Color.duskTextSecondary
    }

    @ViewBuilder
    private var statusIcon: some View {
        if state.isDeleting {
            ProgressView()
                .controlSize(.small)
        } else if record.status == .preparing {
            if let progress = record.preparationProgress {
                CircularProgressView(progress: progress)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Preparing on Plex")
                    .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        } else if record.status == .downloading {
            CircularProgressView(progress: record.progress)
                .frame(width: 24, height: 24)
        } else if record.status == .paused {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(Color.duskTextSecondary)
        } else if record.status == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else {
            Image(systemName: record.status == .queued ? "clock" : "arrow.down.circle")
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private var downloadedSizeText: String {
        guard let totalBytes = record.totalBytes, totalBytes > 0 else {
            return formattedBytes(record.downloadedBytes)
        }
        return "\(formattedBytes(record.downloadedBytes)) of \(formattedBytes(totalBytes))"
    }

    private var downloadingStatusText: String {
        var parts = [
            "\(Int((record.progress * 100).rounded()))%",
            downloadedSizeText
        ]
        if let bytesPerSecond = downloadManager.downloadSpeedBytesPerSecond(for: record) {
            parts.append(DownloadTransferRateFormatter.string(from: bytesPerSecond))
        }
        if let timeRemaining = downloadManager.estimatedTimeRemaining(for: record) {
            parts.append("\(DownloadTimeRemainingFormatter.string(from: timeRemaining)) left")
        }
        return parts.joined(separator: " · ")
    }
}

private enum DownloadTransferRateFormatter {
    static func string(from bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        guard value > 0 else { return "0 KB/s" }

        if value < 1_000_000 {
            let kilobytes = value / 1_000
            return "\(formatted(kilobytes, maximumFractionDigits: kilobytes < 10 ? 1 : 0)) KB/s"
        }

        let megabytes = value / 1_000_000
        return "\(formatted(megabytes, maximumFractionDigits: megabytes < 10 ? 1 : 0)) MB/s"
    }

    private static func formatted(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value.rounded()))"
    }
}

private enum DownloadTimeRemainingFormatter {
    static func string(from value: TimeInterval) -> String {
        let roundedSeconds = roundedDisplaySeconds(for: max(value, 0))
        guard roundedSeconds >= 60 else {
            return "Under 1 min"
        }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = roundedSeconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated

        return formatter.string(from: TimeInterval(roundedSeconds)) ?? "Calculating"
    }

    private static func roundedDisplaySeconds(for value: TimeInterval) -> Int {
        let seconds = Int(value.rounded(.up))
        if seconds < 60 {
            return seconds
        }
        if seconds < 3600 {
            return Int(ceil(Double(seconds) / 60.0) * 60)
        }
        return Int(ceil(Double(seconds) / 300.0) * 300)
    }
}

private extension View {
    @ViewBuilder
    func downloadQueueIdleTimerDisabled(_ isDisabled: Bool) -> some View {
        #if os(iOS)
        modifier(DownloadQueueIdleTimerModifier(isDisabled: isDisabled))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct DownloadQueueIdleTimerModifier: ViewModifier {
    let isDisabled: Bool
    @State private var previousIdleTimerDisabled: Bool?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: updateIdleTimer)
            .onChange(of: isDisabled) { _, _ in
                updateIdleTimer()
            }
            .onDisappear(perform: restoreIdleTimer)
    }

    private func updateIdleTimer() {
        if isDisabled {
            if previousIdleTimerDisabled == nil {
                previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            }
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            restoreIdleTimer()
        }
    }

    private func restoreIdleTimer() {
        guard let previousIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        self.previousIdleTimerDisabled = nil
    }
}
#endif
