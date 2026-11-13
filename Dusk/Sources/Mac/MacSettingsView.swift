#if os(macOS)
import AppKit
import SwiftUI

/// The Mac Settings window (⌘,): toolbar tabs, one grouped `Form` per pane,
/// system backgrounds and type. Never pushes: the list-style sub-pages
/// (Hidden Libraries, Server Priority, IPTV Sources, Seerr, …) open as sheets
/// over the window. The same settings as the iOS root (`SettingsIOSView`),
/// regrouped into Mac panes; About lives in the standard About panel
/// (Dusk › About Dusk). See docs/macos.md.
struct MacSettingsView: View {
    enum Pane: String, Hashable {
        case general, playback, libraries, downloads, integrations, account, support
    }

    @AppStorage("macSettingsPane") private var selection: Pane = .general

    var body: some View {
        TabView(selection: $selection) {
            Tab("General", systemImage: "gearshape", value: .general) {
                MacGeneralSettingsPane()
            }
            Tab("Playback", systemImage: "play.rectangle", value: .playback) {
                MacPlaybackSettingsPane()
            }
            Tab("Libraries", systemImage: "books.vertical", value: .libraries) {
                MacLibrariesSettingsPane()
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
                MacDownloadsSettingsPane()
            }
            Tab("Integrations", systemImage: "puzzlepiece.extension", value: .integrations) {
                MacIntegrationsSettingsPane()
            }
            Tab("Account", systemImage: "person.crop.circle", value: .account) {
                MacAccountSettingsPane()
            }
            Tab("Support Dusk", systemImage: "heart", value: .support) {
                MacSupportSettingsPane()
            }
        }
    }
}

// MARK: - Pane chrome

/// One Settings pane: a grouped form at the Mac Settings width whose height
/// follows its content (the window resizes per tab), up to a cap, past which
/// the form scrolls.
private struct MacSettingsPane<Content: View>: View {
    /// First-layout height, until the form has measured its content.
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat?

    private static var maxHeight: CGFloat { 640 }

    var body: some View {
        Form(content: content)
            .formStyle(.grouped)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, height in
                contentHeight = height
            }
            .frame(
                width: MacWindow.settingsSize.width,
                height: min(max(contentHeight ?? height, 160), Self.maxHeight)
            )
    }
}

/// A row that opens one of the list-style settings pages as a sheet: title,
/// a one-line summary, and a trailing push button.
private struct MacSettingsSheetRow<Page: View>: View {
    let title: String
    var summary: String?
    var buttonTitle = "Edit…"
    @ViewBuilder let page: () -> Page

    @State private var isPresented = false

    var body: some View {
        LabeledContent {
            Button(buttonTitle) { isPresented = true }
        } label: {
            Text(title)
            if let summary, !summary.isEmpty {
                Text(summary)
            }
        }
        .sheet(isPresented: $isPresented) {
            MacSettingsSheet(content: page)
        }
    }
}

/// A settings sub-page over the Settings window, with Done.
struct MacSettingsSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 420, idealHeight: 520)
    }
}

// MARK: - General

private struct MacGeneralSettingsPane: View {
    @Environment(UserPreferences.self) private var preferences
    @Environment(PlexService.self) private var plexService

