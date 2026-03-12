import SwiftUI

struct PosterArtwork: View {
    let imageURL: URL?
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0

    var body: some View {
        ZStack(alignment: .bottom) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    placeholder
                default:
                    placeholder
                }
            }
            .frame(width: width, height: imageHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if let progress, progress > 0 {
                GeometryReader { geo in
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white.opacity(0.3))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.duskAccent)
                                .frame(width: geo.size.width * min(progress, 1.0), height: 3)
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
                .frame(width: width, height: imageHeight)
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.duskSurface)
            .frame(width: width, height: imageHeight)
            .overlay {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(Color.duskTextSecondary)
            }
    }

    private var imageHeight: CGFloat {
        guard imageAspectRatio > 0 else { return width * 1.5 }
        return width / imageAspectRatio
    }
}

struct PosterCardText: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.duskTextPrimary)
                .lineLimit(2)
                .frame(width: width, alignment: .leading)

            subtitleRow
        }
    }

    @ViewBuilder
    private var subtitleRow: some View {
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(Color.duskTextSecondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        } else {
            Text(" ")
                .font(.caption2)
                .hidden()
                .frame(width: width, alignment: .leading)
        }
    }
}

/// Reusable poster card with async image, title, and optional progress bar.
struct PosterCard: View {
    let imageURL: URL?
    let title: String
    var subtitle: String?
    /// 0...1 progress for partially watched items. Nil hides the bar.
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterArtwork(
                imageURL: imageURL,
                progress: progress,
                width: width,
                imageAspectRatio: imageAspectRatio
            )

            PosterCardText(
                title: title,
                subtitle: subtitle,
                width: width
            )
        }
        .frame(width: width, alignment: .topLeading)
    }
}
