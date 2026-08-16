import SwiftUI

/// The small "next episode" poster shown in the bottom-right of the player once
/// the credits marker is reached. It rests near the bottom edge while the HUD is
/// hidden and rises above the play bar when the controls come up. It replaces
/// the old "Skip Credits" button.
///
/// - Tapping it (or pressing Select on tvOS) plays the next episode immediately.
/// - In `timedAutoplay` mode it shows a countdown; when it reaches zero the next
///   episode plays automatically without the full-screen Up Next screen.
/// - Dragging it down (iOS) / swiping down (tvOS) dismisses the poster and
///   cancels any pending auto-advance, letting the current episode play out to
///   its end. The full-screen Up Next screen then appears when it finishes.
///
/// Layout notes: the card is built from concentric corners (`cardCornerRadius`
/// minus `cardPadding` equals `thumbnailCornerRadius`) and a fixed three-row
/// text column, so its height never changes as the countdown ticks. The
/// countdown bar spans the card's full inner width beneath both columns rather
/// than being squeezed into the text column.
struct PlayerUpNextPosterView: View {
    let presentation: UpNextPosterPresentation
    let plexService: PlexService
    let controlsVisible: Bool
    let onPlayNow: () -> Void
    let onDismiss: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    @State private var isDismissing = false
    #else
    @GestureState private var dragTranslation: CGSize = .zero
    #endif

