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
    /// How much of the player, measured from the bottom edge, the card covers
    /// at its resting place. The session keeps the subtitles above it.
    var onCoveredHeightChange: (CGFloat) -> Void = { _ in }

    @Environment(\.blursUnwatchedEpisodes) private var blursUnwatchedEpisodes
    @State private var cardHeight: CGFloat = 0

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
        .onChange(of: coveredHeight, initial: true) {
            if cardHeight > 0 { onCoveredHeightChange(coveredHeight) }
        }
    }

    private var coveredHeight: CGFloat {
        cardHeight + PlayerOverlayLayout.skipMarkerBottomInset(controlsVisible: controlsVisible)
    }

    // MARK: - Card

    private func card(textColumnWidth: CGFloat) -> some View {
        #if os(tvOS)
        // Lifted like a focused tvOS card — scale plus a soft dark drop
        // shadow — rather than the shared white glow: the card is selected for
        // as long as the HUD is hidden, so a glow would be a permanent halo.
        content(textColumnWidth: textColumnWidth)
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
        content(textColumnWidth: textColumnWidth)
            .contentShape(isCompact ? AnyShape(Capsule()) : AnyShape(cardShape))
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
            .accessibilityAction(named: "Dismiss", onDismiss)
        #endif
    }

    @ViewBuilder
    private func content(textColumnWidth: CGFloat) -> some View {
        Group {
            if isCompact {
                compactChip
            } else {
                cardContent(textColumnWidth: textColumnWidth)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { cardHeight = $0 }
    }

    // MARK: - Compact (Blur Unwatched Episodes)

    /// With Blur Unwatched Episodes on, an unwatched next episode gets a
    /// two-line glass pill in the Skip Credits chip's family instead of the
    /// card: no still, just the episode title over a quiet "Up Next · Season 2,
    /// Episode 5" line, the countdown sweeping across the platter and, on iOS,
    /// a dismiss button. Play now / dismiss work exactly as on the card (tap or
    /// Select, swipe or Down).
    private var compactChip: some View {
        HStack(spacing: CompactMetrics.spacing) {
            Group {
                if presentation.isStarting {
                    ProgressView()
                        .tint(compactForeground)
                        #if !os(tvOS)
                        .controlSize(.small)
                        #endif
                } else {
                    Image(systemName: "play.fill")
                        .font(CompactMetrics.glyphFont)
                }
            }
            .frame(width: CompactMetrics.glyphWidth)

            VStack(alignment: .leading, spacing: CompactMetrics.lineSpacing) {
                Text(presentation.item.title)
                    .font(CompactMetrics.titleFont)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(compactDetail)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let statusText {
                        Text(" · \(statusText)")
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .font(CompactMetrics.detailFont)
                .opacity(CompactMetrics.detailOpacity)
            }
            .fixedSize(horizontal: false, vertical: true)
            .modifier(HuggingMaxWidth(CompactMetrics.maxTextWidth))

            #if !os(tvOS)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .opacity(0.7)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            #endif
        }
        .foregroundStyle(compactForeground)
        .padding(.leading, CompactMetrics.leadingPadding)
        .padding(.trailing, CompactMetrics.trailingPadding)
        .padding(.vertical, CompactMetrics.verticalPadding)
        .background { compactCountdownFill }
        .clipShape(Capsule())
        .modifier(CompactChipGlass(isSelected: isSelected))
    }

    /// Same rule as the blurred stills: only an episode still ahead of the
    /// viewer is hidden, so a rewatch keeps the full card.
    private var isCompact: Bool {
        blursUnwatchedEpisodes && presentation.item.isEpisode && !presentation.item.isWatched
    }

    private var compactForeground: Color {
        #if os(tvOS)
        isSelected ? Color.black.opacity(0.86) : Color.white
        #else
        Color.white
        #endif
    }

    /// "Up Next · Season 2, Episode 5". A playlist mixes shows, so it names
    /// the show too and falls back to the short "S2 · E5" form.
    private var compactDetail: String {
        let item = presentation.item
        let inQueue = presentation.queueTitle != nil
        let episode = inQueue
            ? MediaTextFormatter.compactSeasonEpisodeLabel(season: item.parentIndex, episode: item.index)
            : MediaTextFormatter.seasonEpisodeLabel(season: item.parentIndex, episode: item.index, separator: ", ")
        let show = inQueue ? item.grandparentTitle : nil
        return (["Up Next", show, episode] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var compactCountdownFill: some View {
        if presentation.isTimed {
            let progress = min(max(presentation.countdownProgress ?? 0, 0), 1)
            GeometryReader { geometry in
                Rectangle()
                    .fill(compactCountdownColor)
                    .frame(width: geometry.size.width * progress)
                    .animation(.linear(duration: 0.1), value: progress)
            }
        }
    }

    private var compactCountdownColor: Color {
        #if os(tvOS)
        isSelected ? Color.black.opacity(0.12) : Color.white.opacity(0.2)
        #else
        Color.white.opacity(0.18)
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
                Text(eyebrowText)
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

            Text(presentation.item.title)
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
            .frame(width: Metrics.thumbnailWidth, height: Metrics.thumbnailHeight)
            .spoilerBlur(thumbnailIsUnwatchedEpisodeStill)

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
        } else if blursUnwatchedEpisodes && thumbnailIsUnwatchedEpisodeStill {
            // The blurred still carries the spoiler glyph in this spot, as on
            // the episode cards.
            EmptyView()
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
            for: presentation.item.upNextStillPath,
            serverID: presentation.item.serverID,
            width: 640,
            height: 360
        )
    }

    private var thumbnailIsUnwatchedEpisodeStill: Bool {
        presentation.item.hasUnwatchedEpisodeStill
    }

    private var metadataText: String? {
        [
            // A playlist mixes shows, so its episodes name theirs; the show's
            // own next episode never needs to.
            presentation.queueTitle != nil && presentation.item.isEpisode
                ? presentation.item.grandparentTitle
                : nil,
            presentation.item.upNextDetailLabel(compact: presentation.queueTitle != nil),
            MediaTextFormatter.shortDuration(milliseconds: presentation.item.duration),
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

    /// "Next in Weekend Movies" in a playlist session.
    private var eyebrowText: String {
        guard let queueTitle = presentation.queueTitle else { return "UP NEXT" }
        return "NEXT IN \(queueTitle.uppercased())"
    }

    private var accessibilityLabel: String {
        if isCompact {
            return "Play next episode: \(presentation.item.title), \(compactDetail)"
        }
        return presentation.item.isEpisode
            ? "Play next episode: \(presentation.item.title)"
            : "Play next: \(presentation.item.title)"
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

/// The compact chip's platter. tvOS matches `PlayerTVSkipChip` (light glass
/// with a dark label while it owns Select, dark glass while the HUD is up);
/// iOS uses native Liquid Glass where available and the skip chip's material
/// capsule before iOS 26.
private struct CompactChipGlass: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.glassEffect(
            isSelected ? .regular.tint(.white.opacity(0.78)) : .regular.tint(.black.opacity(0.3)),
            in: Capsule()
        )
        #else
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.18)), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
        }
        #endif
    }
}

/// Caps a view's width without making it greedy. A flexible
/// `.frame(maxWidth:)` takes the whole proposed width up to its cap, which
/// stretched the compact pill far past short titles; this only caps the
/// proposal and reports the content's own size, so the pill hugs its text and
/// long titles truncate at the cap.
private struct HuggingMaxWidth: ViewModifier {
    let maxWidth: CGFloat

    init(_ maxWidth: CGFloat) {
        self.maxWidth = maxWidth
    }

    func body(content: Content) -> some View {
        MaxWidthLayout(maxWidth: maxWidth) { content }
    }
}

private struct MaxWidthLayout: Layout {
    let maxWidth: CGFloat

    private func cappedProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(cappedProposal(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private enum CompactMetrics {
    #if os(tvOS)
    static let titleFont: Font = DuskFont.TV.buttonLabel
    static let detailFont: Font = DuskFont.TV.cardSubtitle
    static let glyphFont: Font = .system(size: 24, weight: .semibold)
    static let glyphWidth: CGFloat = 28
    static let spacing: CGFloat = 18
    static let lineSpacing: CGFloat = 2
    static let maxTextWidth: CGFloat = 460
    static let leadingPadding: CGFloat = 34
    static let trailingPadding: CGFloat = 40
    static let verticalPadding: CGFloat = 18
    #else
    static let titleFont: Font = .subheadline.weight(.semibold)
    static let detailFont: Font = .caption
    static let glyphFont: Font = .subheadline.weight(.semibold)
    static let glyphWidth: CGFloat = 18
    static let spacing: CGFloat = 10
    static let lineSpacing: CGFloat = 1
    static let maxTextWidth: CGFloat = 220
    static let leadingPadding: CGFloat = 20
    static let trailingPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 9
    #endif
    static let detailOpacity: Double = 0.7
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
    static let metaOpacity: Double = 0.6
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
    static let metaOpacity: Double = 0.7
    #endif

    // Monochrome like the play bar and the TV app's own player chrome: a
    // secondary-label eyebrow and a white countdown, no brand coral.
    static let eyebrowColor: Color = .white.opacity(0.6)
    static let countdownFill: Color = .white

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
