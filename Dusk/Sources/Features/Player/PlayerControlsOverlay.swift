import SwiftUI

struct PlayerControlsOverlay: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences

    let viewModel: PlayerViewModel
    #if os(tvOS)
    /// tvOS HUD state machine. Owned by `PlayerSessionView` so it outlives the
    /// overlay's visibility and can be driven by the remote bridge.
    let hudController: PlayerTVHUDController
    #endif
    let mediaDetails: PlexMediaDetails?
    let debugInfo: PlaybackDebugInfo?
    let scrubPreviewSource: PlexScrubPreviewSource?
    let controlsTopSafeAreaInset: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        Group {
            #if os(tvOS)
            PlayerControlsTVOverlay(
                viewModel: viewModel,
                controller: hudController,
                context: context,
                scrubPreviewSource: scrubPreviewSource
            )
            #elseif os(macOS)
            MacPlayerHUD(
                viewModel: viewModel,
                context: context,
                scrubPreviewSource: scrubPreviewSource,
                onDismiss: onDismiss
            )
            #else
            PlayerControlsIOSOverlay(
                viewModel: viewModel,
                context: context,
                scrubPreviewSource: scrubPreviewSource,
                controlsTopSafeAreaInset: controlsTopSafeAreaInset,
                onDismiss: onDismiss
            )
            #endif
        }
        // An audio switch onto an Atmos track can keep the session (and the
        // chosen rate); fall back to 1× rather than leave it unreachable.
        .onChange(of: speedControl) { _, availability in
            if availability == .unavailableWithDolbyAtmos {
                viewModel.setPlaybackRate(1)
            }
        }
    }

    /// Advanced playback controls (Settings › Playback Advanced) add the skip
    /// buttons and the speed control. Live TV has no skip target worth a
    /// button and no rate to change.
    private var showsAdvancedPlaybackControls: Bool {
        preferences.playerAdvancedControlsEnabled && !viewModel.isLiveTV
    }

    /// Speed follows the hold-to-2× guards (no SharePlay group following
    /// along). On tvOS an AVPlayer session with a Dolby Atmos track bitstreams
    /// it to the receiver/TV over HDMI, which only plays at 1×, so the control
    /// stays visible but explains itself instead of offering rates. VLCKit
    /// always decodes to PCM, and iOS renders Atmos on device, so both keep it.
    private var speedControl: PlayerSpeedControlAvailability {
        guard showsAdvancedPlaybackControls, !playback.isSharePlayActive else { return .hidden }
        #if os(tvOS)
        if let debugInfo, debugInfo.engine == .avPlayer,
           playback.activeAudioStreamIsDolbyAtmos(in: debugInfo.part) {
            return .unavailableWithDolbyAtmos
        }
        #endif
        return .available
    }

    private var context: PlayerControlsContext {
        PlayerControlsContext(
            mediaHeader: mediaHeader,
            summary: summary,
            subtitleControlTitle: subtitleControlTitle,
            audioControlTitle: audioControlTitle,
            qualityControlTitle: qualityControlTitle,
            selectedQualityPreset: debugInfo?.qualityPreset ?? .original,
            availableQualityPresets: debugInfo?.availableQualityPresets ?? [.original],
            hasPlaybackInfo: debugInfo != nil,
            canDownloadSubtitles: plexService.canDownloadSubtitles(
                serverID: playback.activePlaybackServerID
            ) && !viewModel.isLiveTV,
            hasQualityControl: debugInfo != nil && !viewModel.isLiveTV,
            canSelectQuality: debugInfo?.canSelectPlaybackQuality == true &&
                !playback.isAirPlayPlaybackActive,
            isChangingQuality: playback.isSwitchingQuality,
            hasSharePlayControl: playback.canSharePlayCurrentPlayback,
            isSharePlayActive: playback.isSharePlayActive,
            isStartingSharePlay: playback.isSharePlayStarting,
            sharePlayParticipantCount: playback.sharePlayParticipantCount,
            liveTVContext: viewModel.liveTVContext,
            showsSkipButtons: showsAdvancedPlaybackControls,
            speedControl: speedControl
        )
    }

    /// Synopsis for the tvOS panel's Info tab. Live sessions describe the
    /// program on the bar, not the one that was airing at tune time.
    private var summary: String? {
        if viewModel.isLiveTV {
            return viewModel.liveProgram?.summary
        }
        return mediaDetails?.summary ?? viewModel.iptvCatchUp?.program.summary
    }

    private var mediaHeader: PlayerMediaHeader? {
        if let liveTVContext = viewModel.liveTVContext {
            // The program the play bar is on, not the one that was airing at
            // tune time — the schedule rolls over during long sessions, and a
            // rewind can land in the previous program. Series lead, so the
            // header answers "what show is this" before "which episode".
            let program = viewModel.liveProgram
            return PlayerMediaHeader(
                title: program?.primaryDisplayTitle ?? liveTVContext.channel.displayTitle,
                secondaryTitle: program?.episodeDisplayTitle,
                subtitle: liveTVContext.channel.displayTitle,
                usesCompactTitleOnTV: true
            )
        }

        if mediaDetails == nil, let catchUp = viewModel.iptvCatchUp {
            return PlayerMediaHeader(
                title: catchUp.program.primaryDisplayTitle,
                secondaryTitle: catchUp.program.episodeDisplayTitle,
                subtitle: catchUp.subtitle,
                usesCompactTitleOnTV: true
            )
        }

        guard let mediaDetails else { return nil }

        if mediaDetails.type == .episode {
            let title = mediaDetails.grandparentTitle ?? mediaDetails.title
            let secondaryTitle = mediaDetails.grandparentTitle == nil ? nil : mediaDetails.title
            let subtitle = MediaTextFormatter.seasonEpisodeLabel(
                season: mediaDetails.parentIndex,
                episode: mediaDetails.index
            )

            return PlayerMediaHeader(
                title: title,
                secondaryTitle: secondaryTitle,
                subtitle: subtitle,
                usesCompactTitleOnTV: true
            )
        }

        return PlayerMediaHeader(
            title: mediaDetails.title,
            secondaryTitle: nil,
            subtitle: MediaTextFormatter.joinedWithEdition(mediaDetails.year.map(String.init), edition: mediaDetails.editionTitle),
            usesCompactTitleOnTV: false
        )
    }

    private var subtitleControlTitle: String {
        if let selectedSubtitleTrack = viewModel.selectedSubtitleTrack {
            return selectedSubtitleTrack.displayTitle
        }

        return viewModel.state == .loading ? "..." : "No Subtitles"
    }

    private var audioControlTitle: String {
        if let selectedAudioTrack = viewModel.selectedAudioTrack {
            return selectedAudioTrack.compactDisplayTitle
        }

        return viewModel.state == .loading ? "..." : "-"
    }

    private var qualityControlTitle: String {
        guard let debugInfo else { return "Unavailable" }
        if playback.isAirPlayPlaybackActive { return "AirPlay" }
        if !debugInfo.canSelectPlaybackQuality {
            if case .airPlay = debugInfo.decision { return "AirPlay" }
            return viewModel.isLiveTV ? "Live" : "Unavailable Offline"
        }
        return debugInfo.qualityPreset.displayName
    }
}

