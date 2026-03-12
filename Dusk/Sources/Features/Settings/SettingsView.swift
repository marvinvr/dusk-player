import SwiftUI

/// Settings screen accessible from the Settings tab.
///
/// Sections: Playback, Server, App (per SPEC.md §6.7).
struct SettingsView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @Binding var path: NavigationPath

    @State private var showServerPicker = false
    @State private var availableServers: [PlexServer]?
    @State private var isLoadingServers = false
    @State private var serverError: String?
    @State private var imageCacheClearedAt: Date?
    @State private var imageCacheSize: Int = AppImageCache.shared.currentDiskUsage

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                settingsContent
            }
            .sheet(isPresented: $showServerPicker) {
                serverPickerSheet
            }
            .duskNavigationTitle("Settings")
            .duskNavigationBarTitleDisplayModeLarge()
            .duskAppNavigationDestinations()
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        #if os(tvOS)
        tvSettingsContent
        #else
        iosSettingsContent
        #endif
    }

    @ViewBuilder
    private var iosSettingsContent: some View {
        List {
            playbackSection
            serverSection
            appSection
            accountSection
        }
        .duskScrollContentBackgroundHidden()
    }

    #if os(tvOS)
    private var tvSettingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                tvPlaybackSection
                tvServerSection
                tvAppSection
                tvAccountSection
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.vertical, 48)
        }
    }
    #endif

    // MARK: - Playback

    @ViewBuilder
    private var playbackSection: some View {
        @Bindable var preferences = preferences

        Section {
            // Max Resolution
            Picker("Max Resolution", selection: $preferences.maxResolution) {
                ForEach(MaxResolution.allCases) { resolution in
                    Text(resolution.displayName).tag(resolution)
                }
            }
            .foregroundStyle(Color.duskTextPrimary)

            // Default Subtitle Language
            subtitleLanguagePicker

            // Default Audio Language
            Picker("Audio", selection: $preferences.defaultAudioLanguage) {
                ForEach(CommonLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.code)
                }
            }
            .foregroundStyle(Color.duskTextPrimary)

            Toggle("Force AVPlayer", isOn: $preferences.forceAVPlayer)
                .foregroundStyle(Color.duskTextPrimary)
                .tint(Color.duskAccent)

            // Force VLCKit
            Toggle("Force VLCKit", isOn: $preferences.forceVLCKit)
                .foregroundStyle(Color.duskTextPrimary)
                .tint(Color.duskAccent)

            Toggle("Player Debug Overlay", isOn: $preferences.playerDebugOverlayEnabled)
                .foregroundStyle(Color.duskTextPrimary)
                .tint(Color.duskAccent)
        } header: {
            Text("Playback")
                .foregroundStyle(Color.duskTextSecondary)
        } footer: {
            Text("Force AVPlayer and Force VLCKit bypass automatic engine selection. Enabling one disables the other. Force AVPlayer may fail on formats AVPlayer cannot handle. Player Debug Overlay shows stream stats in the top-right corner during playback.")
                .foregroundStyle(Color.duskTextSecondary)
        }
        .listRowBackground(Color.duskSurface)
    }

    /// Subtitle language picker using a non-optional String binding
    /// ("" means no default subtitle).
    private var subtitleLanguagePicker: some View {
        Picker("Subtitles", selection: subtitleLanguageBinding) {
            Text("None").tag("")
            ForEach(CommonLanguage.allCases) { lang in
                Text(lang.displayName).tag(lang.code)
            }
        }
        .foregroundStyle(Color.duskTextPrimary)
    }

    // MARK: - Server

    @ViewBuilder
    private var serverSection: some View {
        Section {
            if let server = plexService.connectedServer {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name)
                            .foregroundStyle(Color.duskTextPrimary)
                        Text(connectionType)
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)
                    }

                    Spacer()

                    Circle()
                        .fill(Color.duskAccent)
                        .frame(width: 8, height: 8)
                }
            } else {
                Text("Not connected")
                    .foregroundStyle(Color.duskTextSecondary)
            }

            Button {
                Task { await loadServersAndShowPicker() }
            } label: {
                HStack {
                    Text("Change Server")
                        .foregroundStyle(Color.duskAccent)
                    Spacer()
                    if isLoadingServers {
                        ProgressView()
                            .tint(Color.duskAccent)
                    }
                }
            }
            .disabled(isLoadingServers)
            .duskSuppressTVOSButtonChrome()
        } header: {
            Text("Server")
                .foregroundStyle(Color.duskTextSecondary)
        } footer: {
            if let error = serverError {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .listRowBackground(Color.duskSurface)
    }

    // MARK: - App

    @ViewBuilder
    private var appSection: some View {
        @Bindable var preferences = preferences

        Section {
            Picker("Appearance", selection: $preferences.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .foregroundStyle(Color.duskTextPrimary)

            Button {
                AppImageCache.clear()
                imageCacheClearedAt = .now
                imageCacheSize = AppImageCache.shared.currentDiskUsage
            } label: {
                HStack {
                    Text("Clear Image Cache")
                    Spacer()
                    Text(formattedCacheSize)
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
            .foregroundStyle(Color.duskAccent)
            .duskSuppressTVOSButtonChrome()

            HStack {
                Text("Version")
                    .foregroundStyle(Color.duskTextPrimary)
                Spacer()
                Text(appVersion)
                    .foregroundStyle(Color.duskTextSecondary)
            }
        } header: {
            Text("App")
                .foregroundStyle(Color.duskTextSecondary)
        } footer: {
            Text(appFooterText)
                .foregroundStyle(Color.duskTextSecondary)
        }
        .listRowBackground(Color.duskSurface)
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                plexService.signOut()
            }
            .duskSuppressTVOSButtonChrome()
        } footer: {
            Text("Clears the saved Plex session and returns to the sign-in flow.")
                .foregroundStyle(Color.duskTextSecondary)
        }
        .listRowBackground(Color.duskSurface)
    }

    // MARK: - Server Picker Sheet

    @ViewBuilder
    private var serverPickerSheet: some View {
        if let servers = availableServers {
            ServerPickerView(servers: servers) { server in
                try await plexService.connect(to: server)
                showServerPicker = false
                availableServers = nil
            }
        }
    }

    // MARK: - Helpers

    private var connectionType: String {
        // Infer from the stored server URL
        "Connected"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var subtitleLanguageBinding: Binding<String> {
        Binding<String>(
            get: { preferences.defaultSubtitleLanguage ?? "" },
            set: { preferences.defaultSubtitleLanguage = $0.isEmpty ? nil : $0 }
        )
    }

    private var subtitleLanguageOptions: [String] {
        [""] + CommonLanguage.allCases.map(\.code)
    }

    private var audioLanguageOptions: [String] {
        CommonLanguage.allCases.map(\.code)
    }

    private func subtitleDisplayName(for code: String) -> String {
        code.isEmpty ? "None" : languageDisplayName(for: code)
    }

    private func languageDisplayName(for code: String) -> String {
        CommonLanguage(rawValue: code)?.displayName ?? code.uppercased()
    }

    private var playbackFooterText: String {
        "Force AVPlayer and Force VLCKit bypass automatic engine selection. Enabling one disables the other. Force AVPlayer may fail on formats AVPlayer cannot handle. Player Debug Overlay shows stream stats in the top-right corner during playback."
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(imageCacheSize), countStyle: .file)
    }

    private var appFooterText: String {
        let base = "System follows your device appearance. Light and Dark override it for the whole app. Clear Image Cache removes locally cached posters and artwork so they re-download on demand."

        guard imageCacheClearedAt != nil else { return base }
        return "\(base) Image cache cleared."
    }

    private var accountFooterText: String {
        "Clears the saved Plex session and returns to the sign-in flow."
    }

    private func loadServersAndShowPicker() async {
        isLoadingServers = true
        serverError = nil

        do {
            let servers = try await plexService.discoverServers()
            if servers.isEmpty {
                serverError = "No servers found."
            } else {
                availableServers = servers
                showServerPicker = true
            }
        } catch {
            serverError = error.localizedDescription
        }

        isLoadingServers = false
    }

    #if os(tvOS)
    @ViewBuilder
    private var tvPlaybackSection: some View {
        @Bindable var preferences = preferences

        TVSettingsSection(title: "Playback", footer: playbackFooterText) {
            TVSettingsMenuRow(
                title: "Max Resolution",
                options: MaxResolution.allCases,
                selection: $preferences.maxResolution,
                selectedTitle: preferences.maxResolution.displayName
            ) { $0.displayName }

            tvRowDivider

            TVSettingsMenuRow(
                title: "Subtitles",
                options: subtitleLanguageOptions,
                selection: subtitleLanguageBinding,
                selectedTitle: subtitleDisplayName(for: subtitleLanguageBinding.wrappedValue)
            ) { subtitleDisplayName(for: $0) }

            tvRowDivider

            TVSettingsMenuRow(
                title: "Audio",
                options: audioLanguageOptions,
                selection: $preferences.defaultAudioLanguage,
                selectedTitle: languageDisplayName(for: preferences.defaultAudioLanguage)
            ) { languageDisplayName(for: $0) }

            tvRowDivider

            TVSettingsToggleRow(title: "Force AVPlayer", isOn: $preferences.forceAVPlayer)

            tvRowDivider

            TVSettingsToggleRow(title: "Force VLCKit", isOn: $preferences.forceVLCKit)

            tvRowDivider

            TVSettingsToggleRow(title: "Player Debug Overlay", isOn: $preferences.playerDebugOverlayEnabled)
        }
    }

    @ViewBuilder
    private var tvServerSection: some View {
        TVSettingsSection(title: "Server", footer: serverError, footerColor: .red) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current Server")
                        .font(.headline)
                        .foregroundStyle(Color.duskTextPrimary)

                    if let server = plexService.connectedServer {
                        Text(server.name)
                            .foregroundStyle(Color.duskTextPrimary)
                        Text(connectionType)
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)
                    } else {
                        Text("Not connected")
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }

                Spacer()

                Circle()
                    .fill(plexService.connectedServer == nil ? Color.duskTextSecondary : Color.duskAccent)
                    .frame(width: 10, height: 10)
            }
            .frame(minHeight: 72)

            tvRowDivider

            TVSettingsActionRow(
                title: "Change Server",
                tint: Color.duskAccent,
                showsChevron: true,
                isLoading: isLoadingServers
            ) {
                Task { await loadServersAndShowPicker() }
            }
            .disabled(isLoadingServers)
        }
    }

    @ViewBuilder
    private var tvAppSection: some View {
        @Bindable var preferences = preferences

        TVSettingsSection(title: "App", footer: appFooterText) {
            TVSettingsMenuRow(
                title: "Appearance",
                options: AppearanceMode.allCases,
                selection: $preferences.appearanceMode,
                selectedTitle: preferences.appearanceMode.displayName
            ) { $0.displayName }

            tvRowDivider

            TVSettingsActionRow(
                title: "Clear Image Cache",
                tint: Color.duskAccent,
                detail: formattedCacheSize
            ) {
                AppImageCache.clear()
                imageCacheClearedAt = .now
                imageCacheSize = AppImageCache.shared.currentDiskUsage
            }

            tvRowDivider

            HStack(spacing: 20) {
                Text("Version")
                    .font(.headline)
                    .foregroundStyle(Color.duskTextPrimary)

                Spacer()

                Text(appVersion)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .frame(minHeight: 72)
        }
    }

    @ViewBuilder
    private var tvAccountSection: some View {
        TVSettingsSection(title: "Account", footer: accountFooterText) {
            TVSettingsActionRow(
                title: "Sign Out",
                tint: .red,
                role: .destructive
            ) {
                plexService.signOut()
            }
        }
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }
    #endif
}

