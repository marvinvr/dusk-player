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

    /// The remembered tab; `open(_:using:)` writes it to pick a tab.
    static let selectionDefaultsKey = "macSettingsPane"

    @AppStorage(MacSettingsView.selectionDefaultsKey) private var selection: Pane = .general

    /// Opens (or brings forward) the Settings window on `pane`, e.g. from
    /// Live TV's "Open Live TV Settings…". An open window follows along, as
    /// the tab selection is `@AppStorage`.
    static func open(_ pane: Pane, using openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(pane.rawValue, forKey: selectionDefaultsKey)
        openSettings()
    }

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

    /// Fits a 13-inch display with the tab bar; taller panes scroll.
    private static var maxHeight: CGFloat { 600 }

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

        MacSettingsPane(height: 520) {
            Section {
                Picker(selection: $preferences.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Text("Appearance")
                    Text("System follows your Mac. Light and Dark override it for Dusk.")
                }
            }

            Section {
                Toggle(isOn: $preferences.personalizedShelvesEnabled) {
                    Text("Personalized Shelves")
                    Text("Adds recommendations from Dusk to Home.")
                }
                Toggle(isOn: $preferences.showsLiveTVOnHome) {
                    Text("Show Live TV")
                    Text("Adds the channels airing now to Home.")
                }
                Toggle(isOn: $preferences.compactHomeContinueWatching) {
                    Text("Compact Continue Watching")
                    Text("Replaces the large artwork at the top of Home with a Continue Watching row.")
                }
                MacSettingsSheetRow(
                    title: "Hidden Rows",
                    summary: "Choose which of Plex’s rows appear on Home."
                ) {
                    HiddenHomeRowsSettingsView()
                }
                MacSettingsSheetRow(
                    title: "Pinned Playlists",
                    summary: Self.pinnedPlaylistsSummary(plexService.pinnedPlaylistPins.count)
                ) {
                    PinnedPlaylistsSettingsView()
                }
            } header: {
                Text("Home")
            }

            Section {
                Toggle(isOn: $preferences.blursUnwatchedEpisodes) {
                    Text("Blur Unwatched Episodes")
                    Text("Hides the images of episodes you haven’t finished, so they can’t spoil anything.")
                }
            } header: {
                Text("Spoilers")
            }
        }
    }

    private static func pinnedPlaylistsSummary(_ count: Int) -> String {
        switch count {
        case 0: "Playlists you pin appear near the top of Home."
        case 1: "1 playlist pinned near the top of Home."
        default: "\(count) playlists pinned near the top of Home."
        }
    }
}

// MARK: - Playback

