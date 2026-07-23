import SwiftUI

struct SettingsTVView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @Environment(SupporterStore.self) private var supporterStore
    let viewModel: SettingsViewModel
    @State private var showsSupporterSheet = false

    var body: some View {
        SettingsContainer(viewModel: viewModel) {
            settingsContent
        }
        .sheet(isPresented: $showsSupporterSheet) {
            SupporterView(context: .settings)
        }
    }

    private var settingsContent: some View {
        @Bindable var preferences = preferences
        let subtitleLanguageBinding = SettingsSupport.subtitleLanguageBinding(preferences)

        return ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                Text("Settings")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Color.duskTextPrimary)
                    .padding(.leading, TVSettingsMetrics.contentInset)

                TVSettingsSection(title: "Support", footer: SettingsSupport.supporterFooterText) {
                    TVSettingsActionRow(
                        title: supporterStore.isSupporter ? "You're a Supporter ❤️" : "Support Dusk",
                        tint: Color.duskTextPrimary,
                        showsChevron: true
                    ) {
                        showsSupporterSheet = true
                    }
                }

                if plexService.homeUsers.count > 1, let activeUser = plexService.activeHomeUser {
                    TVSettingsSection(
                        title: "Plex Home",
                        footer: "When off, Dusk asks who’s watching whenever it starts."
                    ) {
                        HStack(spacing: 20) {
                            PlexHomeUserAvatar(user: activeUser, size: 58)

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Current User")
                                    .font(.caption)
                                    .foregroundStyle(Color.duskTextSecondary)

                                Text(activeUser.displayName)
                                    .font(.headline)
                                    .foregroundStyle(Color.duskTextPrimary)
                                    .lineLimit(1)
                            }

                            Spacer()
                        }
                        .frame(minHeight: 78)

                        tvRowDivider

                        TVSettingsActionRow(
                            title: "Switch User",
                            tint: Color.duskAccent,
                            showsChevron: true
                        ) {
                            viewModel.showHomeUserPicker = true
                        }

                        tvRowDivider

                        TVSettingsToggleRow(
                            title: "Automatically Sign In",
                            isOn: automaticHomeSignInBinding
                        )
                    }
                }

                if viewModel.hasMultipleServers {
                    TVSettingsSection(title: "Plex Server") {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Current Server")
                                    .font(.headline)
                                    .foregroundStyle(Color.duskTextPrimary)

                                if let server = plexService.connectedServer {
                                    Text(server.name)
                                        .foregroundStyle(Color.duskTextPrimary)
                                    Text(viewModel.connectionType)
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
                            showsChevron: true
                        ) {
                            viewModel.showServerPicker = true
                        }
                    }
                }

                TVSettingsSection(title: "Playback Defaults", footer: SettingsSupport.playbackDefaultsFooterText) {
                    TVSettingsMenuRow(
                        title: "Max Resolution",
                        options: MaxResolution.allCases,
                        selection: $preferences.maxResolution,
                        selectedTitle: preferences.maxResolution.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Subtitles",
                        options: SettingsSupport.subtitleLanguageOptions,
                        selection: subtitleLanguageBinding,
                        selectedTitle: SettingsSupport.subtitleDisplayName(for: subtitleLanguageBinding.wrappedValue)
                    ) { SettingsSupport.subtitleDisplayName(for: $0) }

                    tvRowDivider

                    TVSettingsToggleRow(title: "Forced Only", isOn: $preferences.subtitleForcedOnly)

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Audio",
                        options: SettingsSupport.audioLanguageOptions,
                        selection: $preferences.defaultAudioLanguage,
                        selectedTitle: SettingsSupport.languageDisplayName(for: preferences.defaultAudioLanguage)
                    ) { SettingsSupport.languageDisplayName(for: $0) }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "AI Upscaling",
                        options: VideoEnhancementMode.allCases,
                        selection: $preferences.videoEnhancementMode,
                        selectedTitle: preferences.videoEnhancementMode.displayName
                    ) { $0.displayName }
                }

                TVSettingsSection(title: "Playback Behavior", footer: SettingsSupport.playbackBehaviorFooterText) {
                    TVSettingsMenuRow(
                        title: "Auto-Skip Intros",
                        options: AutoSkipIntroMode.allCases,
                        selection: $preferences.autoSkipIntroMode,
                        selectedTitle: preferences.autoSkipIntroMode.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsToggleRow(title: "Auto-Skip Credits", isOn: $preferences.autoSkipCredits)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Continuous Play", isOn: $preferences.continuousPlayEnabled)

                    if preferences.continuousPlayEnabled {
                        tvRowDivider

                        TVSettingsMenuRow(
                            title: "Next Episode Delay",
                            options: ContinuousPlayCountdown.allCases,
                            selection: $preferences.continuousPlayCountdown,
                            selectedTitle: preferences.continuousPlayCountdown.displayName
                        ) { $0.displayName }

                        tvRowDivider

                        TVSettingsMenuRow(
                            title: "Pause After",
                            options: SettingsSupport.passoutProtectionEpisodeOptions,
                            selection: $preferences.continuousPlayPassoutProtectionEpisodeLimit,
                            selectedTitle: SettingsSupport.passoutProtectionDisplayName(
                                for: preferences.continuousPlayPassoutProtectionEpisodeLimit
                            )
                        ) {
                            SettingsSupport.passoutProtectionDisplayName(for: $0)
                        }
                    }
                }

                TVSettingsSection(title: "Appearance", footer: SettingsSupport.appearanceFooterText) {
                    TVSettingsMenuRow(
                        title: "Appearance",
                        options: AppearanceMode.allCases,
                        selection: $preferences.appearanceMode,
                        selectedTitle: preferences.appearanceMode.displayName
                    ) { $0.displayName }
                }

                TVSettingsSection(title: "Playback Advanced", footer: SettingsSupport.playbackAdvancedFooterText) {
                    TVSettingsToggleRow(title: "Force AVPlayer", isOn: $preferences.forceAVPlayer)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Force VLCKit", isOn: $preferences.forceVLCKit)
                }

                TVSettingsSection(title: "Storage", footer: viewModel.storageFooterText) {
                    TVSettingsActionRow(
                        title: "Clear Image Cache",
                        tint: Color.duskAccent,
                        detail: viewModel.formattedCacheSize
                    ) {
                        viewModel.clearImageCache()
                    }
                }

                TVSettingsSection(title: "About", footer: SettingsSupport.aboutFooterText) {
                    HStack(spacing: 20) {
                        Text("Version")
                            .font(.headline)
                            .foregroundStyle(Color.duskTextPrimary)

                        Spacer()

                        Text(viewModel.appVersion)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                    .frame(minHeight: 72)

                    tvRowDivider

                    TVSettingsExternalLinkRow(
                        title: "About Me",
                        subtitle: "marvinvr.ch"
                    )

                    tvRowDivider

                    TVSettingsExternalLinkRow(
                        title: "GitHub",
                        subtitle: "github.com/marvinvr/dusk-player"
                    )

                    tvRowDivider

                    TVSettingsExternalLinkRow(
                        title: "Feedback",
                        subtitle: "info@getdusk.app"
                    )
                }

                TVSettingsSection(title: "Account", footer: SettingsSupport.accountFooterText) {
                    TVSettingsActionRow(
                        title: "Sign Out",
                        tint: .red,
                        role: .destructive
                    ) {
                        plexService.signOut()
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }

    private var automaticHomeSignInBinding: Binding<Bool> {
        Binding(
            get: { plexService.automaticHomeSignIn },
            set: { plexService.automaticHomeSignIn = $0 }
        )
    }
}
