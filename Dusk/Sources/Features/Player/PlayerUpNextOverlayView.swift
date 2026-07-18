import SwiftUI

struct PlayerUpNextOverlayView: View {
    let presentation: UpNextPresentation
    let plexService: PlexService
    let onPlayNow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let metrics = UpNextLayoutMetrics.make(for: geometry)

            ZStack {
                background

                panel(metrics: metrics)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, metrics.outerPadding)
                    .padding(.top, max(geometry.safeAreaInsets.top + 56, 60))
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom + 16, 20))
            }
        }
        .ignoresSafeArea()
    }

    private var background: some View {
        ZStack {
            Color.black

            LinearGradient(
                colors: [
                    Color.duskSurface.opacity(0.28),
                    Color.black.opacity(0.88),
                    Color.black,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.duskAccent.opacity(0.18),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    private func panel(metrics: UpNextLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            HStack(alignment: .center, spacing: 16) {
                Text(eyebrowText)
                    .font(.subheadline.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.duskAccent)

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(Circle())
            }
            .padding(.bottom, -metrics.sectionSpacing / 2)

            if metrics.usesVerticalLayout {
                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                    previewCard(metrics: metrics)
                    details(metrics: metrics)
                }
            } else {
                HStack(alignment: .top, spacing: metrics.contentSpacing) {
                    previewCard(metrics: metrics)
                    details(metrics: metrics)
                }
            }
        }
        .padding(metrics.panelPadding)
        .frame(width: metrics.panelWidth, height: metrics.panelHeight, alignment: .topLeading)
    }

    private func previewCard(metrics: UpNextLayoutMetrics) -> some View {
        let thumbnailURL = plexService.imageURL(
            for: presentation.episode.thumb ?? presentation.episode.art ?? presentation.episode.grandparentThumb,
            width: 1280,
            height: 720
        )

        return ZStack {
            if let thumbnailURL {
                DuskAsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Color.duskSurface
                    }
                }
            } else {
                Color.duskSurface
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack {
                Spacer()

                HStack {
                    if let subtitle = MediaTextFormatter.seasonEpisodeLabel(
                        season: presentation.episode.parentIndex,
                        episode: presentation.episode.index
                    ) {
                        Text(subtitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(12)

            playNowButton(metrics: metrics)
        }
        .frame(width: metrics.previewWidth, height: metrics.previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
    }

    private func details(metrics: UpNextLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.episode.title)
                .font(metrics.titleFont)
                .foregroundStyle(.white)
                .lineLimit(metrics.titleLineLimit)

            if let metadata = metadataText {
                Text(metadata)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)
            }

            if presentation.shouldAutoplay {
                countdownCard(
                    duration: presentation.countdownDuration,
                    startedAt: presentation.countdownStartedAt,
                    fallbackLabel: presentation.secondsRemaining.map { "Continues in \($0)s" },
                    fallbackProgress: presentation.autoplayProgress
                )
                    .padding(.top, 8)
            }

            if let summary = presentation.episode.summary,
               !summary.isEmpty {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineSpacing(4)
                    .lineLimit(metrics.summaryLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            if let errorMessage = presentation.errorMessage {
                Text(errorMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.duskAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    @ViewBuilder
    private func playNowButton(metrics: UpNextLayoutMetrics) -> some View {
        #if os(tvOS)
        Button(action: onPlayNow) {
            playNowButtonContent(metrics: metrics)
                .frame(width: metrics.playButtonSize, height: metrics.playButtonSize)
        }
        .disabled(presentation.isStarting)
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .tint(.white)
        #else
        Button(action: onPlayNow) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    }
                    .frame(width: metrics.playButtonSize, height: metrics.playButtonSize)

                playNowButtonContent(metrics: metrics)
            }
        }
        .disabled(presentation.isStarting)
        #endif
    }

    @ViewBuilder
    private func playNowButtonContent(metrics: UpNextLayoutMetrics) -> some View {
        if presentation.isStarting {
            ProgressView()
                .tint(.white)
        } else {
            Image(systemName: "play.fill")
                .font(.system(size: metrics.playIconSize, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: 2)
        }
    }

    private func countdownCard(
        duration: Int,
        startedAt: Date?,
        fallbackLabel: String?,
        fallbackProgress: Double?
    ) -> some View {
        let fallback = CountdownVisualState(
            label: fallbackLabel ?? "Continues in \(duration)s",
            progress: min(max(fallbackProgress ?? 0, 0), 1)
        )

        return TimelineView(.periodic(from: startedAt ?? .now, by: 0.1)) { context in
            let visualState = countdownVisualState(
                at: context.date,
                duration: duration,
                startedAt: startedAt,
                fallback: fallback
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Color.duskAccent)

                    Text(visualState.label)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))

                    Capsule()
                        .fill(Color.duskAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: visualState.progress, y: 1, anchor: .leading)
                        .animation(.linear(duration: 0.1), value: visualState.progress)
                }
                .frame(height: 6)
            }
        }
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
            label: "Continues in \(remaining)s",
            progress: progress
        )
    }
}

private struct CountdownVisualState {
    let label: String
    let progress: Double
}

private struct UpNextLayoutMetrics {
    let outerPadding: CGFloat
    let panelWidth: CGFloat
    let panelHeight: CGFloat
    let panelPadding: CGFloat
    let contentSpacing: CGFloat
    let sectionSpacing: CGFloat
    let previewWidth: CGFloat
    let previewHeight: CGFloat
    let usesVerticalLayout: Bool
    let titleFont: Font
    let titleLineLimit: Int
    let summaryLineLimit: Int
    let playButtonSize: CGFloat
    let playIconSize: CGFloat

    static func make(for geometry: GeometryProxy) -> Self {
        let size = geometry.size
        let isCompact = size.width < 500
        let outerPadding: CGFloat = isCompact ? 16 : 48
        let safeHeight = size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom - 40
        let panelWidth = size.width - outerPadding * 2
        let panelHeight = safeHeight
        let panelPadding: CGFloat = isCompact ? 18 : 32
        let contentSpacing: CGFloat = isCompact ? 16 : 32
        let sectionSpacing: CGFloat = isCompact ? 16 : 24
        let previewWidth: CGFloat
        if isCompact {
            previewWidth = min(max(panelWidth * 0.3, 112), 136)
        } else {
            previewWidth = min(max(panelWidth * 0.35, 220), 420)
        }
        let previewHeight = previewWidth * 9.0 / 16.0
        let remainingWidth = panelWidth - (panelPadding * 2) - previewWidth - contentSpacing
        let usesVerticalLayout = remainingWidth < 210

        return Self(
            outerPadding: outerPadding,
            panelWidth: panelWidth,
            panelHeight: panelHeight,
            panelPadding: panelPadding,
            contentSpacing: contentSpacing,
            sectionSpacing: sectionSpacing,
            previewWidth: previewWidth,
            previewHeight: previewHeight,
            usesVerticalLayout: usesVerticalLayout,
            titleFont: isCompact ? .title2.weight(.bold) : .largeTitle.weight(.bold),
            titleLineLimit: isCompact ? 2 : 3,
            summaryLineLimit: isCompact ? 3 : 6,
            playButtonSize: isCompact ? 54 : 72,
            playIconSize: isCompact ? 20 : 28
        )
    }
}
