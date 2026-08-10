import SwiftUI

struct PlayerControlsOverlay: View {
    @Environment(PlaybackCoordinator.self) private var playback

    let viewModel: PlayerViewModel
    let mediaDetails: PlexMediaDetails?
    let debugInfo: PlaybackDebugInfo?
    let scrubPreviewSource: PlexScrubPreviewSource?
    let hasActiveSkipMarker: Bool
    let controlsTopSafeAreaInset: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        #if os(tvOS)
        PlayerControlsTVOverlay(
            viewModel: viewModel,
            context: context,
            scrubPreviewSource: scrubPreviewSource,
            hasActiveSkipMarker: hasActiveSkipMarker
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

    private var context: PlayerControlsContext {
        PlayerControlsContext(
            mediaHeader: mediaHeader,
            subtitleControlTitle: subtitleControlTitle,
            audioControlTitle: audioControlTitle,
            qualityControlTitle: qualityControlTitle,
            selectedQualityPreset: debugInfo?.qualityPreset ?? .original,
            availableQualityPresets: debugInfo?.availableQualityPresets ?? [.original],
            hasPlaybackInfo: debugInfo != nil,
            hasQualityControl: debugInfo != nil && !viewModel.isLiveTV,
            canSelectQuality: debugInfo?.canSelectPlaybackQuality == true,
            isChangingQuality: playback.isSwitchingQuality,
            liveTVContext: viewModel.liveTVContext
        )
    }

    private var mediaHeader: PlayerMediaHeader? {
        if let liveTVContext = viewModel.liveTVContext {
            // The program the play bar is on, not the one that was airing at
            // tune time — the schedule rolls over during long sessions, and a
            // rewind can land in the previous program.
            return PlayerMediaHeader(
                title: viewModel.liveProgram?.displayTitle ?? liveTVContext.channel.displayTitle,
                secondaryTitle: nil,
                subtitle: [liveTVContext.channel.displayNumber, liveTVContext.channel.displayTitle]
                    .compactMap { $0 }
                    .joined(separator: " · "),
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
            subtitle: mediaDetails.year.map(String.init),
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
        if !debugInfo.canSelectPlaybackQuality {
            return viewModel.isLiveTV ? "Live" : "Unavailable Offline"
        }
        return debugInfo.qualityPreset.displayName
    }
}

struct PlayerControlsContext {
    let mediaHeader: PlayerMediaHeader?
    let subtitleControlTitle: String
    let audioControlTitle: String
    let qualityControlTitle: String
    let selectedQualityPreset: PlaybackQualityPreset
    let availableQualityPresets: [PlaybackQualityPreset]
    let hasPlaybackInfo: Bool
    let hasQualityControl: Bool
    let canSelectQuality: Bool
    let isChangingQuality: Bool
    let liveTVContext: PlexLivePlaybackContext?
}

struct PlayerMediaHeader {
    let title: String
    let secondaryTitle: String?
    let subtitle: String?
    let usesCompactTitleOnTV: Bool
}