    var body: some View {
        @Bindable var preferences = preferences

        MacSettingsPane(height: 560) {
            Section {
                Picker("Appearance", selection: $preferences.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle("Blur Unwatched Episodes", isOn: $preferences.blursUnwatchedEpisodes)
            } header: {
                Text("Appearance")
            } footer: {
                MacSettingsFooter(SettingsSupport.appearanceFooterText)
            }

            Section {
                Toggle("Personalized shelves", isOn: $preferences.personalizedShelvesEnabled)
                Toggle("Show Live TV", isOn: $preferences.showsLiveTVOnHome)
                Toggle("Compact Continue Watching", isOn: $preferences.compactHomeContinueWatching)
                MacSettingsSheetRow(title: "Hidden Rows") {
                    HiddenHomeRowsSettingsView()
                }
                MacSettingsSheetRow(
                    title: "Pinned Playlists",
                    summary: SettingsSupport.pinnedPlaylistsSummary(plexService.pinnedPlaylistPins.count)
                ) {
                    PinnedPlaylistsSettingsView()
                }
            } header: {
                Text("Home")
            } footer: {
                MacSettingsFooter(SettingsSupport.homeFooterText + " " + SettingsSupport.homeAdvancedFooterText)
            }
        }
    }
}

// MARK: - Playback

private struct MacPlaybackSettingsPane: View {
    @Environment(UserPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        MacSettingsPane(height: 620) {
            Section {
                Picker("Max Resolution", selection: $preferences.maxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                Picker("Preferred Version", selection: $preferences.preferredVersion) {
                    ForEach(PreferredMediaVersion.allCases) { version in
                        Text(version.displayName).tag(version)
                    }
                }
                MacSettingsSheetRow(
                    title: "Audio & Subtitles",
                    summary: SettingsSupport.audioSubtitlesSummary(preferences)
                ) {
                    AudioSubtitleSettingsView()
                }
                Picker("AI Upscaling", selection: $preferences.videoEnhancementMode) {
                    ForEach(VideoEnhancementMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("Defaults")
            } footer: {
                MacSettingsFooter(SettingsSupport.playbackDefaultsFooterText)
            }

            Section {
                Picker("Auto-Skip Intros", selection: $preferences.autoSkipIntroMode) {
                    ForEach(AutoSkipIntroMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle("Auto-Skip Credits", isOn: $preferences.autoSkipCredits)
                Toggle("Continuous Play", isOn: $preferences.continuousPlayEnabled)
                if preferences.continuousPlayEnabled {
                    Picker("Next Episode Delay", selection: $preferences.continuousPlayCountdown) {
                        ForEach(ContinuousPlayCountdown.allCases) { countdown in
                            Text(countdown.displayName).tag(countdown)
                        }
                    }
                    Picker("Pause After", selection: $preferences.continuousPlayPassoutProtectionEpisodeLimit) {
                        ForEach(SettingsSupport.passoutProtectionEpisodeOptions, id: \.self) { episodeLimit in
                            Text(SettingsSupport.passoutProtectionDisplayName(for: episodeLimit))
                                .tag(episodeLimit as Int?)
                        }
                    }
                }
                Toggle("Episode Buttons", isOn: $preferences.playerEpisodeButtonsEnabled)
                Toggle("Double-Tap to Seek", isOn: $preferences.playerDoubleTapSeekEnabled)
                if preferences.playerDoubleTapSeekEnabled {
                    Picker("Back Jump", selection: $preferences.playerDoubleTapBackwardInterval) {
                        ForEach(PlayerSeekInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    Picker("Forward Jump", selection: $preferences.playerDoubleTapForwardInterval) {
                        ForEach(PlayerSeekInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                }
            } header: {
                Text("Behavior")
            } footer: {
                MacSettingsFooter(SettingsSupport.playbackBehaviorFooterText)
            }

            Section {
                Toggle("Advanced Playback Controls", isOn: $preferences.playerAdvancedControlsEnabled)
                Toggle("Dolby Atmos & Spatial Audio", isOn: $preferences.spatialAudioRemuxEnabled)
                Toggle("HDR & Dolby Vision", isOn: $preferences.hdrVideoRemuxEnabled)
                Toggle("Dolby Vision 7 → 8.1", isOn: $preferences.dolbyVision7ConversionEnabled)
                    .disabled(!preferences.hdrVideoRemuxEnabled)
                Toggle("Force AVPlayer", isOn: $preferences.forceAVPlayer)
                Toggle("Force VLCKit", isOn: $preferences.forceVLCKit)
            } header: {
                Text("Advanced")
            } footer: {
                MacSettingsFooter(SettingsSupport.playbackAdvancedFooterText)
            }
        }
    }
}

// MARK: - Libraries (+ Live TV)

private struct MacLibrariesSettingsPane: View {
    @Environment(UserPreferences.self) private var preferences
    @Environment(PlexService.self) private var plexService
    @Environment(IPTVService.self) private var iptvService

    var body: some View {
        MacSettingsPane(height: 420) {
            Section {
                MacSettingsSheetRow(
                    title: "Navigation Tabs",
                    summary: SettingsSupport.libraryTabsSummary(preferences)
                ) {
                    LibraryTabSettingsView()
                }
                MacSettingsSheetRow(
                    title: "Hidden Libraries",
                    summary: SettingsSupport.hiddenLibrariesSummary(plexService)
                ) {
                    HiddenLibrariesSettingsView()
                }
                MacSettingsSheetRow(
                    title: "Server Priority",
                    summary: SettingsSupport.serverPrioritySummary(plexService)
                ) {
                    ServerPrioritySettingsView()
                }
            } header: {
                Text("Libraries")
            } footer: {
                MacSettingsFooter(SettingsSupport.librariesFooterText)
            }

            Section {
                MacSettingsSheetRow(
                    title: "IPTV Sources",
                    summary: SettingsSupport.iptvSourcesSummary(iptvService.sources.count)
                ) {
                    IPTVSourcesSettingsView()
                }
            } header: {
                Text("Live TV")
            } footer: {
                MacSettingsFooter(SettingsSupport.liveTVFooterText)
            }
        }
    }
}

// MARK: - Downloads

private struct MacDownloadsSettingsPane: View {
    @Environment(UserPreferences.self) private var preferences
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager
    @State private var viewModel = SettingsViewModel()
    @State private var confirmsDeletingDownloads = false

    var body: some View {
        @Bindable var preferences = preferences

        MacSettingsPane(height: 520) {
            Section {
                Picker("Preferred Version", selection: $preferences.downloadMaxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                Toggle("Wi-Fi Only", isOn: $preferences.downloadsWifiOnly)
                Picker("Simultaneous Downloads", selection: $preferences.maximumActiveDownloads) {
                    ForEach(DownloadConcurrency.allCases) { concurrency in
                        Text(concurrency.displayName).tag(concurrency)
                    }
                }
                Picker("Keep Free", selection: $preferences.downloadFreeSpaceReserve) {
                    ForEach(DownloadFreeSpaceReserve.allCases) { reserve in
                        Text(reserve.displayName).tag(reserve)
                    }
                }
            } header: {
                Text("Downloads")
            } footer: {
                MacSettingsFooter(SettingsSupport.downloadsFooterText)
            }

            Section {
                LabeledContent("Storage Used", value: formattedBytes(downloadManager.storageUsageBytes))
                if let availableStorageBytes = downloadManager.availableStorageBytes {
                    LabeledContent("Available", value: formattedBytes(availableStorageBytes))
                }
                if offlinePlaybackSyncManager.pendingSyncCount > 0 {
                    LabeledContent("Pending Watch Sync") {
                        HStack {
                            Text("\(offlinePlaybackSyncManager.pendingSyncCount)")
                            Button(offlinePlaybackSyncManager.isSyncing ? "Syncing…" : "Sync Now") {
                                Task { await offlinePlaybackSyncManager.syncPendingActions(force: true) }
                            }
                            .disabled(offlinePlaybackSyncManager.isSyncing)
                        }
                    }
                }
                LabeledContent("Downloaded Videos") {
                    Button("Delete All…", role: .destructive) {
                        confirmsDeletingDownloads = true
                    }
                    .disabled(downloadManager.records.isEmpty)
                }
                LabeledContent("Image Cache") {
                    HStack {
                        Text(viewModel.formattedCacheSize)
                            .foregroundStyle(.secondary)
                        Button("Clear") { viewModel.clearImageCache() }
                    }
                }
            } header: {
                Text("Storage")
            } footer: {
                MacSettingsFooter(viewModel.storageFooterText)
            }
        }
        .confirmationDialog(
            "Delete all downloads?",
            isPresented: $confirmsDeletingDownloads,
            titleVisibility: .visible
        ) {
            Button("Delete All Downloads", role: .destructive) {
                downloadManager.deleteAllDownloads()
                offlinePlaybackSyncManager.deleteAllLocalState()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded videos, saved metadata, artwork, pause data, and queue entries will be removed from this Mac.")
        }
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

// MARK: - Integrations

private struct MacIntegrationsSettingsPane: View {
    @Environment(SeerrService.self) private var seerrService
    @Environment(TraktService.self) private var traktService

    var body: some View {
        MacSettingsPane(height: 300) {
            Section {
                MacSettingsSheetRow(title: "Seerr", summary: seerrService.connectionSubtitle, buttonTitle: "Configure…") {
                    SeerrSettingsView()
                }
                if traktService.isAvailable {
                    MacSettingsSheetRow(title: "Trakt", summary: traktService.connectionSubtitle, buttonTitle: "Configure…") {
                        TraktSettingsView()
                    }
                }
            } footer: {
                MacSettingsFooter(SettingsSupport.integrationsFooterText(showsTrakt: traktService.isAvailable))
            }
        }
    }
}

// MARK: - Account

private struct MacAccountSettingsPane: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @Environment(\.openURL) private var openURL
    @State private var showsHomeUserPicker = false
    @State private var confirmsSignOut = false

    var body: some View {
        @Bindable var preferences = preferences

        MacSettingsPane(height: 420) {
            if plexService.homeUsers.count > 1, let activeUser = plexService.activeHomeUser {
                Section {
                    LabeledContent {
                        Button("Switch User…") { showsHomeUserPicker = true }
                    } label: {
                        HStack(spacing: 10) {
                            PlexHomeUserAvatar(user: activeUser, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(activeUser.displayName)
                                Text("Current User")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle("Automatically Sign In", isOn: automaticHomeSignInBinding)
                } header: {
                    Text("Plex Home")
                } footer: {
                    MacSettingsFooter("When off, Dusk asks who’s watching whenever it starts.")
                }
            }

            Section {
                Toggle("Help Improve Dusk", isOn: $preferences.analyticsEnabled)
                LabeledContent("Privacy Policy") {
                    Link("getdusk.app/privacy", destination: SettingsSupport.privacyPolicyURL)
                }
            } header: {
                Text("Privacy")
            } footer: {
                MacSettingsFooter(SettingsSupport.privacyFooterText)
            }

            Section {
                LabeledContent("Plex Account") {
                    Button("Manage in Browser…") {
                        openURL(SettingsSupport.plexAccountURL)
                    }
                }
                LabeledContent("Delete Plex Account") {
                    Button("Open Deletion Controls…") {
                        openURL(SettingsSupport.plexAccountURL)
                    }
                }
                LabeledContent("Sign Out of Plex") {
                    Button("Sign Out…", role: .destructive) {
                        confirmsSignOut = true
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                MacSettingsFooter(SettingsSupport.accountManagementFooterText + " " + SettingsSupport.accountFooterText)
            }
        }
        .sheet(isPresented: homeUserPickerPresented) {
            HomeUserPickerView(
                users: plexService.homeUsers,
                rememberSelection: plexService.automaticHomeSignIn,
                onComplete: { showsHomeUserPicker = false },
                onCancel: { showsHomeUserPicker = false }
            )
            .macUISheetSize(minWidth: 560, idealWidth: 720, minHeight: 440, idealHeight: 560)
        }
        .confirmationDialog("Sign out of Plex?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                plexService.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SettingsSupport.accountFooterText)
        }
    }

    private var homeUserPickerPresented: Binding<Bool> {
        Binding(
            get: { showsHomeUserPicker && plexService.homeUsers.count > 1 },
            set: { showsHomeUserPicker = $0 }
        )
    }

    private var automaticHomeSignInBinding: Binding<Bool> {
        Binding(
            get: { plexService.automaticHomeSignIn },
            set: { plexService.automaticHomeSignIn = $0 }
        )
    }
}

// MARK: - Support Dusk

private struct MacSupportSettingsPane: View {
    @Environment(SupporterStore.self) private var supporterStore
    @State private var showsSupporter = false

    var body: some View {
        MacSettingsPane(height: 260) {
            Section {
                LabeledContent {
                    Button(supporterStore.isSupporter ? "Manage…" : "Support Dusk…") {
                        showsSupporter = true
                    }
                } label: {
                    Label {
                        Text(supporterStore.isSupporter ? "You’re a Supporter" : "Support Dusk")
                        Text(statusText)
                    } icon: {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(Color.duskAccent)
                    }
                }
            } footer: {
                MacSettingsFooter("Dusk is free and open source. Supporting it is entirely optional.")
            }
        }
        .sheet(isPresented: $showsSupporter) {
            SupporterView(context: .settings)
        }
    }

    private var statusText: String {
        if supporterStore.hasActiveSubscription {
            return "Dusk Supporter — thank you for making Dusk possible."
        }
        if supporterStore.isSupporter {
            return "Thank you for making Dusk possible."
        }
        return "Free, no ads, no tracking — chip in if you like it."
    }
}

// MARK: - Shared

/// A section footer in the pane's secondary footnote style.
private struct MacSettingsFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - About panel

/// Dusk › About Dusk: the standard About panel, with the links the iOS
/// Settings "About" section carries as its credits.
enum MacAboutPanel {
    @MainActor
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(
            string: "Dusk is free and open source.\n",
            attributes: base
        )
        let links: [(String, URL)] = [
            ("GitHub", SettingsSupport.githubURL),
            ("Community", SettingsSupport.redditURL),
            ("About Me", SettingsSupport.aboutMeURL),
            ("Feedback", SettingsSupport.feedbackURL),
            ("Privacy Policy", SettingsSupport.privacyPolicyURL),
        ]
        for (index, link) in links.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: " · ", attributes: base))
            }
            var attributes = base
            attributes[.link] = link.1
            text.append(NSAttributedString(string: link.0, attributes: attributes))
        }
        return text
    }
}
#endif
