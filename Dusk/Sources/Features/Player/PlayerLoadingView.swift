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
    @Environment(PlaybackCoordinator.self) private var playback

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
                            // A fill-scaled image reports the scaled size, so
                            // without the clamp it makes this stack — and the
                            // top-trailing overlay measured against it — larger
                            // than the screen, pushing the AirPlay and Cancel
                            // buttons off the edge. `opaque: true` samples the
                            // artwork's own edges so the wash reaches the screen
                            // edges instead of fading to transparent corners.
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .blur(radius: 60, opaque: true)
                            .opacity(0.35)
                    } else {
                        Color.clear
                    }
                }
                .clipped()
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
                    Group {
                        switch placeholder.artwork {
                        case .poster:
                            PosterArtwork(imageURL: posterURL, width: posterWidth)
                        case .liveChannel(let logoPath):
                            channelArtwork(logoPath: logoPath)
                        }
                    }
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
            HStack(spacing: 12) {
                PlayerAirPlayControl(
                    isActive: playback.isAirPlayPlaybackActive,
                    symbolFont: .body.weight(.semibold)
                )
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                        .allowsHitTesting(false)
                }

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
                    .accessibilityLabel("Cancel")
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
        #endif
    }

    /// Channel logos are wide, square, or anything in between and usually ship
    /// with their own padding, so they get a centered square tile that fits the
    /// artwork rather than a poster frame that would crop or letterbox it. The
    /// tile is drawn whether or not a logo resolves, so a channel without one
    /// still reads as a channel instead of a blank poster.
    private func channelArtwork(logoPath: String?) -> some View {
        RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)
            .fill(.white.opacity(0.08))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous))
            .overlay {
                if let logoURL = channelLogoURL(for: logoPath) {
                    DuskAsyncImage(url: logoURL) { phase in
                        if case let .success(image) = phase {
                            image
                                .resizable()
                                .scaledToFit()
                        } else {
                            channelFallbackSymbol
                        }
                    }
                    .padding(channelTileSize * 0.16)
                } else {
                    channelFallbackSymbol
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
            .frame(width: channelTileSize, height: channelTileSize)
    }

    private var channelFallbackSymbol: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: channelTileSize * 0.3, weight: .regular))
            .foregroundStyle(.white.opacity(0.55))
    }

    private func channelLogoURL(for path: String?) -> URL? {
        plexService.imageURL(
            for: path,
            width: Int(channelTileSize * 2),
            height: Int(channelTileSize * 2)
        )
    }

    private var channelTileSize: CGFloat {
        #if os(tvOS)
        240
        #else
        160
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
