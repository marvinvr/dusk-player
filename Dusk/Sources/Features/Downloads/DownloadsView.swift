import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager
    @Binding var path: NavigationPath
    @State private var isShowingQueue = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                VStack(spacing: 16) {
                    if offlinePlaybackSyncManager.pendingSyncCount > 0 {
                        pendingSyncBanner
                    }

                    if downloadedItems.isEmpty {
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
            }
            .sheet(isPresented: $isShowingQueue) {
                queueSheet
            }
            .duskAppNavigationDestinations()
        }
    }

    private var downloadedItems: [DownloadedLibraryItem] {
        let shows = downloadManager.downloadedShows.map(DownloadedLibraryItem.show)
        let movies = downloadManager.downloadedMovies.map(DownloadedLibraryItem.movie)
        return (shows + movies)
            .sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
    }

    private var downloadsGrid: some View {
        DownloadsPosterGrid(items: downloadedItems) { width, item in
            PosterNavigationCard(
                route: item.route,
                imageURL: downloadManager.localArtworkURL(for: item.imagePath),
                title: item.title,
                subtitle: item.subtitle,
                width: width
            ) {
                Button(role: .destructive) {
                    switch item {
                    case .movie(let record):
                        downloadManager.deleteDownload(ratingKey: record.ratingKey)
                    case .show(let show):
                        downloadManager.deleteDownloads(showKey: show.ratingKey)
                    }
                } label: {
                    Label("Delete Download", systemImage: "trash")
                }
            }   
        }
    }

    private var emptyDownloadsState: some View {
        Spacer()
            .overlay {
                FeatureEmptyStateView(
                    systemImage: "arrow.down.circle",
                    title: "No Downloads Yet",
                    message: downloadManager.queuedRecords.isEmpty
                        ? "Movies and shows saved for offline playback will appear here."
                        : "Your saved downloads will appear here once the queue finishes."
                )
                .padding(.horizontal, 32)
            }
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isShowingQueue = false
                    }
                    .foregroundStyle(Color.duskAccent)
                }
            }
            .duskAppNavigationDestinations()
        }
    }

    private var pendingSyncBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.duskAccent)

            Text("\(offlinePlaybackSyncManager.pendingSyncCount) watch progress update\(offlinePlaybackSyncManager.pendingSyncCount == 1 ? "" : "s") waiting to sync.")
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task {
                    await offlinePlaybackSyncManager.syncPendingActions()
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
                    DownloadQueueRow(record: record)
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var emptyQueueState: some View {
        Spacer()
            .overlay {
                FeatureEmptyStateView(
                    systemImage: "arrow.down.circle",
                    title: "Nothing Downloading",
                    message: "Active, paused, failed, and queued downloads will appear here."
                )
                .padding(.horizontal, 32)
            }
    }

    private var queueSummaryText: String {
        let records = downloadManager.queuedRecords
        let itemText = records.count == 1 ? "1 item" : "\(records.count) items"
        let activeText = downloadManager.activeDownloadCount == 1
            ? "1 active"
            : "\(downloadManager.activeDownloadCount) active"
        let totalBytes = records.compactMap(\.totalBytes).reduce(Int64(0), +)
        let downloadedBytes = records.reduce(Int64(0)) { $0 + $1.downloadedBytes }
        guard totalBytes > 0 else {
            return "\(itemText) · \(activeText)"
        }
        let remainingBytes = max(totalBytes - downloadedBytes, 0)
        return "\(itemText) · \(activeText) · \(formattedBytes(remainingBytes)) remaining"
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
}

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
            return .downloadedMedia(type: .movie, ratingKey: record.ratingKey)
        case .show(let show):
            return .downloadedMedia(type: .show, ratingKey: show.ratingKey)
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
                        .stroke(Color.duskAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 30, height: 30)
                }

                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isActive ? Color.duskAccent : Color.duskTextPrimary)
            }

            if queuedCount > 0 {
                Text("\(min(queuedCount, 99))")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.duskBackground)
                    .frame(minWidth: 16, minHeight: 16)
                    .padding(.horizontal, queuedCount > 9 ? 3 : 0)
                    .background(Color.duskAccent, in: Capsule())
                    .offset(x: 6, y: -6)
            }
        }
        .frame(width: 40, height: 40)
    }
}

private struct DownloadsPosterGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (CGFloat, Item) -> Content

    init(
        items: [Item],
        @ViewBuilder content: @escaping (CGFloat, Item) -> Content
    ) {
        self.items = items
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

    var body: some View {
        NavigationLink(value: AppNavigationRoute.media(type: record.type, ratingKey: record.ratingKey)) {
            HStack(spacing: 12) {
                PosterArtwork(
                    imageURL: downloadManager.localArtworkURL(for: record.thumbPath),
                    progress: record.status == .downloading ? record.progress : nil,
                    width: 72,
                    imageAspectRatio: record.type == .episode ? 16.0 / 9.0 : 2.0 / 3.0
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(record.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(2)

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)

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
        }
        .buttonStyle(.plain)
        .contextMenu {
            if record.status.canPause {
                Button {
                    downloadManager.pauseDownload(ratingKey: record.ratingKey)
                } label: {
                    Label("Pause Download", systemImage: "pause")
                }
            }

            if record.status == .paused {
                Button {
                    downloadManager.resumeDownload(ratingKey: record.ratingKey)
                } label: {
                    Label("Resume Download", systemImage: "play")
                }
            }

            if record.status == .failed {
                Button {
                    downloadManager.retryDownload(ratingKey: record.ratingKey)
                } label: {
                    Label("Retry Download", systemImage: "arrow.clockwise")
                }
            }

            if record.status == .queued || record.status == .preparing || record.status == .downloading || record.status == .paused {
                Button(role: .destructive) {
                    downloadManager.cancelDownload(ratingKey: record.ratingKey)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            }

            Button(role: .destructive) {
                downloadManager.deleteDownload(ratingKey: record.ratingKey)
            } label: {
                Label("Delete Download", systemImage: "trash")
            }
        }
    }

    private var statusText: String {
        switch record.status {
        case .queued:
            record.totalBytes.map { "Queued · \(formattedBytes($0))" } ?? "Queued"
        case .preparing:
            "Preparing"
        case .downloading:
            "\(Int((record.progress * 100).rounded()))% · \(downloadedSizeText)"
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

    private var statusColor: Color {
        record.status == .failed ? .red : Color.duskTextSecondary
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.status {
        case .downloading:
            CircularProgressView(progress: record.progress)
                .frame(width: 24, height: 24)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(Color.duskAccent)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        default:
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
}
