import SwiftUI

struct PlayerControlsOverlay: View {
    let viewModel: PlayerViewModel
    let mediaDetails: PlexMediaDetails?
    let hasActiveSkipMarker: Bool
    let onDismiss: () -> Void

    var body: some View {
        #if os(tvOS)
        PlayerControlsTVOverlay(
            viewModel: viewModel,
            context: context,
            hasActiveSkipMarker: hasActiveSkipMarker,
            onDismiss: onDismiss
        )
        #else
        PlayerControlsIOSOverlay(
            viewModel: viewModel,
            context: context,
            onDismiss: onDismiss
        )
        #endif
    }

    private var context: PlayerControlsContext {
        PlayerControlsContext(
            mediaHeader: mediaHeader,
            subtitleControlTitle: subtitleControlTitle,
            audioControlTitle: audioControlTitle
        )
    }

    private var mediaHeader: PlayerMediaHeader? {
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
                subtitle: subtitle
            )
        }

        return PlayerMediaHeader(
            title: mediaDetails.title,
            secondaryTitle: nil,
            subtitle: mediaDetails.year.map(String.init)
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
            return selectedAudioTrack.displayTitle
        }

        return viewModel.state == .loading ? "..." : "-"
    }
}

struct PlayerControlsContext {
    let mediaHeader: PlayerMediaHeader?
    let subtitleControlTitle: String
    let audioControlTitle: String
}

struct PlayerMediaHeader {
    let title: String
    let secondaryTitle: String?
    let subtitle: String?
}