    var body: some View {
        // The container width decides how much room the text column can claim:
        // the card is a fixed-width layout, and on a narrow viewport (iPhone
        // portrait, an iPad Slide Over pane) a hardcoded column would push the
        // card past the leading edge.
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    card(textColumnWidth: Metrics.textColumnWidth(fitting: geometry.size.width))
                }
            }
            .padding(.horizontal, PlayerOverlayLayout.controlsHorizontalPadding)
            .padding(.bottom, PlayerOverlayLayout.skipMarkerBottomInset(controlsVisible: controlsVisible))
        }
        .animation(PlayerOverlayLayout.skipMarkerRepositionAnimation, value: controlsVisible)
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Card

    private func card(textColumnWidth: CGFloat) -> some View {
        #if os(tvOS)
        Button(action: onPlayNow) {
            cardContent(textColumnWidth: textColumnWidth)
        }
        .focused($isFocused)
        .duskSuppressTVOSButtonChrome()
        .contentShape(.interaction, cardShape)
        .focusEffectDisabled()
        // No focus glow: the poster grabs focus the moment it appears and holds
        // it while the HUD is hidden, so the shared white glow renders as a
        // permanent oversized halo around the card. The 1.05x scale is enough
        // focus feedback when the HUD is up.
        .duskTVOSFocusedScale(isFocused, glow: false)
        .offset(y: isDismissing ? Metrics.dismissDropDistance : 0)
        .opacity(isDismissing ? 0 : 1)
        .onMoveCommand { direction in
            if direction == .down {
                dismissWithAnimation()
            }
        }
        .onAppear {
            Task { @MainActor in isFocused = true }
        }
        .accessibilityLabel(accessibilityLabel)
        #else
        cardContent(textColumnWidth: textColumnWidth)
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

    private func cardContent(textColumnWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Metrics.countdownSpacing) {
            HStack(alignment: .center, spacing: Metrics.contentSpacing) {
                thumbnail

                textColumn
                    .frame(width: textColumnWidth, alignment: .leading)
            }

            if presentation.isTimed {
                countdownBar
            }
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
        // Deliberately tight: on tvOS the card also carries the focus glow from
        // `duskTVOSFocusedScale`, so anything heavier reads as a hard black halo
        // over bright video.
        .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
    }

    /// Three fixed rows — eyebrow, title, metadata — so the card keeps one
    /// height for the poster's whole lifetime. The countdown lives in the
    /// eyebrow's trailing slot and on the bar below, never as an extra row.
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: Metrics.textRowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("UP NEXT")
                    .font(Metrics.eyebrowFont)
                    .tracking(1.2)
                    .foregroundStyle(Color.duskAccent)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                if let statusText {
                    Text(statusText)
                        .font(Metrics.eyebrowFont.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            Text(presentation.episode.title)
                .font(Metrics.titleFont)
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let metadataText {
                Text(metadataText)
                    .font(Metrics.metaFont.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
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
                colors: [.clear, .black.opacity(0.28)],
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
            // Matches the seasons/episode page play icon (`PosterArtwork`), sized
            // to sit inside the still rather than cover it.
            Image(systemName: "play.fill")
                .font(.system(size: Metrics.playSymbolSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(Metrics.playSymbolPadding)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
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

    /// Spans the card's full inner width under both columns, so the countdown
    /// reads as the card draining rather than as a stray hairline in the text.
    private var countdownBar: some View {
        let progress = min(max(presentation.countdownProgress ?? 0, 0), 1)

        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))

                Capsule()
                    .fill(Color.duskAccent)
                    .frame(width: geometry.size.width * progress)
                    .animation(.linear(duration: 0.1), value: progress)
            }
        }
        .frame(height: Metrics.countdownBarHeight)
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

    /// Trailing half of the eyebrow row: the live countdown while one is
    /// running, or the hand-off state once the next episode is starting.
    private var statusText: String? {
        if presentation.isStarting {
            return "Playing…"
        }

        guard let secondsRemaining = presentation.secondsRemaining else { return nil }
        return "\(secondsRemaining)s"
    }

    private var accessibilityLabel: String {
        "Play next episode: \(presentation.episode.title)"
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
    }

    #if os(tvOS)
    /// Slides the card down and fades it out before it is removed, so a
    /// swipe-down dismiss reads as an intentional gesture that mirrors the
    /// direction of the swipe — instead of the card blinking out of existence.
    private func dismissWithAnimation() {
        guard !isDismissing else { return }
        withAnimation(.easeIn(duration: 0.28)) {
            isDismissing = true
        } completion: {
            onDismiss()
        }
    }
    #endif

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
    static let thumbnailWidth: CGFloat = 240
    static let cardCornerRadius: CGFloat = 34
    static let cardPadding: CGFloat = 18
    static let contentSpacing: CGFloat = 20
    static let preferredTextColumnWidth: CGFloat = 320
    static let minimumTextColumnWidth: CGFloat = 240
    static let textRowSpacing: CGFloat = 6
    static let countdownSpacing: CGFloat = 16
    static let countdownBarHeight: CGFloat = 6
    static let dismissDropDistance: CGFloat = 60
    static let playSymbolSize: CGFloat = 24
    static let playSymbolPadding: CGFloat = 14
    static let playCircleSize: CGFloat = 52
    // Explicit sizes: tvOS's semantic text styles (.title3/.subheadline/…) map
    // to much larger points than iOS, which made this compact overlay card read
    // as oversized. These are tuned for the card, not inherited from the scale.
    static let eyebrowFont: Font = .system(size: 19, weight: .bold)
    static let titleFont: Font = .system(size: 29, weight: .semibold)
    static let metaFont: Font = .system(size: 20, weight: .regular)
    #else
    static let thumbnailWidth: CGFloat = 132
    static let cardCornerRadius: CGFloat = 24
    static let cardPadding: CGFloat = 10
    static let contentSpacing: CGFloat = 12
    static let preferredTextColumnWidth: CGFloat = 168
    static let minimumTextColumnWidth: CGFloat = 112
    static let textRowSpacing: CGFloat = 3
    static let countdownSpacing: CGFloat = 10
    static let countdownBarHeight: CGFloat = 4
    static let playSymbolSize: CGFloat = 14
    static let playSymbolPadding: CGFloat = 9
    static let playCircleSize: CGFloat = 32
    static let eyebrowFont: Font = .caption2.weight(.bold)
    static let titleFont: Font = .subheadline.weight(.semibold)
    static let metaFont: Font = .caption2
    #endif

    static var thumbnailHeight: CGFloat {
        (thumbnailWidth * 9.0 / 16.0).rounded()
    }

    /// Concentric corners: the still's radius is the card's radius minus the
    /// uniform card padding, so both curves share a center.
    static var thumbnailCornerRadius: CGFloat {
        cardCornerRadius - cardPadding
    }

    /// The text column is fixed so the card never resizes mid-countdown, but it
    /// gives width back when the player itself is narrower than the preferred
    /// card.
    static func textColumnWidth(fitting containerWidth: CGFloat) -> CGFloat {
        let chrome = PlayerOverlayLayout.controlsHorizontalPadding * 2
            + cardPadding * 2
            + thumbnailWidth
            + contentSpacing

        return min(preferredTextColumnWidth, max(minimumTextColumnWidth, containerWidth - chrome))
    }
}