#if os(tvOS)
private struct TVSettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    let footerColor: Color
    private let content: Content

    init(
        title: String,
        footer: String? = nil,
        footerColor: Color = Color.duskTextSecondary,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.footerColor = footerColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.duskTextPrimary)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.subheadline)
                    .foregroundStyle(footerColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct TVSettingsMenuRow<Option: Hashable>: View {
    let title: String
    let options: [Option]
    let selectedTitle: String
    let optionTitle: (Option) -> String
    @Binding var selection: Option

    init(
        title: String,
        options: [Option],
        selection: Binding<Option>,
        selectedTitle: String,
        optionTitle: @escaping (Option) -> String
    ) {
        self.title = title
        self.options = options
        self._selection = selection
        self.selectedTitle = selectedTitle
        self.optionTitle = optionTitle
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(optionTitle(option)).tag(option)
            }
        } label: {
            HStack(spacing: 20) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.duskTextPrimary)
            }
            .frame(minHeight: 72)
            .contentShape(Rectangle())
        }
        .pickerStyle(.navigationLink)
    }
}

private struct TVSettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 20) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)

            Spacer(minLength: 24)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle())
                .tint(Color.duskAccent)
        }
        .frame(minHeight: 72)
    }
}

private struct TVSettingsActionRow: View {
    let title: String
    let tint: Color
    let role: ButtonRole?
    let showsChevron: Bool
    let isLoading: Bool
    let detail: String?
    let action: () -> Void