struct PlayerControlsContext {
    let mediaHeader: PlayerMediaHeader?
    /// Item synopsis (or the live program's), used by the tvOS panel's Info tab.
    let summary: String?
    let subtitleControlTitle: String
    let audioControlTitle: String
    let qualityControlTitle: String
    let selectedQualityPreset: PlaybackQualityPreset
    let availableQualityPresets: [PlaybackQualityPreset]
    let hasPlaybackInfo: Bool
    /// Whether the session may install a sidecar subtitle from Plex's
    /// OpenSubtitles search (server owner, non-restricted user, not Live TV).
    let canDownloadSubtitles: Bool
    let hasQualityControl: Bool
    let canSelectQuality: Bool
    let isChangingQuality: Bool
    let hasSharePlayControl: Bool
    let isSharePlayActive: Bool
    let isStartingSharePlay: Bool
    let sharePlayParticipantCount: Int
    let liveTVContext: PlexLivePlaybackContext?
    /// Skip back / forward buttons (advanced playback controls).
    let showsSkipButtons: Bool
    let speedControl: PlayerSpeedControlAvailability
}

enum PlayerSpeedControlAvailability: Equatable {
    /// Advanced playback controls are off, or the session cannot change rate.
    case hidden
    case available
    /// Shown, but without rates: the Atmos bitstream only plays at 1×.
    case unavailableWithDolbyAtmos

    static let unavailableMessage = "Not available with Dolby Atmos"
}

struct PlayerMediaHeader {
    let title: String
    let secondaryTitle: String?
    let subtitle: String?
    let usesCompactTitleOnTV: Bool
}
