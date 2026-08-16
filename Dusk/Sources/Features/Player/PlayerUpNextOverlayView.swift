import SwiftUI

/// The full-screen Up Next screen shown when an episode ends without an
/// auto-advance already in flight (see `PlayerUpNextPosterView` for the small
/// in-playback card).
///
/// Layout notes: the content block is a single vertically centered group, sized
/// from **both** axes of the container. The player is watched in landscape as
/// often as portrait, so the still is driven by the shorter of "a share of the
/// width" and "a share of the height" — a width-only rule pushed the details off
/// the bottom of an iPhone in landscape. The close button is anchored to the
/// screen's top-trailing safe area rather than riding inside the content block.
struct PlayerUpNextOverlayView: View {
    let presentation: UpNextPresentation
    let plexService: PlexService
    let onPlayNow: () -> Void
    let onDismiss: () -> Void

    #if os(tvOS)
    @FocusState private var isPlayFocused: Bool
    #endif

    var body: some View {
        GeometryReader { geometry in
            let metrics = UpNextLayoutMetrics.make(for: geometry)

            ZStack(alignment: .topTrailing) {
                background

                content(metrics: metrics)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.leading, metrics.leadingPadding)
                    .padding(.trailing, metrics.trailingPadding)
                    .padding(.top, metrics.topPadding)
                    .padding(.bottom, metrics.bottomPadding)

                closeButton(metrics: metrics)
                    .padding(.top, metrics.closeTopInset)
                    .padding(.trailing, metrics.closeTrailingInset)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color.black

            // The next episode's own artwork, blurred out to a wash. It gives the
            // screen the same "the show continues" feel as the detail heroes
            // instead of a flat gradient, and it is already in the image cache
            // because the still below uses the same source.
            if let backdropURL {
                DuskAsyncImage(url: backdropURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            // `opaque: true` samples the artwork's own edges, so
                            // the wash reaches the screen edges instead of fading
                            // to transparent corners.
                            .blur(radius: 60, opaque: true)
                            .opacity(0.34)
                            .transition(.opacity)
                    default:
                        Color.clear
                    }
                }
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.78),
                    Color.black.opacity(0.94),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.duskAccent.opacity(0.14),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 620
            )
        }
        .clipped()
        .ignoresSafeArea()
    }

    // MARK: - Content

    @ViewBuilder
    private func content(metrics: UpNextLayoutMetrics) -> some View {
        if metrics.usesVerticalLayout {
            VStack(alignment: .leading, spacing: metrics.columnSpacing) {
                still(metrics: metrics)
                details(metrics: metrics)
            }
            .frame(width: metrics.previewWidth, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: metrics.columnSpacing) {
                still(metrics: metrics)

                details(metrics: metrics)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: metrics.contentWidth)
        }
    }

    private func still(metrics: UpNextLayoutMetrics) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.stillCornerRadius, style: .continuous)

        return ZStack {
            if let stillURL {
                DuskAsyncImage(url: stillURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        placeholderFill
                    }
                }
            } else {
                placeholderFill
            }
        }
        .frame(width: metrics.previewWidth, height: metrics.previewHeight)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
    }

    private var placeholderFill: some View {
        Color.duskSurface
            .overlay {
                Image(systemName: "film")
                    .font(.largeTitle)
                    .foregroundStyle(Color.duskTextSecondary)
            }
    }

    private func details(metrics: UpNextLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.blockSpacing) {
            VStack(alignment: .leading, spacing: metrics.headerSpacing) {
                Text(eyebrowText)
                    .font(metrics.eyebrowFont)
                    .tracking(1.4)
                    .foregroundStyle(Color.duskAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(presentation.episode.title)
                    .font(metrics.titleFont)
                    .foregroundStyle(.white)
                    .lineLimit(metrics.titleLineLimit)
                    .fixedSize(horizontal: false, vertical: true)

                if let metadataText {
                    Text(metadataText)
                        .font(metrics.metadataFont.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            if let summary = presentation.episode.summary,
               !summary.isEmpty,
               metrics.summaryLineLimit > 0 {
                Text(summary)
                    .font(metrics.summaryFont)
                    .foregroundStyle(.white.opacity(0.84))
                    .lineSpacing(3)
                    .lineLimit(metrics.summaryLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: metrics.summaryWidth, alignment: .leading)
            }

            if presentation.shouldAutoplay {
                countdown(metrics: metrics)
            }

            playButton(metrics: metrics)

            if let errorMessage = presentation.errorMessage {
                Text(errorMessage)
                    .font(metrics.metadataFont.weight(.medium))
                    .foregroundStyle(Color.duskAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Controls

    private func playButton(metrics: UpNextLayoutMetrics) -> some View {
        Button(action: onPlayNow) {
            HStack(spacing: 10) {
                if presentation.isStarting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black)
                } else {
                    Image(systemName: "play.fill")
                        .font(metrics.actionFont.weight(.semibold))
                }

                Text(playButtonTitle)
                    .font(metrics.actionFont)
                    .lineLimit(1)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: metrics.actionFillsWidth ? .infinity : nil, minHeight: metrics.actionMinHeight)
            #if os(tvOS)
            // Matches the detail hero primary: a contained width so the button
            // does not hug a two-word label in a left-aligned column.
            .frame(minWidth: 300)
            #endif
            .contentShape(Capsule())
        }
        .disabled(presentation.isStarting)
        .upNextPrimaryButtonStyle()
        #if os(tvOS)
        .focused($isPlayFocused)
        .onAppear {
            Task { @MainActor in isPlayFocused = true }
        }
        #endif
        .accessibilityLabel("\(playButtonTitle): \(presentation.episode.title)")
    }

    private func closeButton(metrics: UpNextLayoutMetrics) -> some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(metrics.closeIconFont)
                .foregroundStyle(.white)
                .frame(width: metrics.closeButtonSize, height: metrics.closeButtonSize)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
        }
        .duskSuppressTVOSButtonChrome()
        .duskTVOSFocusEffectShape(Circle())
        .accessibilityLabel("Close Player")
    }

    private func countdown(metrics: UpNextLayoutMetrics) -> some View {
        let fallback = CountdownVisualState(
            label: presentation.secondsRemaining.map(Self.countdownLabel)
                ?? Self.countdownLabel(for: presentation.countdownDuration),
            progress: min(max(presentation.autoplayProgress ?? 0, 0), 1)
        )

        return TimelineView(.periodic(from: presentation.countdownStartedAt ?? .now, by: 0.1)) { context in
            let visualState = countdownVisualState(
                at: context.date,
                duration: presentation.countdownDuration,
                startedAt: presentation.countdownStartedAt,
                fallback: fallback
            )

            VStack(alignment: .leading, spacing: 9) {
                Text(visualState.label)
                    .font(metrics.countdownFont.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.16))

                        Capsule()
                            .fill(Color.duskAccent)
                            .frame(width: geometry.size.width * visualState.progress)
                            .animation(.linear(duration: 0.1), value: visualState.progress)
                    }
                }
                .frame(height: metrics.countdownBarHeight)
            }
            .frame(maxWidth: metrics.countdownWidth, alignment: .leading)
        }
    }

    // MARK: - Data

    private var stillURL: URL? {
        plexService.imageURL(
            for: presentation.episode.thumb ?? presentation.episode.art ?? presentation.episode.grandparentThumb,
            width: 1280,
            height: 720
        )
    }

    private var backdropURL: URL? {
        plexService.imageURL(
            for: presentation.episode.art ?? presentation.episode.thumb ?? presentation.episode.grandparentThumb,
            width: 1280,
            height: 720
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

    private var eyebrowText: String {
        if presentation.autoplayBlockedByPassoutProtection {
            return "AUTOPLAY PAUSED"
        }
        if !presentation.shouldAutoplay, case .playbackEnded = presentation.source {
            return "ARE YOU STILL WATCHING?"
        }
        return "UP NEXT"
    }

    /// A countdown is already promising the next episode, so the button is the
    /// "don't wait" shortcut. Without one it is the only way forward, and after
    /// a pause for passout protection it reads as resuming the binge.
    private var playButtonTitle: String {
        if presentation.shouldAutoplay {
            return "Play Now"
        }
        return "Keep Watching"
    }

    private static func countdownLabel(for seconds: Int) -> String {
        "Plays in \(max(seconds, 0))s"
    }

    private func countdownVisualState(
        at date: Date,
        duration: Int,
        startedAt: Date?,
        fallback: CountdownVisualState
    ) -> CountdownVisualState {
        guard let startedAt, duration > 0 else { return fallback }

        let durationSeconds = Double(duration)
        let elapsed = min(max(date.timeIntervalSince(startedAt), 0), durationSeconds)
        let remaining = max(0, Int(ceil(durationSeconds - elapsed)))
        let progress = min(max(elapsed / durationSeconds, 0), 1)

        return CountdownVisualState(
            label: Self.countdownLabel(for: remaining),
            progress: progress
        )
    }
}

private struct CountdownVisualState {
    let label: String
    let progress: Double
}

// MARK: - Primary Action Style

private extension View {
    /// A white glass capsule with a dark label. The Up Next screen is always a
    /// near-black surface regardless of the app's appearance mode, so this one
    /// keeps a fixed light lean instead of `Color.duskPrimaryButtonTint`, which
    /// would resolve to a dark capsule on a dark screen in Light mode.
    @ViewBuilder
    func upNextPrimaryButtonStyle() -> some View {
        #if os(tvOS)
        // A custom style rather than `.glassProminent`: the system focus
        // highlight forces the fill *and* the label to white, which would render
        // the focused button as white-on-white.
        self.buttonStyle(UpNextPrimaryTVButtonStyle())
        #else
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.white)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.white)
        }
        #endif
    }
}