    init(
        title: String,
        tint: Color,
        role: ButtonRole? = nil,
        showsChevron: Bool = false,
        isLoading: Bool = false,
        detail: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.tint = tint
        self.role = role
        self.showsChevron = showsChevron
        self.isLoading = isLoading
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Group {
            if let role {
                Button(role: role, action: action, label: label)
            } else {
                Button(action: action, label: label)
            }
        }
        .duskSuppressTVOSButtonChrome()
    }

    @ViewBuilder
    private func label() -> some View {
        HStack(spacing: 20) {
            Text(title)
                .font(.headline)
                .foregroundStyle(tint)

            Spacer()

            if isLoading {
                ProgressView()
                    .tint(Color.duskAccent)
            } else if let detail {
                Text(detail)
                    .foregroundStyle(Color.duskTextSecondary)
            } else if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
        .frame(minHeight: 72)
        .contentShape(Rectangle())
    }
}

#endif

// MARK: - Common Languages

/// A focused list of common languages for subtitle/audio preference pickers.
enum CommonLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case russian = "ru"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh"
    case arabic = "ar"
    case hindi = "hi"
    case swedish = "sv"
    case norwegian = "no"
    case danish = "da"
    case finnish = "fi"
    case polish = "pl"
    case czech = "cs"
    case turkish = "tr"
    case thai = "th"
    case vietnamese = "vi"
    case indonesian = "id"
    case malay = "ms"
    case hebrew = "he"

    var id: String { rawValue }
    var code: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .portuguese: "Portuguese"
        case .dutch: "Dutch"
        case .russian: "Russian"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .chinese: "Chinese"
        case .arabic: "Arabic"
        case .hindi: "Hindi"
        case .swedish: "Swedish"
        case .norwegian: "Norwegian"
        case .danish: "Danish"
        case .finnish: "Finnish"
        case .polish: "Polish"
        case .czech: "Czech"
        case .turkish: "Turkish"
        case .thai: "Thai"
        case .vietnamese: "Vietnamese"
        case .indonesian: "Indonesian"
        case .malay: "Malay"
        case .hebrew: "Hebrew"
        }
    }
}