private struct MacPlaybackSettingsPane: View {
    @Environment(UserPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        MacSettingsPane(height: 600) {
            Section {
                Picker(selection: $preferences.maxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                } label: {
                    Text("Max Resolution")
                    Text("The highest stream quality Dusk asks your server for.")
                }
                Picker(selection: $preferences.preferredVersion) {
                    ForEach(PreferredMediaVersion.allCases) { version in
                        Text(version.displayName).tag(version)
                    }
                } label: {
                    Text("Preferred Version")
                    Text("Which version plays when a title has more than one.")
                }
                MacSettingsSheetRow(
                    title: "Audio & Subtitles",
                    summary: SettingsSupport.audioSubtitlesSummary(preferences)
                ) {
                    AudioSubtitleSettingsView()
                }
                Picker(selection: $preferences.videoEnhancementMode) {
                    ForEach(VideoEnhancementMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Text("AI Upscaling")
                    Text("Sharpens lower-resolution video. Can increase power use.")
                }
            } header: {
                Text("Defaults")
            }

            Section {
                Picker(selection: $preferences.autoSkipIntroMode) {
                    ForEach(AutoSkipIntroMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Text("Auto-Skip Intros")
                    Text("Skips intros after a brief countdown.")
                }
                Toggle(isOn: $preferences.autoSkipCredits) {
                    Text("Auto-Skip Credits")
                    Text("Skips credits after a brief countdown.")
                }
                Toggle(isOn: $preferences.continuousPlayEnabled) {
                    Text("Continuous Play")
                    Text("Shows Up Next when an episode ends and plays the next one.")
                }
                if preferences.continuousPlayEnabled {
                    Picker("Next Episode Delay", selection: $preferences.continuousPlayCountdown) {
                        ForEach(ContinuousPlayCountdown.allCases) { countdown in
                            Text(Self.seconds(countdown.rawValue)).tag(countdown)
                        }
                    }
                    Picker(selection: $preferences.continuousPlayPassoutProtectionEpisodeLimit) {
                        ForEach(SettingsSupport.passoutProtectionEpisodeOptions, id: \.self) { episodeLimit in
                            Text(SettingsSupport.passoutProtectionDisplayName(for: episodeLimit))
                                .tag(episodeLimit as Int?)
                        }
                    } label: {
                        Text("Pause After")
                        Text("Counts the current episode, then waits for you before playing on.")
                    }
                }
            } header: {
                Text("Behavior")
            }

            // The Mac player always shows its skip buttons, so only the
            // intervals are settings here (the iOS double-tap zones and the
            // opt-in for skip/speed/episode buttons don't apply).
            Section {
                Picker("Skip Back", selection: $preferences.playerDoubleTapBackwardInterval) {
                    ForEach(PlayerSeekInterval.allCases) { interval in
                        Text(Self.seconds(interval.rawValue)).tag(interval)
                    }
                }
                Picker("Skip Forward", selection: $preferences.playerDoubleTapForwardInterval) {
                    ForEach(PlayerSeekInterval.allCases) { interval in
                        Text(Self.seconds(interval.rawValue)).tag(interval)
                    }
                }
            } header: {
                Text("Player")
            } footer: {
                MacSettingsFooter("Used by the player’s skip buttons and the Left and Right Arrow keys.")
            }

            Section {
                Toggle(isOn: $preferences.spatialAudioRemuxEnabled) {
                    Text("Dolby Atmos & Spatial Audio")
                    Text("Plays Atmos and surround Dolby tracks in MKV and similar files through Apple’s player.")
                }
                Toggle(isOn: $preferences.hdrVideoRemuxEnabled) {
                    Text("HDR & Dolby Vision")
                    Text("Does the same for HDR10, HDR10+, HLG and Dolby Vision video.")
                }
                Toggle(isOn: $preferences.dolbyVision7ConversionEnabled) {
                    Text("Dolby Vision 7 → 8.1")
                    Text("Plays profile 7 (UHD Blu-ray) video as Dolby Vision. Turn off if those titles misbehave.")
                }
                .disabled(!preferences.hdrVideoRemuxEnabled)
                Toggle(isOn: $preferences.forceAVPlayer) {
                    Text("Force AVPlayer")
                    Text("Skips automatic engine selection. May fail on formats it can’t play.")
                }
                Toggle(isOn: $preferences.forceVLCKit) {
                    Text("Force VLCKit")
                    Text("Skips automatic engine selection.")
                }
            } header: {
                Text("Advanced")
            } footer: {
                MacSettingsFooter("Your Plex server repackages the file without re-encoding it, so quality stays the original’s.")
            }
        }
    }

    private static func seconds(_ value: Int) -> String {
        value == 1 ? "1 second" : "\(value) seconds"
    }
}

// MARK: - Libraries (+ Live TV)

private struct MacLibrariesSettingsPane: View {
    @Environment(UserPreferences.self) private var preferences
    @Environment(PlexService.self) private var plexService
    @Environment(IPTVService.self) private var iptvService

    var body: some View {
        MacSettingsPane(height: 400) {
            Section {
                MacSettingsSheetRow(
                    title: "Sidebar Items",
                    summary: Self.join(
                        SettingsSupport.libraryTabsSummary(preferences),
                        "Which libraries and Live TV appear in the sidebar, in order."
                    )
                ) {
                    LibraryTabSettingsView()
                }
                MacSettingsSheetRow(
                    title: "Hidden Libraries",
                    summary: Self.join(
                        SettingsSupport.hiddenLibrariesSummary(plexService),
                        "Removed from Dusk completely, including Home and Search."
                    )
                ) {
                    HiddenLibrariesSettingsView()
                }
                MacSettingsSheetRow(
                    title: "Server Priority",
                    summary: Self.join(
                        SettingsSupport.serverPrioritySummary(plexService),
                        "Which server plays a title that is on more than one."
                    )
                ) {
                    ServerPrioritySettingsView()
                }
            }

            Section {
                MacSettingsSheetRow(
                    title: "IPTV Sources",
                    summary: Self.join(
                        SettingsSupport.iptvSourcesSummary(iptvService.sources.count),
                        "M3U playlists shown beside Plex Live TV."
                    )
                ) {
                    IPTVSourcesSettingsView()
                }
            } header: {
                Text("Live TV")
            }
        }
    }

    /// "Current value · what the row does", skipping an empty value.
    private static func join(_ value: String, _ description: String) -> String {
        value.isEmpty ? description : "\(value) · \(description)"
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
            // No Wi-Fi Only on the Mac: there's no cellular network to avoid.
            Section {
                Picker(selection: $preferences.downloadMaxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                } label: {
                    Text("Preferred Version")
                    Text("Which version is downloaded when a title has several.")
                }
                Picker("Simultaneous Downloads", selection: $preferences.maximumActiveDownloads) {
                    ForEach(DownloadConcurrency.allCases) { concurrency in
                        Text(concurrency.displayName).tag(concurrency)
                    }
                }
                Picker(selection: $preferences.downloadFreeSpaceReserve) {
                    ForEach(DownloadFreeSpaceReserve.allCases) { reserve in
                        Text(reserve.displayName).tag(reserve)
                    }
                } label: {
                    Text("Keep Free")
                    Text("Downloads stop before the disk gets this full.")
                }
            } footer: {
                MacSettingsFooter("You choose the quality each time you start a download.")
            }

            Section {
                LabeledContent("Storage Used", value: formattedBytes(downloadManager.storageUsageBytes))
                if let availableStorageBytes = downloadManager.availableStorageBytes {
                    LabeledContent("Available", value: formattedBytes(availableStorageBytes))
                }
                if offlinePlaybackSyncManager.pendingSyncCount > 0 {
                    LabeledContent {
                        Button(offlinePlaybackSyncManager.isSyncing ? "Syncing…" : "Sync Now") {
                            Task { await offlinePlaybackSyncManager.syncPendingActions(force: true) }
                        }
                        .disabled(offlinePlaybackSyncManager.isSyncing)
                    } label: {
                        Text("Pending Watch Sync")
                        Text(offlinePlaybackSyncManager.pendingSyncCount == 1
                            ? "1 change waiting for Plex"
                            : "\(offlinePlaybackSyncManager.pendingSyncCount) changes waiting for Plex")
                    }
                }
                LabeledContent {
                    Button("Delete All…", role: .destructive) {
                        confirmsDeletingDownloads = true
                    }
                    .disabled(downloadManager.records.isEmpty)
                } label: {
                    Text("Downloaded Videos")
                    Text(downloadManager.records.isEmpty
                        ? "None"
                        : downloadManager.records.count == 1 ? "1 video" : "\(downloadManager.records.count) videos")
                }
                LabeledContent {
                    Button("Clear") { viewModel.clearImageCache() }
                } label: {
                    Text("Image Cache")
                    Text(viewModel.formattedCacheSize)
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
                MacSettingsSheetRow(
                    title: "Seerr",
                    summary: Self.join(seerrService.connectionSubtitle, "Request movies and shows from Search."),
                    buttonTitle: "Configure…"
                ) {
                    SeerrSettingsView()
                }
                if traktService.isAvailable {
                    MacSettingsSheetRow(
                        title: "Trakt",
                        summary: Self.join(traktService.connectionSubtitle, "Keeps your Trakt history up to date."),
                        buttonTitle: "Configure…"
                    ) {
                        TraktSettingsView()
                    }
                }
            }
        }
    }

    private static func join(_ value: String?, _ description: String) -> String {
        guard let value, !value.isEmpty else { return description }
        return "\(value) · \(description)"
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

        MacSettingsPane(height: 460) {
            Section {
                MacPlexAccountRow(user: plexService.currentUser)
                LabeledContent {
                    Button("Manage in Browser…") {
                        openURL(SettingsSupport.plexAccountURL)
                    }
                } label: {
                    Text("Plex Account")
                    Text("Your account settings on plex.tv, including account deletion.")
                }
                LabeledContent {
                    Button("Sign Out…", role: .destructive) {
                        confirmsSignOut = true
                    }
                } label: {
                    Text("Sign Out of Plex")
                    Text("Dusk forgets this Plex session and returns to sign-in.")
                }
            }

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
                    Toggle(isOn: automaticHomeSignInBinding) {
                        Text("Automatically Sign In")
                        Text("When off, Dusk asks who’s watching whenever it starts.")
                    }
                } header: {
                    Text("Plex Home")
                }
            }

            Section {
                Toggle(isOn: $preferences.analyticsEnabled) {
                    Text("Help Improve Dusk")
                    Text("Sends a few anonymous events, including error reports, to Dusk’s own server.")
                }
                LabeledContent("Privacy Policy") {
                    Button {
                        openURL(SettingsSupport.privacyPolicyURL)
                    } label: {
                        Label("View", systemImage: "arrow.up.right.square")
                    }
                    .help("Opens getdusk.app/privacy in your browser")
                }
            } header: {
                Text("Privacy")
            } footer: {
                MacSettingsFooter("Nothing about your library, your server, what you watch or what you search for is ever included.")
            }
        }
        .task {
            // The identity row; cached after the first load.
            _ = try? await plexService.getCurrentUser()
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
            Text("Dusk forgets this Plex session and returns to sign-in.")
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

/// Who is signed in: the Plex account's avatar, name and email (or
/// username), like the Apple Account row in System Settings.
private struct MacPlexAccountRow: View {
    let user: PlexUser?

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var name: String {
        user?.title?.nilIfEmpty ?? user?.friendlyName?.nilIfEmpty ?? user?.username?.nilIfEmpty ?? "Plex Account"
    }

    private var detail: String? {
        if let email = user?.email?.nilIfEmpty { return email }
        if let username = user?.username?.nilIfEmpty, username != name { return username }
        return user == nil ? nil : "Signed in with Plex"
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.18))
            DuskAsyncImage(url: user?.thumb?.nilIfEmpty.flatMap(URL.init(string:))) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                case .empty, .failure:
                    Image(systemName: "person.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }
}

// MARK: - Support Dusk

private struct MacSupportSettingsPane: View {
    @Environment(SupporterStore.self) private var supporterStore
    @State private var showsSupporter = false

    var body: some View {
        MacSettingsPane(height: 320) {
            Section {
                LabeledContent {
                    Button(supporterStore.isSupporter ? "Manage…" : "Learn More…") {
                        showsSupporter = true
                    }
                } label: {
                    Label {
                        Text(supporterStore.isSupporter ? "You’re a Supporter" : "Become a Supporter")
                        Text(statusText)
                    } icon: {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(Color.duskAccent)
                    }
                }
                if let since = supporterStore.supporterSince {
                    LabeledContent("Supporter Since", value: since.formatted(date: .long, time: .omitted))
                }
            }

            Section {
                perk("app.gift", "Alternate App Icons", "Tips from Generous up unlock six classic icons for Dusk on iPhone, iPad and Apple TV.")
                perk("sparkles", "Subscriber Exclusives", "The subscription adds four more: Velvet, Emerald, Gilded and Sapphire.")
                perk("hammer", "Keeps Dusk Going", "Everything in Dusk stays free either way. Supporting pays for its development.")
            } header: {
                Text("What You Get")
            }
        }
        .sheet(isPresented: $showsSupporter) {
            SupporterView(context: .settings)
        }
    }

    private func perk(_ systemImage: String, _ title: String, _ detail: String) -> some View {
        Label {
            Text(title)
            Text(detail)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
    }

    private var statusText: String {
        if supporterStore.hasActiveSubscription {
            return "Dusk Supporter subscription active. Thank you for making Dusk possible."
        }
        if supporterStore.isSupporter {
            return "Thank you for making Dusk possible."
        }
        return "Dusk is free, open source and has no ads. Supporting is entirely optional."
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

/// Dusk › About Dusk: the standard About panel, with one short line of links
/// as its credits (small, secondary, not underlined) and the copyright from
/// LICENSE.
enum MacAboutPanel {
    static let copyright = "© 2026 Marvin von Rappard"

    @MainActor
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright,
        ])
        NSApp.activate()
        quietLinks()
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let separator: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString()
        let links: [(String, URL)] = [
            ("GitHub", SettingsSupport.githubURL),
            ("Community", SettingsSupport.redditURL),
            ("Feedback", SettingsSupport.feedbackURL),
            ("Privacy", SettingsSupport.privacyPolicyURL),
        ]
        for (index, link) in links.enumerated() {
            if index > 0 {
                // Non-breaking on the left, so a "·" never starts or ends a
                // wrapped line on its own.
                text.append(NSAttributedString(string: "\u{00A0}· ", attributes: separator))
            }
            text.append(NSAttributedString(string: link.0, attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
                .link: link.1,
            ]))
        }
        return text
    }

    /// The panel's credits text view underlines links in the accent colour
    /// through its `linkTextAttributes`; keep them plain secondary text with
    /// a pointing-hand cursor.
    @MainActor
    private static func quietLinks() {
        for window in NSApp.windows where window.isVisible && window is NSPanel {
            for textView in textViews(in: window.contentView) {
                textView.linkTextAttributes = [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .cursor: NSCursor.pointingHand,
                ]
            }
        }
    }

    private static func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        if let textView = view as? NSTextView { return [textView] }
        return view.subviews.flatMap { textViews(in: $0) }
    }
}
#endif
