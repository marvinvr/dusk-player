import SwiftUI

/// The small "next episode" poster shown in the bottom-right of the player over
/// the play bar once the credits marker is reached. It replaces the old "Skip
/// Credits" button.
///
/// - Tapping it (or pressing Select on tvOS) plays the next episode immediately.
/// - In `timedAutoplay` mode it shows a countdown; when it reaches zero the next
///   episode plays automatically without the full-screen Up Next screen.
/// - Dragging it down (iOS) / swiping down (tvOS) dismisses the poster and
///   cancels any pending auto-advance, letting the current episode play out to
///   its end. The full-screen Up Next screen then appears when it finishes.
struct PlayerUpNextPosterView: View {
    let presentation: UpNextPosterPresentation
    let plexService: PlexService
    let onPlayNow: () -> Void
    let onDismiss: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #else
    @GestureState private var dragTranslation: CGSize = .zero
    #endif

    var body: some View {
        VStack {
            Spacer()

            HStack {
                Spacer()
                card
            }
        }
        .padding(.horizontal, PlayerOverlayLayout.controlsHorizontalPadding)
        .padding(.bottom, max(PlayerOverlayLayout.skipMarkerBottomInset, 24))
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Card

    private var card: some View {
        #if os(tvOS)
        Button(action: onPlayNow) {
            cardContent
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .duskSuppressTVOSButtonChrome()
        .contentShape(.interaction, cardShape)
        .focusEffectDisabled()
        .duskTVOSFocusedScale(isFocused)
        .onMoveCommand { direction in
            if direction == .down {
                onDismiss()
            }
        }
        .onAppear {
            Task { @MainActor in isFocused = true }
        }
        .accessibilityLabel(accessibilityLabel)
        #else
        cardContent
            .contentShape(cardShape)
            .offset(y: liveDragOffset)
            .opacity(dragOpacity)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: dragTranslation)
            .onTapGesture(perform: onPlayNow)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .updating($dragTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        let isDownwardDrag = value.translation.height > 64 &&
                            value.translation.height > abs(value.translation.width)
                        if isDownwardDrag {
                            onDismiss()
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Swipe down to dismiss")
        #endif
    }

    private var cardContent: some View {
        HStack(alignment: .center, spacing: Metrics.contentSpacing) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                Text("UP NEXT")
                    .font(Metrics.eyebrowFont)
                    .tracking(1.3)
                    .foregroundStyle(Color.duskAccent)

                Text(presentation.episode.title)
                    .font(Metrics.titleFont)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let metadata = metadataText {
                    Text(metadata)
                        .font(Metrics.metaFont.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                if presentation.isTimed {
                    countdownRow
                        .padding(.top, 2)
                }
            }
            .frame(width: Metrics.textColumnWidth, alignment: .leading)
        }
        .padding(Metrics.cardPadding)
        .background {
            cardShape
                .fill(.ultraThinMaterial)
                .overlay {
                    cardShape.fill(Color.black.opacity(0.18))
                }
        }
        .overlay {
            cardShape
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .clipShape(cardShape)
        .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
    }

    private var thumbnail: some View {
        ZStack {
            DuskAsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    placeholderFill
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.32)],
                startPoint: .center,
                endPoint: .bottom
            )

            playOverlay
        }
        .frame(width: Metrics.thumbnailWidth, height: Metrics.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbnailCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.thumbnailCornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var playOverlay: some View {
        if presentation.isStarting {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: Metrics.playCircleSize, height: Metrics.playCircleSize)
                ProgressView()
                    .tint(.white)
            }
        } else {
            // Matches the seasons/episode page play icon (`PosterArtwork`).
            Image(systemName: "play.fill")
                .font(.system(size: Metrics.playSymbolSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(Metrics.playSymbolPadding)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
    }

    private var placeholderFill: some View {
        Color.duskSurface
            .overlay {
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundStyle(Color.duskTextSecondary)
            }
    }

    private var countdownRow: some View {
        let progress = min(max(presentation.countdownProgress ?? 0, 0), 1)

        return VStack(alignment: .leading, spacing: 5) {
            if let secondsRemaining = presentation.secondsRemaining {
                Text(presentation.isStarting ? "Playing…" : "Plays in \(secondsRemaining)s")
                    .font(Metrics.metaFont.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))

                    Capsule()
                        .fill(Color.duskAccent)
                        .frame(width: geometry.size.width * progress)
                        .animation(.linear(duration: 0.1), value: progress)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - Data

    private var thumbnailURL: URL? {
        plexService.imageURL(
            for: presentation.episode.thumb
                ?? presentation.episode.art
                ?? presentation.episode.grandparentThumb,
            width: 640,
            height: 360
        )
    }

    private var metadataText: String? {
        [
            MediaTextFormatter.seasonEpisodeLabel(
                season: presentation.episode.parentIndex,
                episode: presentation.episode.index
            ),
            MediaTextFormatter.shortDuration(milliseconds: presentation.episode.duration),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    }

    private var accessibilityLabel: String {
        "Play next episode: \(presentation.episode.title)"
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
    }

    #if !os(tvOS)
    /// Follows the finger downward (with resistance) while dragging, so the pull
    /// to dismiss the poster feels physical.
    private var liveDragOffset: CGFloat {
        max(0, dragTranslation.height) * 0.55
    }

    private var dragOpacity: Double {
        guard dragTranslation.height > 0 else { return 1 }
        return max(0.6, 1 - Double(dragTranslation.height) / 260)
    }
    #endif
}

private enum Metrics {
    #if os(tvOS)
    static let thumbnailWidth: CGFloat = 248
    static let thumbnailCornerRadius: CGFloat = 18
    static let cardCornerRadius: CGFloat = 28
    static let cardPadding: CGFloat = 20
    static let contentSpacing: CGFloat = 20
    static let textColumnWidth: CGFloat = 320
    static let playSymbolSize: CGFloat = 34
    static let playSymbolPadding: CGFloat = 18
    static let playCircleSize: CGFloat = 70
    static let eyebrowFont: Font = .caption.weight(.bold)
    static let titleFont: Font = .title3.weight(.semibold)
    static let metaFont: Font = .subheadline
    #else
    static let thumbnailWidth: CGFloat = 116
    static let thumbnailCornerRadius: CGFloat = 14
    static let cardCornerRadius: CGFloat = 22
    static let cardPadding: CGFloat = 12
    static let contentSpacing: CGFloat = 12
    static let textColumnWidth: CGFloat = 158
    static let playSymbolSize: CGFloat = 19
    static let playSymbolPadding: CGFloat = 11
    static let playCircleSize: CGFloat = 44
    static let eyebrowFont: Font = .caption2.weight(.bold)
    static let titleFont: Font = .subheadline.weight(.semibold)
    static let metaFont: Font = .caption2
    #endif

    static var thumbnailHeight: CGFloat {
        (thumbnailWidth * 9.0 / 16.0).rounded()
    }
}
