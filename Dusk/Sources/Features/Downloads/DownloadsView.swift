import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

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
            .downloadQueueIdleTimerDisabled(downloadManager.activeDownloadCount > 0)
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

            Label("Your device will stay awake while this queue is open and downloads are active.", systemImage: "info.circle")
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

                Text("Start downloading a movie or episode and it will show up here with progress, pause, and retry controls.")
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

    var scope: DownloadScope {
        switch self {
        case .movie(let record):
            return DownloadScope(ratingKey: record.ratingKey, type: .movie)
        case .show(let show):
            return DownloadScope(ratingKey: show.ratingKey, type: .show)
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
                    .background(Color.duskAccent, in: Capsule())
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
        DownloadScope(ratingKey: record.ratingKey, type: record.type)
    }

    private var state: DownloadControlState {
        downloadManager.downloadState(for: scope)
    }

    var body: some View {
        Button {
            onOpen(.downloadedMedia(type: record.type, ratingKey: record.ratingKey))
        } label: {
            HStack(spacing: 12) {
                PosterArtwork(
                    imageURL: downloadManager.localArtworkURL(for: record.thumbPath),
                    progress: record.status == .downloading ? record.progress : nil,
                    width: 72,
                    imageAspectRatio: record.type == .episode ? 16.0 / 9.0 : 2.0 / 3.0,
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
                onRetry: { downloadManager.retryDownload(ratingKey: record.ratingKey) }
            )
        }
    }

    private var statusText: String {
        if state.isDeleting {
            return "Deleting"
        }

        return switch record.status {
        case .queued:
            record.totalBytes.map { "Queued · \(formattedBytes($0))" } ?? "Queued"
        case .preparing:
            "Preparing"
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
                .tint(Color.duskAccent)
        } else if record.status == .downloading {
            CircularProgressView(progress: record.progress)
                .frame(width: 24, height: 24)
        } else if record.status == .paused {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(Color.duskAccent)
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
