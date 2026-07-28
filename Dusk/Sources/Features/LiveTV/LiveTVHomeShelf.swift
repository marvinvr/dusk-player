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
                VStack(alignment: .leading, spacing: 12) {
                    Text("Live TV")
                        .font(.title2.bold())
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
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                                .duskTVOSFocusEffectShape(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                            }
                        }
                        .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }
}
