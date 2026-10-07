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
    /// tvOS only: the card is "selected" while the HUD is hidden, which is when
    /// `PlayerTVHUDController` routes Select and Down to it. It is deliberately
    /// not focusable — a focusable card here would take the remote away from
    /// the player's single input bridge. Ignored on iOS.
    var isSelected: Bool = false
    let onPlayNow: () -> Void
    let onDismiss: () -> Void

    #if !os(tvOS)
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
            .padding(.horizontal, PlayerOverlayLayout.bottomTrailingHorizontalPadding)
            .padding(.bottom, PlayerOverlayLayout.skipMarkerBottomInset(controlsVisible: controlsVisible))
        }
        .animation(PlayerOverlayLayout.skipMarkerRepositionAnimation, value: controlsVisible)
        .ignoresSafeArea(edges: PlayerOverlayLayout.bottomTrailingIgnoredSafeAreaEdges)
    }

    // MARK: - Card

    private func card(textColumnWidth: CGFloat) -> some View {
        #if os(tvOS)
        // Lifted like a focused tvOS card — scale plus a soft dark drop
        // shadow — rather than the shared white glow: the card is selected for
        // as long as the HUD is hidden, so a glow would be a permanent halo.
        cardContent(textColumnWidth: textColumnWidth)
            .scaleEffect(isSelected ? PlayerTVHUDLayout.bottomTrailingSelectedScale : 1)
            .shadow(
                color: .black.opacity(isSelected ? 0.4 : 0),
                radius: isSelected ? 24 : 0,
                y: isSelected ? 14 : 0
            )
            .animation(PlayerTVHUDLayout.selectionAnimation, value: isSelected)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Press Select to play now, Down to dismiss")
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
                countdownBar(width: Metrics.thumbnailWidth + Metrics.contentSpacing + textColumnWidth)
            }
        }
        .padding(Metrics.cardPadding)
        .background {
            cardShape
                .fill(.ultraThinMaterial)
                .overlay {
                    cardShape.fill(cardTint)
                }
        }
        .overlay {
            cardShape
                .strokeBorder(.white.opacity(cardBorderOpacity), lineWidth: 1)
        }
        .clipShape(cardShape)
        #if !os(tvOS)
        .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
        #endif
    }

    /// tvOS brightens the platter while the card owns Select, the way a
    /// focused tvOS platter lightens; iOS keeps one darkened glass.
    private var cardTint: Color {
        #if os(tvOS)
        isSelected ? Color.white.opacity(0.14) : Color.black.opacity(0.22)
        #else
        Color.black.opacity(0.18)
        #endif
    }

    private var cardBorderOpacity: Double {
        #if os(tvOS)
        isSelected ? 0.28 : 0.12
        #else
        0.12
        #endif
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
                    .foregroundStyle(Metrics.eyebrowColor)
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
                    .foregroundStyle(.white.opacity(Metrics.metaOpacity))
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
                    .font(DuskFont.glyphMedium(ios: .title3))
                    .foregroundStyle(Color.duskTextSecondary)
            }
    }

    /// Spans the card's full inner width under both columns, so the countdown
    /// reads as the card draining rather than as a stray hairline in the text.
    ///
    /// The width is explicit: the bar's `GeometryReader` is greedy, and left to
    /// itself it stretched the whole card across the screen.
    private func countdownBar(width: CGFloat) -> some View {
        let progress = min(max(presentation.countdownProgress ?? 0, 0), 1)

        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))

                Capsule()
                    .fill(Metrics.countdownFill)
                    .frame(width: geometry.size.width * progress)
                    .animation(.linear(duration: 0.1), value: progress)
            }
        }
        .frame(width: width, height: Metrics.countdownBarHeight)
    }

    // MARK: - Data

    private var thumbnailURL: URL? {
        plexService.imageURL(
            for: presentation.episode.thumb
                ?? presentation.episode.art
                ?? presentation.episode.grandparentThumb,
            serverID: presentation.episode.serverID,
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
    static let thumbnailWidth: CGFloat = 256
    static let cardCornerRadius: CGFloat = 32
    static let cardPadding: CGFloat = 16
    static let contentSpacing: CGFloat = 22
    static let preferredTextColumnWidth: CGFloat = 330
    static let minimumTextColumnWidth: CGFloat = 240
    static let textRowSpacing: CGFloat = 4
    static let countdownSpacing: CGFloat = 14
    static let countdownBarHeight: CGFloat = 6
    static let playSymbolSize: CGFloat = 24
    static let playSymbolPadding: CGFloat = 14
    static let playCircleSize: CGFloat = 52
    // On the `DuskFont` tvOS ladder: badge eyebrow, compact player title,
    // card subtitle — the same steps the play bar's own title uses.
    static let eyebrowFont: Font = DuskFont.TV.badge
    static let titleFont: Font = DuskFont.TV.playerTitleCompact
    static let metaFont: Font = DuskFont.TV.cardSubtitle
    // Monochrome like the play bar and the TV app's own player chrome: a
    // secondary-label eyebrow and a white countdown, no brand coral.
    static let eyebrowColor: Color = .white.opacity(0.6)
    static let metaOpacity: Double = 0.6
    static let countdownFill: Color = .white
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
    static let eyebrowColor: Color = .duskAccent
    static let metaOpacity: Double = 0.7
    static let countdownFill: Color = .duskAccent
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
        let chrome = PlayerOverlayLayout.bottomTrailingHorizontalPadding * 2
            + cardPadding * 2
            + thumbnailWidth
            + contentSpacing

        return min(preferredTextColumnWidth, max(minimumTextColumnWidth, containerWidth - chrome))
    }
}