#if os(tvOS)
private struct UpNextPrimaryTVButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .glassEffect(.regular.tint(Color.white.opacity(0.9)), in: Capsule())
                .scaleEffect(isFocused ? 1.05 : 1.0)
                .shadow(
                    color: isFocused ? Color.white.opacity(0.34) : .clear,
                    radius: isFocused ? 16 : 0,
                    y: isFocused ? 6 : 0
                )
                .opacity(configuration.isPressed ? 0.86 : 1.0)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}
#endif

// MARK: - Layout

private struct UpNextLayoutMetrics {
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let contentWidth: CGFloat
    let columnSpacing: CGFloat
    let blockSpacing: CGFloat
    let headerSpacing: CGFloat
    let previewWidth: CGFloat
    let previewHeight: CGFloat
    let stillCornerRadius: CGFloat
    let usesVerticalLayout: Bool
    let eyebrowFont: Font
    let titleFont: Font
    let metadataFont: Font
    let summaryFont: Font
    let countdownFont: Font
    let actionFont: Font
    let titleLineLimit: Int
    let summaryLineLimit: Int
    let summaryWidth: CGFloat
    let countdownWidth: CGFloat
    let countdownBarHeight: CGFloat
    let actionFillsWidth: Bool
    let actionMinHeight: CGFloat
    let closeButtonSize: CGFloat
    let closeIconFont: Font
    let closeTopInset: CGFloat
    let closeTrailingInset: CGFloat

