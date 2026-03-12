import SwiftUI

struct EpisodeRowView: View {
    let episode: PlexEpisode
    let thumbURL: URL?
    var onToggleWatched: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Thumbnail
            ZStack(alignment: .bottomLeading) {
                if let url = thumbURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(16/9, contentMode: .fill)
                        default:
                            Color.duskSurface
                                .aspectRatio(16/9, contentMode: .fill)
                        }
                    }
                } else {
                    Color.duskSurface
                        .aspectRatio(16/9, contentMode: .fill)
                }

                // Progress bar
                if episode.isPartiallyWatched,
                   let offset = episode.viewOffset, let duration = episode.duration, duration > 0 {
                    GeometryReader { geo in
                        let progress = min(1.0, Double(offset) / Double(duration))
                        VStack {
                            Spacer()
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.2))
                                    .frame(height: 3)
                                Rectangle()
                                    .fill(Color.duskAccent)
                                    .frame(width: geo.size.width * progress, height: 3)
                            }
                        }
                    }
                }
            }
            .frame(width: 140)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                if episode.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.duskAccent)
                }

                Text(primaryTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.duskTextPrimary)
                    .lineLimit(2)

                if let duration = formattedDuration {
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                }

                if let summary = episode.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onToggleWatched?()
            } label: {
                Label(
                    episode.isWatched ? "Mark Unwatched" : "Mark Watched",
                    systemImage: episode.isWatched ? "eye.slash" : "eye"
                )
            }
        }
    }

    private var formattedDuration: String? {
        guard let ms = episode.duration, ms > 0 else { return nil }
        let totalMinutes = ms / 60_000
        return "\(totalMinutes) min"
    }

    private var primaryTitle: String {
        guard let label = episode.episodeLabel else { return episode.title }
        return "\(label) - \(episode.title)"
    }
}
