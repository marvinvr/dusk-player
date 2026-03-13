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
                    .padding(.top, max(geometry.safeAreaInsets.top + 16, 20))
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
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(eyebrowText)
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(Color.duskAccent)

                    if let showTitle = presentation.episode.grandparentTitle {
                        Text(showTitle)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                }

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

        return ZStack(alignment: .bottomLeading) {
            if let thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
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

            VStack(alignment: .leading, spacing: 4) {
                if let subtitle = MediaTextFormatter.seasonEpisodeLabel(
                    season: presentation.episode.parentIndex,
                    episode: presentation.episode.index
                ) {
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .padding(12)

            Button(action: onPlayNow) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                        }
                        .frame(width: metrics.playButtonSize, height: metrics.playButtonSize)

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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .disabled(presentation.isStarting)
            .duskSuppressTVOSButtonChrome()
            .duskTVOSFocusEffectShape(Circle())
        }
        .frame(width: metrics.previewWidth, height: metrics.previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 18, y: 10)
    }

    private func details(metrics: UpNextLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(primaryTitle)
                .font(metrics.titleFont)
                .foregroundStyle(.white)
                .lineLimit(metrics.titleLineLimit)

            if !presentation.shouldAutoplay {
                Text(presentation.episode.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }

            if let metadata = metadataText {
                Text(metadata)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)
            }

            if presentation.shouldAutoplay,
               let countdownLabel = presentation.secondsRemaining.map({ "Continues in \($0)s" }) {
                countdownCard(label: countdownLabel, progress: presentation.autoplayProgress)
            } else {
                Text(manualPromptMessage)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let summary = presentation.episode.summary,
               !summary.isEmpty {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineSpacing(4)
                    .lineLimit(metrics.summaryLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
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
        presentation.autoplayBlockedByPassoutProtection ? "AUTOPLAY PAUSED" : "UP NEXT"
    }

    private var primaryTitle: String {
        presentation.shouldAutoplay ? presentation.episode.title : "Are You Still Watching?"
    }

    private var manualPromptMessage: String {
        if presentation.autoplayBlockedByPassoutProtection,
           let episodeLimit = presentation.passoutProtectionEpisodeLimit {
            let episodeLabel = episodeLimit == 1 ? "episode" : "episodes"
            return "Autoplay paused after \(episodeLimit) \(episodeLabel). Start the next episode when you're ready."
        }

        return "Playback finished. Start the next episode when you're ready."
    }

    private func countdownCard(label: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.duskAccent)

                Text(label)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))

                    Capsule()
                        .fill(Color.duskAccent)
                        .frame(width: geometry.size.width * max(0, min(progress ?? 0, 1)))
                        .animation(.linear(duration: 1), value: progress ?? 0)
                }
            }
            .frame(height: 6)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        }
    }
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
        let outerPadding: CGFloat = size.width < 500 ? 16 : 28
        let safeHeight = size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom - 40
        let panelWidth = min(size.width - outerPadding * 2, size.width < 500 ? 680 : 860)
        let panelHeight = min(size.width < 500 ? 340 : 400, safeHeight)
        let panelPadding: CGFloat = size.width < 500 ? 18 : 24
        let contentSpacing: CGFloat = size.width < 500 ? 16 : 24
        let sectionSpacing: CGFloat = size.width < 500 ? 16 : 20
        let previewWidth = min(max(panelWidth * (size.width < 500 ? 0.3 : 0.28), 112), size.width < 500 ? 136 : 220)
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
            titleFont: size.width < 500 ? .title2.weight(.bold) : .largeTitle.weight(.bold),
            titleLineLimit: size.width < 500 ? 2 : 3,
            summaryLineLimit: size.width < 500 ? 3 : 4,
            playButtonSize: size.width < 500 ? 54 : 64,
            playIconSize: size.width < 500 ? 20 : 24
        )
    }
}
