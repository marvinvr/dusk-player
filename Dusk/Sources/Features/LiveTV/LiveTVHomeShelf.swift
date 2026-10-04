import SwiftUI

struct LiveTVHomeShelf: View {
    let viewModel: LiveTVViewModel
    let play: (PlexLiveChannel, PlexLiveProgram, PlexLiveTVLineup) -> Void

    var body: some View {
        if let lineup = viewModel.nowPlayingLineup {
            let currentPrograms = lineup.guides.compactMap { guide -> (PlexLiveChannel, PlexLiveProgram)? in
                guard let program = guide.currentProgram() else { return nil }
                return (guide.channel, program)
            }

            if !currentPrograms.isEmpty {
                VStack(alignment: .leading, spacing: DuskPosterMetrics.carouselSectionSpacing) {
                    Text("Live TV")
                        .font(DuskFont.sectionHeader(ios: .title2.bold()))
                        .foregroundStyle(Color.duskTextPrimary)
                        .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)

                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(currentPrograms, id: \.1.id) { channel, program in
                                Button {
                                    play(channel, program, lineup)
                                } label: {
                                    LiveTVProgramCard(
                                        program: program,
                                        imageURL: viewModel.imageURL(
                                            for: program.preferredLandscapePath,
                                            width: 640,
                                            height: 360
                                        ),
                                        channelLogoURL: viewModel.imageURL(
                                            for: channel.thumb,
                                            width: 256,
                                            height: 256
                                        )
                                    )
                                }
                                // tvOS: Home disables this shelf while its
                                // hero is up, and `.plain` may dim a disabled
                                // button. The innermost style wins.
                                .duskSuppressTVOSButtonChrome()
                                .buttonStyle(.plain)
                                .duskTVOSFocusEffectShape(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .carouselLeadingFocusTarget()
                                .carouselItemFocusLock(isLeadingItem: program.id == currentPrograms.first?.1.id)
                            }
                        }
                        .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)
                    }
                    .scrollIndicators(.hidden)
                    .carouselLeadingFocusLock(leadingInset: DuskPosterMetrics.carouselHorizontalPadding)
                }
            }
        }
    }
}
