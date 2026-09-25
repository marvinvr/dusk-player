import SwiftUI

struct SettingsTVView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(SeerrService.self) private var seerrService
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
                    .font(DuskFont.pageTitle(ios: .title.weight(.bold)))
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
                        HStack(spacing: 22) {
                            PlexHomeUserAvatar(user: activeUser, size: 68)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Current User")
                                    .font(DuskFont.badge(ios: .caption.weight(.semibold)))
                                    .textCase(.uppercase)
                                    .tracking(0.5)
                                    .foregroundStyle(Color.duskTextSecondary)

                                Text(activeUser.displayName)
                                    .font(DuskFont.rowTitle(ios: .headline.weight(.semibold)))
                                    .foregroundStyle(Color.duskTextPrimary)
                                    .lineLimit(1)
                            }

                            Spacer()
                        }
                        .frame(minHeight: 100)
                        .padding(.vertical, 14)

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

                TVSettingsSection(
                    title: "Integrations",
                    footer: "Optionally add requestable movies and shows to search."
                ) {
                    TVSettingsNavigationRow(
                        title: "Seerr",
                        detail: seerrService.connectionSubtitle
                    ) {
                        SeerrSettingsView()
                    }
                }

                TVSettingsSection(
                    title: "Navigation",
                    footer: SettingsSupport.navigationFooterText
                ) {
                    TVSettingsNavigationRow(
                        title: "Navigation Tabs",
                        detail: SettingsSupport.libraryTabsSummary(preferences)
                    ) {
                        LibraryTabSettingsView()
                    }

                    tvRowDivider

                    TVSettingsNavigationRow(
                        title: "Library Order",
                        detail: SettingsSupport.libraryOrderSummary(plexService)
                    ) {
                        LibraryOrderSettingsView()
                    }

                    tvRowDivider

                    TVSettingsNavigationRow(
                        title: "Server Priority",
                        detail: SettingsSupport.serverPrioritySummary(plexService)
                    ) {
                        ServerPrioritySettingsView()
                    }
                }

                TVSettingsSection(title: "Home", footer: SettingsSupport.homeFooterText) {
                    TVSettingsToggleRow(title: "Show Live TV", isOn: $preferences.showsLiveTVOnHome)
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
                        title: "Subtitle Size",
                        options: SubtitleFontSize.allCases,
                        selection: $preferences.subtitleFontSize,
                        selectedTitle: preferences.subtitleFontSize.displayName
                    ) { $0.displayName }

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
                    TVSettingsToggleRow(title: "Dolby Atmos", isOn: $preferences.spatialAudioRemuxEnabled)

                    tvRowDivider

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

                TVSettingsSection(title: "Privacy", footer: SettingsSupport.privacyFooterText) {
                    TVSettingsToggleRow(title: "Help Improve Dusk", isOn: $preferences.analyticsEnabled)
                }

                TVSettingsSection(title: "About", footer: SettingsSupport.aboutFooterText) {
                    HStack(spacing: 20) {
                        Text("Version")
                            .font(DuskFont.rowTitle(ios: .headline))
                            .foregroundStyle(Color.duskTextPrimary)

                        Spacer()

                        Text(viewModel.appVersion)
                            .duskFont(tvOnly: DuskFont.TV.rowValue)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                    .frame(minHeight: TVSettingsMetrics.rowMinHeight)

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
