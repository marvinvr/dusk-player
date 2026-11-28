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
    @State private var isShowingQualitySelection = false
    @State private var isShowingSmartOptions = false

    /// Server-scoped identity of the item the button acts on. Rating keys
    /// collide across servers, so the download record must be found by both.
    let id: MediaItemID
    let type: MediaKind
    /// True for video clips (Plex `type == "movie"` + `subtype == "clip"`), so
    /// the queued download record carries the flag for 16:9 artwork and
    /// `.downloadedVideo` routing.
    var isClip = false
    var fillsWidth = false
    /// Icon-only rendering for the iOS detail hero secondary row (the state icon
    /// already conveys download status, so the text label is dropped).
    var iconOnly = false

    #if os(macOS)
    @Environment(\.detailHeroMacControlSize) private var macControlSize
    #endif

    @ViewBuilder
    var body: some View {
        if DownloadsFeature.isVisible, isAvailable {
            Button {
                handleTap()
            } label: {
                Group {
                    if iconOnly {
                        #if os(macOS)
                        // The Mac hero's shared secondary circle (see
                        // `DetailHeroSecondaryIconLabel`).
                        let glyphGrowth: CGFloat = macControlSize == .extraLarge ? 4 : 0
                        icon
                            .font(.system(size: 13 + glyphGrowth / 2, weight: .semibold))
                            .frame(
                                width: detailHeroMacSecondaryGlyphBox + glyphGrowth,
                                height: detailHeroMacSecondaryGlyphBox + glyphGrowth
                            )
                            .help(title)
                        #else
                        icon
                            .frame(minWidth: 24, minHeight: 32)
                        #endif
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
            .sheet(isPresented: $isShowingQualitySelection) {
                DownloadQualitySelectionSheet(qualities: qualities, offersKeepNext: type == .show) { quality, keepNext in
                    isShowingQualitySelection = false
                    if let keepNext {
                        startSmartDownloads(count: keepNext, quality: quality)
                    } else {
                        startDownload(quality: quality)
                    }
                }
            }
            .confirmationDialog(
                smartRule?.menuLabel ?? "",
                isPresented: $isShowingSmartOptions,
                titleVisibility: .visible
            ) {
                if let smartRule {
                    SmartDownloadDialogActions(
                        rule: smartRule,
                        state: state,
                        onPause: { downloadManager.pauseDownload(scope: scope) },
                        onResume: { downloadManager.resumeDownload(scope: scope) },
                        onRetry: retry,
                        onDelete: { downloadManager.deleteDownload(scope: scope) }
                    )
                }
            } message: {
                Text("Watched episodes are removed and the next ones download automatically.")
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
                if type == .show {
                    SmartDownloadMenuContent(show: id, quality: state.records.first?.downloadQuality ?? .original)
                }
            }
        }
    }

    private var smartRule: SmartDownloadRule? {
        type == .show ? downloadManager.smartDownloadRule(show: id) : nil
    }

    /// Hidden only when nothing is on the device and the user may not
    /// download from this server.
    private var isAvailable: Bool {
        state.hasRecords || smartRule != nil || downloadManager.canStartDownload(for: id)
    }

    private var qualities: [DownloadQuality] {
        downloadManager.downloadQualities(for: id)
    }

    private var scope: DownloadScope {
        DownloadScope(id: id, type: type)
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
                // Kept by Keep Next N Unwatched: the dotted arrow of its menu.
                Image(systemName: smartRule == nil ? "checkmark.circle.fill" : "arrow.down.circle.dotted")
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
            case .cancelled:
                Image(systemName: "arrow.down.circle")
            case nil:
                // A smart show with nothing on the device (fully watched, or
                // waiting for its server) still says it is being kept.
                Image(systemName: smartRule == nil ? "arrow.down.circle" : "arrow.down.circle.dotted")
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

        if let smartRule, state.status == nil || state.status == .completed {
            return smartRule.menuLabel
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
        } else if smartRule != nil {
            isShowingSmartOptions = true
        } else if state.canPause {
            downloadManager.pauseDownload(scope: scope)
        } else if state.status == .paused {
            downloadManager.resumeDownload(scope: scope)
        } else if state.status == .failed {
            retry()
        } else if state.status == .completed {
            isShowingDeleteConfirmation = true
        } else if supportsQualitySelection {
            isShowingQualitySelection = true
        } else {
            startDownload(quality: .original)
        }
    }

    /// A show always gets the sheet for its Episodes choice; anything else
    /// only when there is a quality to pick.
    private var supportsQualitySelection: Bool {
        guard !isClip else { return false }
        if type == .show { return true }
        return qualities.count > 1 && (type == .movie || type == .episode || type == .season)
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

    private func startDownload(quality: DownloadQuality? = nil) {
        isStartingDownload = true
        Task {
            await downloadManager.queueDownload(id: id, type: type, isClip: isClip, quality: quality)
            isStartingDownload = false
        }
    }

    private func startSmartDownloads(count: Int, quality: DownloadQuality) {
        isStartingDownload = true
        Task {
            await downloadManager.enableSmartDownloads(show: id, count: count, quality: quality)
            isStartingDownload = false
        }
    }

    private func retry() {
        if smartRule != nil {
            // Re-queuing the whole show would download every episode.
            for record in state.records where record.status == .failed {
                downloadManager.retryDownload(id: record.mediaItemID)
            }
        } else if type == .season || type == .show {
            startDownload()
        } else {
            downloadManager.retryDownload(id: id)
        }
    }
}

struct DownloadQualitySelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedQuality = DownloadQuality.original
    /// 0 = every episode; otherwise Keep Next N Unwatched.
    @State private var keepNextCount = 0

    /// What the item's server can download; one choice hides the section.
    var qualities: [DownloadQuality] = DownloadQuality.allCases
    /// Shows get the Episodes choice (all, or keep the next N unwatched).
    var offersKeepNext = false
    /// The chosen quality, and the Keep Next count when one was picked.
    let onDownload: (DownloadQuality, Int?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                if offersKeepNext {
                    Section {
                        Picker("Episodes", selection: $keepNextCount) {
                            Text("All Episodes").tag(0)
                            ForEach(SmartDownloadRule.countOptions, id: \.self) { count in
                                Text("Next \(count) Unwatched").tag(count)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Episodes")
                    } footer: {
                        if keepNextCount > 0 {
                            Text("Watched episodes are removed and the next ones download automatically.")
                        }
                    }
                }

                if qualities.count > 1 {
                    Section {
                        Picker("Quality", selection: $selectedQuality) {
                            ForEach(qualities) { quality in
                                Text(quality.displayName)
                                    .tag(quality)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        if offersKeepNext {
                            Text("Quality")
                        }
                    } footer: {
                        Text("Original downloads the file as it is. Other qualities ask your Plex server to convert a smaller copy first, which may leave out embedded subtitles. Keep Dusk open while Plex prepares it; the download then continues in the background.")
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(offersKeepNext ? "Download Show" : "Download Quality")
            .duskNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        onDownload(selectedQuality, keepNextCount > 0 ? keepNextCount : nil)
                    }
                }
            }
        }
        #if os(macOS)
        .macUISheetSize(minHeight: 320, idealHeight: 420)
        #endif
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

/// The long-press menu entries for a show's Keep Next N Unwatched rule:
/// turn it on with a count, change the count, or stop it. Shared by the show's
/// Download button and its poster in Downloads.
struct SmartDownloadMenuContent: View {
    @Environment(DownloadManager.self) private var downloadManager

    let show: MediaItemID
    /// Used when the rule is turned on from here (no quality sheet).
    var quality: DownloadQuality = .original

    var body: some View {
        if let rule = downloadManager.smartDownloadRule(show: show) {
            Picker(selection: Binding(
                get: { rule.count },
                set: { downloadManager.setSmartDownloadCount($0, show: show) }
            )) {
                ForEach(SmartDownloadRule.countOptions, id: \.self) { count in
                    Text("Next \(count) Unwatched").tag(count)
                }
            } label: {
                Label("Keep Next Unwatched", systemImage: "arrow.down.circle.dotted")
            }
            .pickerStyle(.menu)

            Button {
                downloadManager.disableSmartDownloads(show: show)
            } label: {
                Label("Stop Keeping \(rule.shortLabel)", systemImage: "xmark.circle")
            }
        } else if downloadManager.canStartDownload(for: show) {
            Menu {
                ForEach(SmartDownloadRule.countOptions, id: \.self) { count in
                    Button("Next \(count) Unwatched") {
                        Task { await downloadManager.enableSmartDownloads(show: show, count: count, quality: quality) }
                    }
                }
            } label: {
                Label("Keep Next Unwatched", systemImage: "arrow.down.circle.dotted")
            }
        }
    }
}

/// The action sheet a smart show's Download button opens.
private struct SmartDownloadDialogActions: View {
    @Environment(DownloadManager.self) private var downloadManager

    let rule: SmartDownloadRule
    let state: DownloadControlState
    let onPause: () -> Void
    let onResume: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ForEach(SmartDownloadRule.countOptions.filter { $0 != rule.count }, id: \.self) { count in
            Button("Keep Next \(count) Unwatched") {
                downloadManager.setSmartDownloadCount(count, show: rule.showID)
            }
        }
        if state.canPause {
            Button("Pause Downloads", action: onPause)
        } else if state.status == .paused {
            Button("Resume Downloads", action: onResume)
        } else if state.status == .failed {
            Button("Retry Downloads", action: onRetry)
        }
        Button("Stop Keeping \(rule.shortLabel)") {
            downloadManager.disableSmartDownloads(show: rule.showID)
        }
        if state.hasRecords {
            Button("Delete Downloads", role: .destructive, action: onDelete)
        }
        Button("Cancel", role: .cancel) {}
    }
}