    static func make(for geometry: GeometryProxy) -> Self {
        let insets = geometry.safeAreaInsets
        let safeWidth = max(geometry.size.width - insets.leading - insets.trailing, 280)
        let safeHeight = max(geometry.size.height - insets.top - insets.bottom, 200)

        #if os(tvOS)
        let horizontalPadding: CGFloat = 90
        let verticalPadding: CGFloat = 60
        let maxContentWidth: CGFloat = 1500
        let isCompactWidth = false
        #else
        let isCompactWidth = safeWidth < 500
        let horizontalPadding: CGFloat = isCompactWidth ? 24 : 48
        let verticalPadding: CGFloat = isCompactWidth ? 28 : 36
        let maxContentWidth: CGFloat = 1000
        #endif

        let availableWidth = max(safeWidth - horizontalPadding * 2, 220)
        let availableHeight = max(safeHeight - verticalPadding * 2, 180)
        let contentWidth = min(availableWidth, maxContentWidth)
        // A tall, narrow container (iPhone portrait, iPad portrait) reads better
        // as a stacked still-over-text card; anything wide enough to keep a
        // readable text column beside the still goes side by side.
        #if os(tvOS)
        let usesVerticalLayout = false
        #else
        let usesVerticalLayout = contentWidth < 600 || safeHeight > safeWidth * 1.05
        #endif
        let columnSpacing: CGFloat = isCompactWidth ? 20 : 32

        let preview = previewSize(
            contentWidth: contentWidth,
            availableHeight: availableHeight,
            columnSpacing: columnSpacing,
            usesVerticalLayout: usesVerticalLayout,
            isCompactWidth: isCompactWidth
        )

        // Only the vertical axis actually squeezes the text: iPhone landscape has
        // a wide but very short content box.
        let isShortHeight = availableHeight < 340

        #if os(tvOS)
        let eyebrowFont: Font = .system(size: 22, weight: .bold)
        let titleFont: Font = .system(size: 50, weight: .bold)
        let metadataFont: Font = .system(size: 24, weight: .medium)
        let summaryFont: Font = .system(size: 26, weight: .regular)
        let countdownFont: Font = .system(size: 24, weight: .semibold)
        let actionFont: Font = .system(size: 26, weight: .semibold)
        let summaryLineLimit = 3
        let blockSpacing: CGFloat = 26
        let headerSpacing: CGFloat = 10
        let countdownBarHeight: CGFloat = 7
        let countdownWidth: CGFloat = 460
        let summaryWidth: CGFloat = 760
        let actionMinHeight: CGFloat = 0
        let closeButtonSize: CGFloat = 62
        let closeIconFont: Font = .system(size: 24, weight: .semibold)
        #else
        let eyebrowFont: Font = isCompactWidth ? .caption.weight(.bold) : .subheadline.weight(.bold)
        let titleFont: Font = {
            if isCompactWidth { return .title2.weight(.bold) }
            if isShortHeight { return .title.weight(.bold) }
            return .largeTitle.weight(.bold)
        }()
        let metadataFont: Font = .subheadline
        let summaryFont: Font = isCompactWidth || isShortHeight ? .subheadline : .body
        let countdownFont: Font = .subheadline.weight(.semibold)
        let actionFont: Font = .headline
        let summaryLineLimit = isShortHeight ? 2 : (isCompactWidth ? 3 : 4)
        let blockSpacing: CGFloat = isShortHeight ? 14 : 20
        let headerSpacing: CGFloat = 6
        let countdownBarHeight: CGFloat = 5
        let countdownWidth: CGFloat = 320
        let summaryWidth: CGFloat = 620
        let actionMinHeight: CGFloat = 26
        let closeButtonSize: CGFloat = 44
        let closeIconFont: Font = .body.weight(.semibold)
        #endif

        return Self(
            leadingPadding: insets.leading + horizontalPadding,
            trailingPadding: insets.trailing + horizontalPadding,
            topPadding: insets.top + verticalPadding,
            bottomPadding: insets.bottom + verticalPadding,
            contentWidth: contentWidth,
            columnSpacing: columnSpacing,
            blockSpacing: blockSpacing,
            headerSpacing: headerSpacing,
            previewWidth: preview.width,
            previewHeight: preview.height,
            stillCornerRadius: preview.width < 260 ? 16 : 22,
            usesVerticalLayout: usesVerticalLayout,
            eyebrowFont: eyebrowFont,
            titleFont: titleFont,
            metadataFont: metadataFont,
            summaryFont: summaryFont,
            countdownFont: countdownFont,
            actionFont: actionFont,
            titleLineLimit: 2,
            summaryLineLimit: summaryLineLimit,
            summaryWidth: summaryWidth,
            countdownWidth: countdownWidth,
            countdownBarHeight: countdownBarHeight,
            actionFillsWidth: isCompactWidth,
            actionMinHeight: actionMinHeight,
            closeButtonSize: closeButtonSize,
            closeIconFont: closeIconFont,
            closeTopInset: insets.top + (isCompactWidth ? 12 : 20),
            closeTrailingInset: insets.trailing + (isCompactWidth ? 16 : 24)
        )
    }

    /// 16:9 still sized against both axes, then re-derived from whichever
    /// constraint bit first so the aspect ratio always survives.
    private static func previewSize(
        contentWidth: CGFloat,
        availableHeight: CGFloat,
        columnSpacing: CGFloat,
        usesVerticalLayout: Bool,
        isCompactWidth: Bool
    ) -> CGSize {
        let aspectRatio: CGFloat = 16.0 / 9.0
        let minimumDetailsWidth: CGFloat = 280

        var width: CGFloat
        var heightBudget: CGFloat

        if usesVerticalLayout {
            width = isCompactWidth ? contentWidth : min(contentWidth, 560)
            // The still is only ever the top half of a stacked card, so it can
            // never eat the room the title, synopsis, and button need.
            heightBudget = availableHeight * 0.44
        } else {
            width = min(max(contentWidth * 0.42, 240), 560)
            width = min(width, max(contentWidth - columnSpacing - minimumDetailsWidth, 200))
            heightBudget = availableHeight * 0.86
        }

        var height = width / aspectRatio
        if height > heightBudget {
            height = heightBudget
            width = height * aspectRatio
        }

        return CGSize(width: width.rounded(), height: height.rounded())
    }
}
