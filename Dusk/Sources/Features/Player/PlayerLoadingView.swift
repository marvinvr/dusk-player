import SwiftUI

/// Full-screen "preparing playback" state shown inside the player cover while
/// the metadata fetch and engine startup run. Presenting this the instant the
/// user presses Play (before the `getMediaDetails` round-trip) makes playback
/// feel snappy: the poster and title of the chosen item appear immediately,
/// while `PlayerView` owns the one persistent spinner used by every loading
/// phase. A `nil` placeholder degrades to the shared bare spinner (e.g.
/// programmatic playback with no known metadata).
struct PlayerLoadingView: View {
    @Environment(PlexService.self) private var plexService

    let placeholder: PlaybackPlaceholder?
    /// Backs out of a load before it resolves. On iOS this is the only escape
    /// from the cover while loading (`fullScreenCover` isn't swipe-dismissable);
    /// tvOS uses the Menu/exit command instead.
    var onCancel: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let backdropURL {
                DuskAsyncImage(url: backdropURL) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 32)
                            .opacity(0.35)
                    } else {
                        Color.clear
                    }
                }
                .ignoresSafeArea()
            }

            LinearGradient(
                colors: [.black.opacity(0.25), .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                if let placeholder {
                    PosterArtwork(imageURL: posterURL, width: posterWidth)
                        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)

                    VStack(spacing: 6) {
                        Text(placeholder.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        if let subtitle = placeholder.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                        }
                    }
                }

                // PlayerView draws the actual shared spinner in this reserved
                // slot so the original poster-led layout stays unchanged.
                Color.clear
                    .frame(width: 20, height: 20)
                    .padding(.top, placeholder == nil ? 0 : 6)
            }
            .padding(40)
        }
        #if !os(tvOS)
        .overlay(alignment: .topTrailing) {
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                        }
                }
                .padding(.top, 12)
                .padding(.trailing, 16)
                .accessibilityLabel("Cancel")
            }
        }
        #endif
    }

    private var posterWidth: CGFloat {
        #if os(tvOS)
        240
        #else
        150
        #endif
    }

    private var posterURL: URL? {
        guard let path = placeholder?.posterPath else { return nil }
        return plexService.imageURL(
            for: path,
            width: Int(posterWidth),
            height: Int(posterWidth * 1.5)
        )
    }

    private var backdropURL: URL? {
        guard let path = placeholder?.backdropPath else { return nil }
        return plexService.imageURL(for: path, width: 1280, height: 720)
    }
}
